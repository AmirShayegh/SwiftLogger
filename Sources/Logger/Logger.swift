//
//  Logger.swift
//
//  Created by Amir Shayegh on 2024-08-14.
//

import Foundation

// MARK: - Logger

/// Thread-safe, singleton logger with fluent configuration, hierarchical subsystems,
/// scoped correlation IDs, and structured metadata.
///
/// Access via the global `Log` constant or `Logger.shared`:
///
///     // Configure once at launch
///     Log.minimumLevel(.info)
///        .subsystem("network", level: .debug)
///        .consoleLogging(true)
///
///     // Log anywhere
///     Log("request sent", level: .debug, subsystem: "network")
///
/// Configuration is held as an immutable snapshot swapped under a lock, so the
/// logging path reads it with a single reference load rather than locking each
/// field. The class is marked `@unchecked Sendable` because every stored
/// property is either immutable or accessed exclusively under a lock.
public final class Logger: @unchecked Sendable {
    public static let shared = Logger()

    /// Guards only the `_config` reference — held just long enough to load or
    /// store a pointer, never across destination work.
    private let configLock = UnfairLock()
    private var _config: LoggerConfiguration

    /// Serializes configuration *mutations* end-to-end, so concurrent
    /// read-modify-write sequences cannot lose updates. Also guards the
    /// exception-handler fields, which are cold-path only.
    private let writeLock = NSLock()

    private var _exceptionHandlerInstalled = false
    private var _previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    internal static let defaultRegistrar: (@convention(c) (NSException) -> Void) -> Void = {
        NSSetUncaughtExceptionHandler($0)
    }
    internal var exceptionHandlerRegistrar: (@convention(c) (NSException) -> Void) -> Void = Logger.defaultRegistrar

    private init() {
        _config = .makeDefault()
    }

    // MARK: - Configuration Access

    /// Label identifying the default file destination managed by ``fileLogging(_:)``.
    /// Matches the default label of ``fileLogging(url:label:minimumLevel:rotation:)``
    /// and the internal `FileDestination` convenience initializer.
    private static let defaultFileLabel = "file"

    /// Label identifying the console destination.
    private static let consoleLabel = "console"

    private var config: LoggerConfiguration {
        configLock.withLock { _config }
    }

    /// Applies a configuration change. The new snapshot is built outside
    /// `configLock` — constructing a `FileDestination` opens a file handle, which
    /// is far too slow to do while readers are blocked.
    private func mutateConfig(_ transform: (LoggerConfiguration) -> LoggerConfiguration) {
        writeLock.lock()
        defer { writeLock.unlock() }
        let current = configLock.withLock { _config }
        let next = transform(current)
        configLock.withLock { _config = next }
    }

    private var consoleDestination: ConsoleDestination? {
        config.destination(labelled: Self.consoleLabel) as? ConsoleDestination
    }

    private var fileDestination: FileDestination? {
        config.destination(labelled: Self.defaultFileLabel) as? FileDestination
    }

    // MARK: - Read-Only State

    /// Whether the *default* file destination — the one managed by ``fileLogging(_:)``
    /// under the `"file"` label — is registered and holds a valid file handle.
    ///
    /// Custom file destinations registered under a different label do not affect
    /// this property, mirroring ``fileLogging(_:)``, which is also label-scoped.
    public var isFileLoggingActive: Bool {
        fileDestination != nil
    }

    /// Whether `installExceptionHandler()` has been called.
    public var isExceptionHandlerInstalled: Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return _exceptionHandlerInstalled
    }

    // MARK: - Fluent Configuration

    /// Sets the global minimum log level. Messages below this level are discarded.
    /// Default is `.debug`.
    @discardableResult
    public func minimumLevel(_ level: LogLevel) -> Logger {
        mutateConfig { $0.with(minimumLogLevel: level) }
        return self
    }

    /// Toggles console output via `print()`. Default is `true`.
    /// The output sink (used by tests) continues to receive messages regardless.
    @discardableResult
    public func consoleLogging(_ enabled: Bool) -> Logger {
        // Mutates the destination object itself, not the destination list, so no
        // snapshot swap is needed.
        consoleDestination?.printEnabled = enabled
        return self
    }

    /// Toggles the default file destination, which logs to `Library/Logs/app.log`
    /// under the label `"file"`.
    ///
    /// This method operates strictly on that default destination, identified by its
    /// `"file"` label. Custom file destinations registered via
    /// ``fileLogging(url:label:minimumLevel:rotation:)`` with a different label are
    /// left untouched — enabling adds the default alongside them, and disabling
    /// removes only the default. To remove a custom destination, use
    /// ``removeDestination(label:)``.
    ///
    /// The file handle is created lazily on first enable, and only when no `"file"`
    /// destination already exists. If the file cannot be opened, file logging
    /// remains disabled and a warning is printed to console. Check
    /// ``isFileLoggingActive`` to verify.
    @discardableResult
    public func fileLogging(_ enabled: Bool) -> Logger {
        var openFailed = false
        mutateConfig { current in
            if enabled {
                guard current.destination(labelled: Self.defaultFileLabel) == nil else { return current }
                guard let fd = FileDestination() else {
                    openFailed = true
                    return current
                }
                return current.with(destinations: current.destinations + [fd])
            } else {
                return current.with(
                    destinations: current.destinations.filter { $0.label != Self.defaultFileLabel }
                )
            }
        }
        if openFailed {
            print("[Logger] Failed to enable file logging — could not open log file")
        }
        return self
    }

    /// Enables file logging to a specific URL with optional configuration.
    @discardableResult
    public func fileLogging(
        url: URL,
        label: String = "file",
        minimumLevel: LogLevel? = nil,
        rotation: FileRotationConfig? = nil,
        formatter: any LogFormatter = DefaultLogFormatter()
    ) -> Logger {
        var openFailed = false
        mutateConfig { current in
            guard let fd = FileDestination(
                url: url,
                label: label,
                minimumLevel: minimumLevel,
                rotation: rotation,
                formatter: formatter
            ) else {
                openFailed = true
                return current
            }
            return current.with(
                destinations: current.destinations.filter { $0.label != label } + [fd]
            )
        }
        if openFailed {
            print("[Logger] Failed to enable file logging — could not open \(url.path)")
        }
        return self
    }

    /// Overrides the minimum log level for messages originating from `fileName`.
    ///
    /// The file name is matched against the last path component of the call
    /// site's `#fileID` (e.g. `"ContentAPI.swift"`).
    @discardableResult
    public func logLevel(_ level: LogLevel, forFile fileName: String) -> Logger {
        mutateConfig { current in
            var levels = current.fileLogLevels
            levels[fileName] = level
            return current.with(fileLogLevels: levels)
        }
        return self
    }

    /// Removes a per-file log level override, falling back to the global minimum.
    @discardableResult
    public func resetLogLevel(forFile fileName: String) -> Logger {
        mutateConfig { current in
            var levels = current.fileLogLevels
            levels.removeValue(forKey: fileName)
            return current.with(fileLogLevels: levels)
        }
        return self
    }

    /// Sets the minimum log level for a named subsystem.
    ///
    /// Subsystems support dot-separated hierarchy. Setting a level on `"ffmpeg"`
    /// applies to `"ffmpeg.decoder"`, `"ffmpeg.demuxer"`, etc. unless a more
    /// specific child level is configured.
    ///
    /// When a log message specifies a subsystem, the resolution order is:
    /// 1. Exact subsystem match
    /// 2. Walk up the hierarchy (`"a.b.c"` -> `"a.b"` -> `"a"`)
    /// 3. Per-file override (if no subsystem level found)
    /// 4. Global minimum level
    @discardableResult
    public func subsystem(_ name: String, level: LogLevel) -> Logger {
        mutateConfig { current in
            var levels = current.subsystemLevels
            levels[name] = level
            return current.with(subsystemLevels: levels)
        }
        return self
    }

    /// Removes a subsystem level, falling back to parent subsystems or the global minimum.
    @discardableResult
    public func resetSubsystem(_ name: String) -> Logger {
        mutateConfig { current in
            var levels = current.subsystemLevels
            levels.removeValue(forKey: name)
            return current.with(subsystemLevels: levels)
        }
        return self
    }

    /// Prefixes log output from `fileName` with `>>>` for visual scanning.
    @discardableResult
    public func highlight(_ fileName: String) -> Logger {
        consoleDestination?.highlight(fileName)
        return self
    }

    /// Removes the highlight prefix for `fileName`.
    @discardableResult
    public func removeHighlight(_ fileName: String) -> Logger {
        consoleDestination?.removeHighlight(fileName)
        return self
    }

    /// Installs a process-wide uncaught exception handler that logs the crash and
    /// writes it to the log file (if file logging is active) before forwarding to
    /// any previously installed handler.
    ///
    /// This is opt-in and idempotent — calling it multiple times has no additional effect.
    /// For signal-based crash reporting (SIGSEGV, SIGABRT, etc.), use a dedicated
    /// crash reporter such as Firebase Crashlytics or Sentry.
    @discardableResult
    public func installExceptionHandler() -> Logger {
        writeLock.lock()
        guard !_exceptionHandlerInstalled else {
            writeLock.unlock()
            return self
        }
        _previousExceptionHandler = NSGetUncaughtExceptionHandler()
        _exceptionHandlerInstalled = true
        let registrar = exceptionHandlerRegistrar
        writeLock.unlock()

        registrar { exception in
            Logger.shared.handleException(exception)
        }

        return self
    }

    // MARK: - Custom Destinations

    /// Registers a custom log destination.
    ///
    /// If a destination with the same `label` already exists, it is replaced.
    @discardableResult
    public func addDestination(_ destination: any LogDestination) -> Logger {
        mutateConfig { current in
            current.with(
                destinations: current.destinations.filter { $0.label != destination.label } + [destination]
            )
        }
        return self
    }

    /// Removes a destination by label.
    @discardableResult
    public func removeDestination(label: String) -> Logger {
        mutateConfig { current in
            current.with(destinations: current.destinations.filter { $0.label != label })
        }
        return self
    }

    /// Blocks until every destination has drained its buffered output to storage.
    ///
    /// File destinations write asynchronously on a background queue, so at normal
    /// process exit the tail of the log can be lost if the queue has not caught up
    /// (most likely under bursty logging or when rotation is slowing the sink).
    /// Call this before terminating — e.g. in `applicationWillTerminate` or an
    /// `atexit` handler — to guarantee queued entries reach disk. It is safe to call
    /// at any time and on any thread.
    public func flush() {
        for destination in config.destinations {
            destination.flush()
        }
    }

    // MARK: - OSLog Convenience

    #if canImport(os)
    /// Adds an OSLog destination. Convenience for `addDestination(OSLogDestination(...))`.
    @discardableResult
    public func osLogDestination(
        subsystem: String,
        category: String,
        label: String = "oslog",
        minimumLevel: LogLevel? = nil
    ) -> Logger {
        addDestination(OSLogDestination(
            subsystem: subsystem,
            category: category,
            label: label,
            minimumLevel: minimumLevel
        ))
    }
    #endif

    // MARK: - Scoped Loggers

    /// Creates a lightweight ``ScopedLogger`` that tags every message with a
    /// correlation ID and optional default subsystem.
    ///
    ///     let job = Log.scoped(correlation: "job-\(id)", subsystem: "decoder")
    ///     job.info("started")
    ///     job.debug("frame decoded", metadata: ["pts": 42])
    ///
    /// Pass `metadata` to attach context to every message from the scope:
    ///
    ///     let session = Log.scoped(correlation: "s-1", metadata: ["user": userID])
    public func scoped(
        correlation: String,
        subsystem: String? = nil,
        metadata: LogMetadata? = nil
    ) -> ScopedLogger {
        ScopedLogger(logger: self, correlation: correlation, subsystem: subsystem, metadata: metadata)
    }

    // MARK: - callAsFunction

    /// Shorthand for ``log(_:level:subsystem:metadata:correlation:file:function:line:)``,
    /// enabling `Log("message")` syntax via the global `Log` constant.
    public func callAsFunction(
        _ message: @autoclosure () -> String,
        level: LogLevel = .info,
        subsystem: String? = nil,
        metadata: LogMetadata? = nil,
        correlation: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        logMessage(message, level: level, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
    }

    // MARK: - Logging

    /// Emits a log message if `level` meets the effective threshold.
    ///
    /// The message is an `@autoclosure` — the string is not allocated when the
    /// level is filtered out, which matters in hot paths like decode loops.
    public func log(
        _ message: @autoclosure () -> String,
        level: LogLevel = .info,
        subsystem: String? = nil,
        metadata: LogMetadata? = nil,
        correlation: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        logMessage(message, level: level, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
    }

    // MARK: - Integration Entry Point

    // Public so bridge modules (SwiftLogHandler, ScopedLogger, global functions)
    // can forward the @autoclosure as a plain closure without forcing evaluation.
    public func logMessage(
        _ message: () -> String,
        level: LogLevel = .info,
        subsystem: String? = nil,
        metadata: LogMetadata? = nil,
        correlation: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let config = self.config

        // Deriving the file name costs a string scan, and a filtered-out message
        // never needs it. Resolve the level with the cheapest sufficient
        // information: a subsystem level wins outright, and per-file lookup only
        // happens when overrides actually exist.
        var fileName: String? = nil
        let effectiveLevel: LogLevel
        if let subsystemLevel = subsystem.flatMap({ config.resolveSubsystemLevel($0) }) {
            effectiveLevel = subsystemLevel
        } else if config.hasFileLevelOverrides {
            let name = Self.lastPathComponent(of: file)
            fileName = name
            effectiveLevel = config.fileLogLevels[name] ?? config.minimumLogLevel
        } else {
            effectiveLevel = config.minimumLogLevel
        }

        guard level >= effectiveLevel else { return }

        // Resolve each destination's `isEnabled`/`minimumLevel` once. Both are
        // lock-guarded computed properties on some destinations, so the previous
        // "any active?" prescan followed by a second read in the write loop paid
        // for them twice.
        var writable: [any LogDestination] = []
        for destination in config.destinations where destination.isEnabled {
            if let destMin = destination.minimumLevel, level < destMin { continue }
            writable.append(destination)
        }
        guard !writable.isEmpty else { return }

        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            message: message(),
            metadata: metadata,
            correlation: correlation,
            subsystem: subsystem,
            fileName: fileName ?? Self.lastPathComponent(of: file),
            function: function,
            line: line,
            // Only worth an allocation when more than one destination would
            // otherwise format the same entry independently.
            formatCache: writable.count > 1 ? LogEntryFormatCache() : nil
        )

        for destination in writable {
            destination.write(entry)
        }
    }

    /// Native-Swift last path component. `#fileID` yields `"Module/File.swift"`,
    /// and callers may pass a full `#file` path; both reduce to the trailing
    /// segment. Avoids the `NSString` bridge this used to pay on every call.
    @inline(__always)
    private static func lastPathComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    // MARK: - Exception Handling

    private func handleException(_ exception: NSException) {
        let crashLog = """
        Exception Name: \(exception.name)
        Exception Reason: \(exception.reason ?? "Unknown")
        Stack Trace:
        \(exception.callStackSymbols.joined(separator: "\n"))
        """
        log("Crash occurred:\n\(crashLog)", level: .error)

        let fd = fileDestination

        writeLock.lock()
        let previousHandler = _previousExceptionHandler
        writeLock.unlock()

        fd?.forceSave(crashLog)

        previousHandler?(exception)
    }

    // MARK: - Test Support

    internal func destinationForTesting(label: String) -> (any LogDestination)? {
        config.destination(labelled: label)
    }

    internal func setOutputSink(_ sink: ((String) -> Void)?) {
        consoleDestination?.setOutputSink(sink)
    }

    internal func reset() {
        writeLock.lock()
        configLock.withLock { _config = .makeDefault() }
        _exceptionHandlerInstalled = false
        _previousExceptionHandler = nil
        exceptionHandlerRegistrar = Self.defaultRegistrar
        writeLock.unlock()
    }
}

// MARK: - Global Accessor

/// Global shorthand for `Logger.shared`.
///
/// Supports `callAsFunction` so you can write `Log("message")` as well as
/// `Log.minimumLevel(.info)` for configuration.
public let Log = Logger.shared

// MARK: - Global Convenience Functions

/// Logs a message at `.verbose` level.
public func logVerbose(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    Log.logMessage(message, level: .verbose, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.debug` level.
public func logDebug(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    Log.logMessage(message, level: .debug, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.info` level.
public func logInfo(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    Log.logMessage(message, level: .info, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.warning` level.
public func logWarning(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    Log.logMessage(message, level: .warning, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.error` level.
public func logError(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    Log.logMessage(message, level: .error, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.todo` level — marks incomplete work.
public func logTODO(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    Log.logMessage(message, level: .todo, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

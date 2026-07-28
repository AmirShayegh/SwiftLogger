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

    /// Installs a process-wide uncaught-exception handler, or clears it when
    /// passed `nil`. Nullable because ``reset()`` has to be able to restore a
    /// pre-install state that had no handler at all.
    internal typealias ExceptionHandlerRegistrar = ((@convention(c) (NSException) -> Void)?) -> Void

    internal static let defaultRegistrar: ExceptionHandlerRegistrar = {
        NSSetUncaughtExceptionHandler($0)
    }
    internal var exceptionHandlerRegistrar: ExceptionHandlerRegistrar = Logger.defaultRegistrar

    /// The registrar that actually installed the trampoline.
    ///
    /// ``reset()`` restores through *this*, not through whatever
    /// `exceptionHandlerRegistrar` happens to hold now. A test that swapped in
    /// a fake registrar never touched the real process handler, so restoring
    /// via `NSSetUncaughtExceptionHandler` would clobber the test host's.
    private var _installRegistrar: ExceptionHandlerRegistrar?

    private init() {
        _config = .makeDefault()
    }

    // MARK: - Configuration Access

    /// Label identifying the default file destination managed by ``fileLogging(_:)``.
    /// Matches the default label of ``fileLogging(url:label:minimumLevel:rotation:formatter:)``
    /// and the internal `FileDestination` convenience initializer.
    private static let defaultFileLabel = "file"

    /// Label identifying the console destination.
    private static let consoleLabel = "console"

    /// Redirects the destination created by ``fileLogging(_:)``, for tests that
    /// would otherwise write to the developer's real `~/Library/Logs/app.log`.
    ///
    /// Guarded by its own lock, deliberately not `writeLock`: it is read from
    /// `FileDestination.init()` inside a `mutateConfig` transform, which already
    /// holds `writeLock`. Reusing it here would deadlock on the first
    /// `fileLogging(true)`.
    private static let defaultFileURLLock = UnfairLock()
    private nonisolated(unsafe) static var _defaultFileURLOverride: URL?

    internal static var defaultFileURLOverride: URL? {
        get { defaultFileURLLock.withLock { _defaultFileURLOverride } }
        set { defaultFileURLLock.withLock { _defaultFileURLOverride = newValue } }
    }

    /// Where ``fileLogging(_:)`` writes.
    internal static var defaultFileURL: URL {
        if let override = defaultFileURLOverride { return override }
        let logsDir: URL
        if let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            logsDir = lib.appendingPathComponent("Logs")
        } else {
            logsDir = FileManager.default.temporaryDirectory
        }
        return logsDir.appendingPathComponent("app.log")
    }

    private var config: LoggerConfiguration {
        configLock.withLock { _config }
    }

    /// Applies a configuration change. The new snapshot is built outside
    /// `configLock` — constructing a `FileDestination` opens a file handle, which
    /// is far too slow to do while readers are blocked.
    ///
    /// A transform that drops a destination appends it to `retiring` instead of
    /// flushing it itself. Retired destinations are flushed, and the outgoing
    /// snapshot released, only after `writeLock` is dropped — both steps run
    /// arbitrary user code, and running it under the lock deadlocks:
    ///
    /// - `flush()` on a file destination is a `queue.sync`, and the drain
    ///   renders any pending drop notice through the user's `LogFormatter`.
    /// - Releasing the last reference to a file destination runs its `deinit`,
    ///   which drains through that same formatter.
    ///
    /// Either one is free to call straight back into a configuration API, and
    /// `writeLock` is a plain `NSLock`.
    private func mutateConfig(
        _ transform: (LoggerConfiguration, inout [any LogDestination]) -> LoggerConfiguration
    ) {
        var retiring: [any LogDestination] = []

        writeLock.lock()
        let current = configLock.withLock { _config }
        let next = transform(current, &retiring)
        configLock.withLock { _config = next }
        writeLock.unlock()

        for destination in retiring {
            destination.flush()
        }
        // `current` holds the last reference to every retired destination, and
        // ARC is free to release a local at its final use — which would be
        // inside the critical section above. Pin it until here.
        withExtendedLifetime(current) {}
    }

    /// Convenience for transforms that retire nothing.
    private func mutateConfig(_ transform: (LoggerConfiguration) -> LoggerConfiguration) {
        mutateConfig { current, _ in transform(current) }
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
    /// ``fileLogging(url:label:minimumLevel:rotation:formatter:)`` with a different label are
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
        mutateConfig { current, retiring in
            if enabled {
                guard current.destination(labelled: Self.defaultFileLabel) == nil else { return current }
                guard let fd = FileDestination() else {
                    openFailed = true
                    return current
                }
                return current.with(destinations: current.destinations + [fd])
            } else {
                // Retired rather than dropped, so it is drained synchronously
                // once the lock is clear: callers find every entry on disk when
                // this returns rather than racing the deinit drain.
                if let outgoing = current.destination(labelled: Self.defaultFileLabel) {
                    retiring.append(outgoing)
                }
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
        mutateConfig { current, retiring in
            // The outgoing destination is drained as soon as the lock is clear,
            // before this call returns, so its buffered entries land ahead of
            // the replacement's. A log call that raced into the old snapshot
            // still cannot corrupt the file: both handles append.
            if let outgoing = current.destination(labelled: label) {
                retiring.append(outgoing)
            }
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
        _installRegistrar = registrar
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
        mutateConfig { current, retiring in
            // Drain any replaced destination so its buffered entries are on
            // disk before the newcomer starts writing.
            if let outgoing = current.destination(labelled: destination.label) {
                retiring.append(outgoing)
            }
            return current.with(
                destinations: current.destinations.filter { $0.label != destination.label } + [destination]
            )
        }
        return self
    }

    /// Removes a destination by label. Buffered output is drained to storage
    /// before this returns.
    @discardableResult
    public func removeDestination(label: String) -> Logger {
        mutateConfig { current, retiring in
            if let outgoing = current.destination(labelled: label) {
                retiring.append(outgoing)
            }
            return current.with(destinations: current.destinations.filter { $0.label != label })
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
    ///     let session = Log.scoped(correlation: "s-1", metadata: ["user": LogValue(userID)])
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
        let (effectiveLevel, fileName) = config.resolveEffectiveLevel(subsystem: subsystem, file: file)

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
    internal static func lastPathComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Whether a message at `level` from `subsystem`/`file` would pass the
    /// level gate.
    ///
    /// Lets a bridge skip building context — stringifying errors, converting
    /// metadata dictionaries — for a message that is about to be discarded. It
    /// takes the raw `file` rather than a pre-derived name on purpose: deriving
    /// one eagerly would reintroduce exactly the string scan the hot path goes
    /// out of its way to defer.
    ///
    /// This is only the *level* gate, the same one ``logMessage`` applies
    /// first; a message that passes here can still be dropped by every
    /// destination's own minimum.
    internal func wouldLog(level: LogLevel, subsystem: String?, file: String) -> Bool {
        level >= config.resolveEffectiveLevel(subsystem: subsystem, file: file).level
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

    /// Returns the logger to its as-launched state.
    ///
    /// Exception-handler invariants, in the order they matter:
    ///
    /// - Reset without a prior install never calls any registrar. Uninstalling
    ///   a handler this logger did not install is not this logger's business.
    /// - An install followed by a reset restores whatever
    ///   `NSGetUncaughtExceptionHandler()` returned *before* the install —
    ///   including `nil` — through the registrar that performed the install.
    /// - Consequently install → reset → install reads the genuine pre-install
    ///   handler as its "previous", never this logger's own trampoline. Without
    ///   the restore, the second install chains the trampoline to itself and
    ///   the first uncaught exception recurses until the stack runs out.
    /// - A second reset is a no-op, because the first cleared the flag.
    internal func reset() {
        writeLock.lock()
        let outgoing = configLock.withLock { _config }
        configLock.withLock { _config = .makeDefault() }
        let restore: (registrar: ExceptionHandlerRegistrar, handler: (@convention(c) (NSException) -> Void)?)?
            = _exceptionHandlerInstalled ? (_installRegistrar ?? Self.defaultRegistrar, _previousExceptionHandler) : nil
        _exceptionHandlerInstalled = false
        _previousExceptionHandler = nil
        _installRegistrar = nil
        exceptionHandlerRegistrar = Self.defaultRegistrar
        writeLock.unlock()

        Self.defaultFileURLOverride = nil

        // Outside the lock: the registrar is caller-supplied, and the drain and
        // release below run the user's formatter, which may reconfigure the
        // logger. Same reasoning as mutateConfig.
        if let restore {
            restore.registrar(restore.handler)
        }
        for destination in outgoing.destinations {
            destination.flush()
        }
        withExtendedLifetime(outgoing) {}
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

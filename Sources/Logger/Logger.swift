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
/// All mutable state is protected by an internal lock. The class is marked
/// `@unchecked Sendable` because every stored property is either immutable
/// or accessed exclusively under that lock.
public final class Logger: @unchecked Sendable {
    public static let shared = Logger()

    private let lock = NSLock()

    private var _minimumLogLevel: LogLevel = .debug
    private var _fileLogLevels: [String: LogLevel] = [:]
    private var _subsystemLevels: [String: LogLevel] = [:]
    private var _destinations: [any LogDestination] = []
    private var _exceptionHandlerInstalled = false
    private var _previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    internal static let defaultRegistrar: (@convention(c) (NSException) -> Void) -> Void = {
        NSSetUncaughtExceptionHandler($0)
    }
    internal var exceptionHandlerRegistrar: (@convention(c) (NSException) -> Void) -> Void = Logger.defaultRegistrar

    private init() {
        _destinations = [ConsoleDestination()]
    }

    // MARK: - Destination Access (internal)

    private func destination<T: LogDestination>(ofType type: T.Type) -> T? {
        _destinations.first(where: { $0 is T }) as? T
    }

    private var consoleDestination: ConsoleDestination? {
        destination(ofType: ConsoleDestination.self)
    }

    private var fileDestination: FileDestination? {
        destination(ofType: FileDestination.self)
    }

    // MARK: - Read-Only State

    /// Whether file logging is both enabled and has a valid file handle.
    public var isFileLoggingActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fileDestination != nil
    }

    /// Whether `installExceptionHandler()` has been called.
    public var isExceptionHandlerInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _exceptionHandlerInstalled
    }

    // MARK: - Fluent Configuration

    /// Sets the global minimum log level. Messages below this level are discarded.
    /// Default is `.debug`.
    @discardableResult
    public func minimumLevel(_ level: LogLevel) -> Logger {
        lock.lock()
        _minimumLogLevel = level
        lock.unlock()
        return self
    }

    /// Toggles console output via `print()`. Default is `true`.
    /// The output sink (used by tests) continues to receive messages regardless.
    @discardableResult
    public func consoleLogging(_ enabled: Bool) -> Logger {
        lock.lock()
        consoleDestination?.printEnabled = enabled
        lock.unlock()
        return self
    }

    /// Toggles file logging to `Documents/app.log`.
    ///
    /// The file handle is created lazily on first enable. If the file cannot be
    /// opened, file logging remains disabled and a warning is printed to console.
    /// Check ``isFileLoggingActive`` to verify.
    @discardableResult
    public func fileLogging(_ enabled: Bool) -> Logger {
        lock.lock()
        if enabled {
            if fileDestination == nil {
                if let fd = FileDestination() {
                    _destinations.append(fd)
                } else {
                    lock.unlock()
                    print("[Logger] Failed to enable file logging — could not open log file")
                    return self
                }
            }
        } else {
            _destinations.removeAll(where: { $0 is FileDestination })
        }
        lock.unlock()
        return self
    }

    /// Overrides the minimum log level for messages originating from `fileName`.
    ///
    /// The file name is matched against the last path component of `#file`
    /// (e.g. `"ContentAPI.swift"`).
    @discardableResult
    public func logLevel(_ level: LogLevel, forFile fileName: String) -> Logger {
        lock.lock()
        _fileLogLevels[fileName] = level
        lock.unlock()
        return self
    }

    /// Removes a per-file log level override, falling back to the global minimum.
    @discardableResult
    public func resetLogLevel(forFile fileName: String) -> Logger {
        lock.lock()
        _fileLogLevels.removeValue(forKey: fileName)
        lock.unlock()
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
        lock.lock()
        _subsystemLevels[name] = level
        lock.unlock()
        return self
    }

    /// Removes a subsystem level, falling back to parent subsystems or the global minimum.
    @discardableResult
    public func resetSubsystem(_ name: String) -> Logger {
        lock.lock()
        _subsystemLevels.removeValue(forKey: name)
        lock.unlock()
        return self
    }

    /// Prefixes log output from `fileName` with `>>>` for visual scanning.
    @discardableResult
    public func highlight(_ fileName: String) -> Logger {
        lock.lock()
        consoleDestination?.highlight(fileName)
        lock.unlock()
        return self
    }

    /// Removes the highlight prefix for `fileName`.
    @discardableResult
    public func removeHighlight(_ fileName: String) -> Logger {
        lock.lock()
        consoleDestination?.removeHighlight(fileName)
        lock.unlock()
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
        lock.lock()
        guard !_exceptionHandlerInstalled else {
            lock.unlock()
            return self
        }
        _previousExceptionHandler = NSGetUncaughtExceptionHandler()
        _exceptionHandlerInstalled = true
        let registrar = exceptionHandlerRegistrar
        lock.unlock()

        registrar { exception in
            Logger.shared.handleException(exception)
        }

        return self
    }

    // MARK: - Scoped Loggers

    /// Creates a lightweight ``ScopedLogger`` that tags every message with a
    /// correlation ID and optional default subsystem.
    ///
    ///     let job = Log.scoped(correlation: "job-\(id)", subsystem: "decoder")
    ///     job.info("started")
    ///     job.debug("frame decoded", metadata: ["pts": 42])
    public func scoped(correlation: String, subsystem: String? = nil) -> ScopedLogger {
        ScopedLogger(logger: self, correlation: correlation, subsystem: subsystem)
    }

    // MARK: - Subsystem Level Resolution

    private func resolveSubsystemLevel(_ name: String) -> LogLevel? {
        var current = name
        while true {
            if let level = _subsystemLevels[current] {
                return level
            }
            guard let dotIndex = current.lastIndex(of: ".") else {
                return nil
            }
            current = String(current[current.startIndex..<dotIndex])
        }
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
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        _log(message, level: level, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
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
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        _log(message, level: level, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
    }

    // MARK: - Internal Log (closure-forwarding entry point)

    // internal (not private) so ScopedLogger and global functions can forward
    // the @autoclosure as a plain closure without forcing evaluation.
    internal func _log(
        _ message: () -> String,
        level: LogLevel = .info,
        subsystem: String? = nil,
        metadata: LogMetadata? = nil,
        correlation: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let fileName = (file as NSString).lastPathComponent

        lock.lock()
        let subsystemLevel = subsystem.flatMap { resolveSubsystemLevel($0) }
        let fileLevel = _fileLogLevels[fileName]
        let effectiveLevel = subsystemLevel ?? fileLevel ?? _minimumLogLevel
        let destinations = _destinations
        lock.unlock()

        guard level >= effectiveLevel else { return }
        guard destinations.contains(where: { $0.isEnabled }) else { return }

        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            message: message(),
            metadata: metadata,
            correlation: correlation,
            subsystem: subsystem,
            fileName: fileName,
            function: function,
            line: line
        )

        for destination in destinations where destination.isEnabled {
            destination.write(entry)
        }
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

        lock.lock()
        let fd = fileDestination
        let previousHandler = _previousExceptionHandler
        lock.unlock()

        fd?.forceSave(crashLog)

        previousHandler?(exception)
    }

    // MARK: - Test Support

    internal func setOutputSink(_ sink: ((String) -> Void)?) {
        lock.lock()
        consoleDestination?.setOutputSink(sink)
        lock.unlock()
    }

    internal func reset() {
        lock.lock()
        _minimumLogLevel = .debug
        _fileLogLevels = [:]
        _subsystemLevels = [:]
        _destinations = [ConsoleDestination()]
        _exceptionHandlerInstalled = false
        _previousExceptionHandler = nil
        exceptionHandlerRegistrar = Self.defaultRegistrar
        lock.unlock()
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
public func logVerbose(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log._log(message, level: .verbose, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.debug` level.
public func logDebug(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log._log(message, level: .debug, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.info` level.
public func logInfo(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log._log(message, level: .info, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.warning` level.
public func logWarning(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log._log(message, level: .warning, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.error` level.
public func logError(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log._log(message, level: .error, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.todo` level — marks incomplete work.
public func logTODO(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log._log(message, level: .todo, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

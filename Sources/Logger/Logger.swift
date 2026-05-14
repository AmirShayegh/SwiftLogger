//
//  Logger.swift
//
//  Created by Amir Shayegh on 2024-08-14.
//

import Foundation

// MARK: - LogLevel

/// Severity levels for log messages, ordered from least to most severe.
///
/// The logger filters messages below the configured minimum level.
/// Levels in ascending order: `verbose` < `debug` < `info` < `warning` < `error` < `todo`.
public enum LogLevel: String, Comparable, Sendable, CaseIterable {
    case verbose = "VERBOSE"
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    /// Marks incomplete work. Highest severity so it always surfaces.
    case todo = "TODO"

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.verbose, .debug, .info, .warning, .error, .todo]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    var emoji: String {
        switch self {
        case .verbose: return "🟣"
        case .debug: return "🔵"
        case .info: return "🟢"
        case .warning: return "⚠️"
        case .error: return "⛔️"
        case .todo: return "🚧"
        }
    }

    var prefix: String {
        "\(emoji) [\(rawValue)]"
    }
}

// MARK: - LogValue

/// A type-safe, `Sendable` value for structured log metadata.
///
/// Conforms to `ExpressibleByStringLiteral`, `ExpressibleByIntegerLiteral`,
/// `ExpressibleByFloatLiteral`, and `ExpressibleByBooleanLiteral` so metadata
/// dictionaries read naturally at the call site:
///
///     Log("frame decoded", metadata: ["pts": 42, "keyframe": true])
public enum LogValue: Sendable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public var description: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return String(v)
        }
    }
}

extension LogValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension LogValue: ExpressibleByStringInterpolation {
    public init(stringInterpolation: DefaultStringInterpolation) {
        self = .string(String(stringInterpolation: stringInterpolation))
    }
}

extension LogValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension LogValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension LogValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Key-value pairs attached to a log message for structured context.
public typealias LogMetadata = [String: LogValue]

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
    private var _consoleEnabled = true
    private var _fileEnabled = false
    private var _fileLogLevels: [String: LogLevel] = [:]
    private var _subsystemLevels: [String: LogLevel] = [:]
    private var _highlightedFiles: Set<String> = []
    private var _fileLogger: FileLogger?
    private var _exceptionHandlerInstalled = false
    private var _previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    private var _outputSink: ((String) -> Void)?

    internal static let defaultRegistrar: (@convention(c) (NSException) -> Void) -> Void = {
        NSSetUncaughtExceptionHandler($0)
    }
    internal var exceptionHandlerRegistrar: (@convention(c) (NSException) -> Void) -> Void = Logger.defaultRegistrar

    private init() {}

    // MARK: - Read-Only State

    /// Whether file logging is both enabled and has a valid file handle.
    public var isFileLoggingActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fileEnabled && _fileLogger != nil
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
    @discardableResult
    public func consoleLogging(_ enabled: Bool) -> Logger {
        lock.lock()
        _consoleEnabled = enabled
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
            if _fileLogger == nil {
                _fileLogger = FileLogger()
            }
            _fileEnabled = _fileLogger != nil
            if !_fileEnabled {
                lock.unlock()
                print("⚠️ [Logger] Failed to enable file logging — could not open log file")
                return self
            }
        } else {
            _fileEnabled = false
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

    /// Prefixes log output from `fileName` with a magnifying glass icon for visual scanning.
    @discardableResult
    public func highlight(_ fileName: String) -> Logger {
        lock.lock()
        _highlightedFiles.insert(fileName)
        lock.unlock()
        return self
    }

    /// Removes the highlight prefix for `fileName`.
    @discardableResult
    public func removeHighlight(_ fileName: String) -> Logger {
        lock.lock()
        _highlightedFiles.remove(fileName)
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

    // Walks "a.b.c" -> "a.b" -> "a" to find the nearest configured level.
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
        log(message(), level: level, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
    }

    // MARK: - Logging

    /// Emits a log message if `level` meets the effective threshold.
    ///
    /// The message is an `@autoclosure` — the string is not allocated when the
    /// level is filtered out, which matters in hot paths like decode loops.
    ///
    /// - Parameters:
    ///   - message: The log message (lazily evaluated).
    ///   - level: Severity level. Default is `.info`.
    ///   - subsystem: Optional subsystem for hierarchical filtering (e.g. `"ffmpeg.decoder"`).
    ///   - metadata: Optional key-value pairs rendered as `{key=value, ...}` after the message.
    ///   - correlation: Optional correlation ID rendered as `[id]` before the source location.
    ///   - file: Source file (auto-captured).
    ///   - function: Source function (auto-captured).
    ///   - line: Source line (auto-captured).
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
        let fileName = (file as NSString).lastPathComponent

        lock.lock()
        let subsystemLevel = subsystem.flatMap { resolveSubsystemLevel($0) }
        let fileLevel = _fileLogLevels[fileName]
        let effectiveLevel = subsystemLevel ?? fileLevel ?? _minimumLogLevel
        let consoleOn = _consoleEnabled
        let fileOn = _fileEnabled
        let highlighted = _highlightedFiles.contains(fileName)
        let fileLogger = _fileLogger
        let sink = _outputSink
        lock.unlock()

        guard level >= effectiveLevel else { return }

        let messageText = message()
        let timestamp = Self.formatTimestamp()

        var tags = ""
        if let corr = correlation {
            tags += "[\(corr)] "
        }
        if let sub = subsystem {
            tags += "[\(sub)] "
        }

        var logMessage = "\(level.prefix) [\(timestamp)] \(tags)(\(fileName):\(line)) \(function)\n    ┗━▶ \(messageText)"

        if let meta = metadata, !meta.isEmpty {
            let pairs = meta.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            logMessage += " {\(pairs)}"
        }

        if highlighted {
            logMessage = "🔍 \(logMessage)"
        }

        if consoleOn {
            print(logMessage)
        }

        if fileOn {
            fileLogger?.log(logMessage)
        }

        sink?(logMessage)
    }

    // MARK: - Thread-Safe Timestamp

    private static func formatTimestamp() -> String {
        let formatter = Thread.current.threadDictionary["LoggerDateFormatter"] as? DateFormatter ?? {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            Thread.current.threadDictionary["LoggerDateFormatter"] = f
            return f
        }()
        return formatter.string(from: Date())
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
        let fileLogger = _fileLogger
        let fileOn = _fileEnabled
        let previousHandler = _previousExceptionHandler
        lock.unlock()

        if fileOn {
            fileLogger?.forceSave(crashLog)
        }

        previousHandler?(exception)
    }

    // MARK: - Test Support

    internal func setOutputSink(_ sink: ((String) -> Void)?) {
        lock.lock()
        _outputSink = sink
        lock.unlock()
    }

    internal func reset() {
        lock.lock()
        _minimumLogLevel = .debug
        _consoleEnabled = true
        _fileEnabled = false
        _fileLogLevels = [:]
        _subsystemLevels = [:]
        _highlightedFiles = []
        _fileLogger = nil
        _exceptionHandlerInstalled = false
        _previousExceptionHandler = nil
        _outputSink = nil
        exceptionHandlerRegistrar = Self.defaultRegistrar
        lock.unlock()
    }
}

// MARK: - ScopedLogger

/// A lightweight, `Sendable` logger that tags every message with a correlation ID
/// and optional default subsystem.
///
/// Created via ``Logger/scoped(correlation:subsystem:)``. Scoped loggers delegate
/// all work to the parent `Logger` — they carry no mutable state of their own.
///
///     let job = Log.scoped(correlation: "job-\(id)", subsystem: "decoder")
///     job.info("started")
///     job.debug("keyframe at pts=\(pts)", metadata: ["size": 2048])
///
/// Scoped loggers can be nested. A child inherits the parent's subsystem unless
/// explicitly overridden:
///
///     let child = job.scoped(correlation: "subtask-1")              // keeps "decoder"
///     let other = job.scoped(correlation: "sub-2", subsystem: "io") // overrides
public struct ScopedLogger: Sendable {
    private let logger: Logger
    /// The correlation ID attached to every log message from this scope.
    public let correlation: String
    /// The default subsystem for this scope, used for hierarchical filtering.
    public let subsystem: String?

    internal init(logger: Logger, correlation: String, subsystem: String?) {
        self.logger = logger
        self.correlation = correlation
        self.subsystem = subsystem
    }

    /// Logs a message through the parent logger with this scope's correlation ID and subsystem.
    public func log(
        _ message: @autoclosure () -> String,
        level: LogLevel = .info,
        metadata: LogMetadata? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        logger.log(
            message(),
            level: level,
            subsystem: subsystem,
            metadata: metadata,
            correlation: correlation,
            file: file,
            function: function,
            line: line
        )
    }

    public func verbose(_ message: @autoclosure () -> String, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), level: .verbose, metadata: metadata, file: file, function: function, line: line)
    }

    public func debug(_ message: @autoclosure () -> String, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), level: .debug, metadata: metadata, file: file, function: function, line: line)
    }

    public func info(_ message: @autoclosure () -> String, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), level: .info, metadata: metadata, file: file, function: function, line: line)
    }

    public func warning(_ message: @autoclosure () -> String, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), level: .warning, metadata: metadata, file: file, function: function, line: line)
    }

    public func error(_ message: @autoclosure () -> String, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), level: .error, metadata: metadata, file: file, function: function, line: line)
    }

    public func todo(_ message: @autoclosure () -> String, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), level: .todo, metadata: metadata, file: file, function: function, line: line)
    }

    /// Creates a child scope. Inherits this scope's subsystem unless overridden.
    public func scoped(correlation: String, subsystem: String? = nil) -> ScopedLogger {
        ScopedLogger(logger: logger, correlation: correlation, subsystem: subsystem ?? self.subsystem)
    }
}

// MARK: - File Logger

private final class FileLogger: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<Bool>()
    private let queue: DispatchQueue
    private let fileURL: URL
    private let fileHandle: FileHandle

    init?() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent("app.log")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil) else {
                return nil
            }
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return nil
        }

        self.fileHandle = handle
        self.fileHandle.seekToEndOfFile()
        self.queue = DispatchQueue(label: "com.logger.filewriter")
        self.queue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit {
        queue.sync {
            try? fileHandle.synchronize()
            try? fileHandle.close()
        }
    }

    func log(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        queue.async { [fileHandle] in
            try? fileHandle.write(contentsOf: data)
        }
    }

    func forceSave(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        let work = { [fileHandle] in
            try? fileHandle.write(contentsOf: data)
            try? fileHandle.synchronize()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            work()
        } else {
            queue.sync(execute: work)
        }
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
    Log.log(message(), level: .verbose, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.debug` level.
public func logDebug(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log.log(message(), level: .debug, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.info` level.
public func logInfo(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log.log(message(), level: .info, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.warning` level.
public func logWarning(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log.log(message(), level: .warning, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.error` level.
public func logError(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log.log(message(), level: .error, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

/// Logs a message at `.todo` level — marks incomplete work.
public func logTODO(_ message: @autoclosure () -> String, subsystem: String? = nil, metadata: LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Log.log(message(), level: .todo, subsystem: subsystem, metadata: metadata, file: file, function: function, line: line)
}

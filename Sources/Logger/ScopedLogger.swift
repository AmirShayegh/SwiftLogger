import Foundation

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
        metadata: @autoclosure () -> LogMetadata? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        logger.logMessage(
            message,
            level: level,
            subsystem: subsystem,
            metadata: metadata,
            correlation: correlation,
            file: file,
            function: function,
            line: line
        )
    }

    public func verbose(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .verbose, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
    }

    public func debug(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .debug, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
    }

    public func info(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .info, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
    }

    public func warning(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .warning, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
    }

    public func error(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .error, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
    }

    public func todo(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .todo, subsystem: subsystem, metadata: metadata, correlation: correlation, file: file, function: function, line: line)
    }

    /// Creates a child scope. Inherits this scope's subsystem unless overridden.
    public func scoped(correlation: String, subsystem: String? = nil) -> ScopedLogger {
        ScopedLogger(logger: logger, correlation: correlation, subsystem: subsystem ?? self.subsystem)
    }
}

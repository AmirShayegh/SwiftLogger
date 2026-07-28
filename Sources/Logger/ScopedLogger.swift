import Foundation

/// A lightweight, `Sendable` logger that tags every message with a correlation ID
/// and optional default subsystem.
///
/// Created via ``Logger/scoped(correlation:subsystem:metadata:)``. Scoped loggers delegate
/// all work to the parent `Logger` — they carry no mutable state of their own.
///
///     let job = Log.scoped(correlation: "job-\(id)", subsystem: "decoder")
///     job.info("started")
///     job.debug("keyframe at pts=\(pts)", metadata: ["size": 2048])
///
/// A scope can also carry default metadata, merged into every message it emits:
///
///     let job = Log.scoped(correlation: "job-\(id)", metadata: ["user": LogValue(userID)])
///     job.info("started")                              // includes user=…
///     job.info("done", metadata: ["ms": elapsed])      // includes user=… and ms=…
///
/// Scoped loggers can be nested. A child inherits the parent's subsystem and
/// metadata unless explicitly overridden:
///
///     let child = job.scoped(correlation: "subtask-1")              // keeps "decoder"
///     let other = job.scoped(correlation: "sub-2", subsystem: "io") // overrides
public struct ScopedLogger: Sendable {
    private let logger: Logger
    /// The correlation ID attached to every log message from this scope.
    public let correlation: String
    /// The default subsystem for this scope, used for hierarchical filtering.
    public let subsystem: String?
    /// Metadata merged into every message from this scope. Per-call metadata
    /// wins on key collisions.
    public let metadata: LogMetadata?

    internal init(
        logger: Logger,
        correlation: String,
        subsystem: String?,
        metadata: LogMetadata? = nil
    ) {
        self.logger = logger
        self.correlation = correlation
        self.subsystem = subsystem
        self.metadata = metadata
    }

    /// Combines this scope's metadata with a call site's.
    ///
    /// The call site wins on collisions: a message saying `["state": "failed"]`
    /// must not be overridden by the scope's default.
    @inline(__always)
    internal func merged(_ callSite: LogMetadata?) -> LogMetadata? {
        guard let metadata else { return callSite }
        guard let callSite else { return metadata }
        return metadata.merging(callSite) { _, fromCallSite in fromCallSite }
    }

    /// Logs a message through the parent logger with this scope's correlation ID and subsystem.
    public func log(
        _ message: @autoclosure () -> String,
        level: LogLevel = .info,
        metadata: @autoclosure () -> LogMetadata? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        logger.logMessage(
            message,
            level: level,
            subsystem: subsystem,
            // Deferred: the caller's dictionary AND the merge with the scope's
            // defaults are both skipped when the message is filtered out.
            metadata: { merged(metadata()) },
            correlation: correlation,
            file: file,
            function: function,
            line: line
        )
    }

    public func verbose(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .verbose, subsystem: subsystem, metadata: { merged(metadata()) }, correlation: correlation, file: file, function: function, line: line)
    }

    public func debug(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .debug, subsystem: subsystem, metadata: { merged(metadata()) }, correlation: correlation, file: file, function: function, line: line)
    }

    public func info(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .info, subsystem: subsystem, metadata: { merged(metadata()) }, correlation: correlation, file: file, function: function, line: line)
    }

    public func warning(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .warning, subsystem: subsystem, metadata: { merged(metadata()) }, correlation: correlation, file: file, function: function, line: line)
    }

    public func error(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .error, subsystem: subsystem, metadata: { merged(metadata()) }, correlation: correlation, file: file, function: function, line: line)
    }

    public func todo(_ message: @autoclosure () -> String, metadata: @autoclosure () -> LogMetadata? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
        logger.logMessage(message, level: .todo, subsystem: subsystem, metadata: { merged(metadata()) }, correlation: correlation, file: file, function: function, line: line)
    }

    /// Creates a child scope, inheriting this scope's subsystem and metadata
    /// unless overridden.
    ///
    /// Metadata is merged rather than replaced, so a child adds to its parent's
    /// context instead of discarding it; the child's own keys win on collision.
    public func scoped(
        correlation: String,
        subsystem: String? = nil,
        metadata: LogMetadata? = nil
    ) -> ScopedLogger {
        ScopedLogger(
            logger: logger,
            correlation: correlation,
            subsystem: subsystem ?? self.subsystem,
            metadata: merged(metadata)
        )
    }
}

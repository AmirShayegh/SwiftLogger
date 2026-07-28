import Foundation

/// Holds the default-formatted line for one entry so that fanning out to
/// several destinations formats it once.
///
/// A reference type deliberately: `LogEntry` is a struct handed to each
/// destination by value, and a class lets every copy share the one result.
internal final class LogEntryFormatCache: @unchecked Sendable {
    private let lock = UnfairLock()
    private var line: String?

    #if DEBUG
    /// Test hook: how many times a line was actually computed, to prove the
    /// cache is doing its job.
    ///
    /// Debug-only. In release this counter would be a process-wide lock taken
    /// on every single formatted entry — a serialisation point between threads
    /// that exists purely to satisfy a test assertion.
    private static let computeCountLock = UnfairLock()
    private static var _computeCount = 0
    internal static var computeCount: Int {
        computeCountLock.withLock { _computeCount }
    }
    internal static func resetComputeCountForTesting() {
        computeCountLock.withLock { _computeCount = 0 }
    }
    #endif

    func line(for entry: LogEntry) -> String {
        lock.withLock {
            if let line { return line }
            let computed = entry.computeDefaultFormat()
            line = computed
            return computed
        }
    }

    @inline(__always)
    static func noteComputation() {
        #if DEBUG
        computeCountLock.withLock { _computeCount += 1 }
        #endif
    }
}

/// Structured representation of a single log event, passed to destinations.
public struct LogEntry: Sendable {
    public let timestamp: Date
    public let level: LogLevel
    public let message: String
    public let metadata: LogMetadata?
    public let correlation: String?
    public let subsystem: String?
    public let fileName: String
    public let function: String
    public let line: Int

    /// Present only when the entry fans out to more than one destination, where
    /// sharing the formatted line pays for the allocation. A single-destination
    /// entry leaves this `nil` and formats directly, so the common case adds
    /// nothing.
    internal let formatCache: LogEntryFormatCache?

    /// Whether this entry carries a shared format cache. Lets the tests assert
    /// the allocation policy in release builds, where the compute counter is
    /// compiled out.
    internal var hasFormatCacheForTesting: Bool { formatCache != nil }

    public init(
        timestamp: Date = Date(),
        level: LogLevel,
        message: String,
        metadata: LogMetadata? = nil,
        correlation: String? = nil,
        subsystem: String? = nil,
        fileName: String = "",
        function: String = "",
        line: Int = 0
    ) {
        self.init(
            timestamp: timestamp,
            level: level,
            message: message,
            metadata: metadata,
            correlation: correlation,
            subsystem: subsystem,
            fileName: fileName,
            function: function,
            line: line,
            formatCache: nil
        )
    }

    internal init(
        timestamp: Date,
        level: LogLevel,
        message: String,
        metadata: LogMetadata?,
        correlation: String?,
        subsystem: String?,
        fileName: String,
        function: String,
        line: Int,
        formatCache: LogEntryFormatCache?
    ) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.metadata = metadata
        self.correlation = correlation
        self.subsystem = subsystem
        self.fileName = fileName
        self.function = function
        self.line = line
        self.formatCache = formatCache
    }

    /// Renders the entry in the library's default format.
    ///
    /// When several destinations share this entry the result is computed once
    /// and reused; a custom ``LogFormatter`` bypasses this entirely.
    public func format() -> String {
        if let formatCache {
            return formatCache.line(for: self)
        }
        return computeDefaultFormat()
    }

    internal func computeDefaultFormat() -> String {
        LogEntryFormatCache.noteComputation()

        let formattedTimestamp = TimestampFormatter.string(from: timestamp)

        var tags = ""
        if let corr = correlation {
            tags += "[\(corr)] "
        }
        if let sub = subsystem {
            tags += "[\(sub)] "
        }

        var body = "\(tags)\(message)"
        if let meta = metadata, !meta.isEmpty {
            body += " {\(Self.formatMetadata(meta))}"
        }

        return "\(level.tag) | \(formattedTimestamp) | \(fileName):\(line) | \(body)"
    }

    /// Renders metadata as `key=value` pairs ordered by key.
    ///
    /// Sorting the keys rather than the rendered pairs avoids building a
    /// throwaway string per entry just to order them, and sorts by what the
    /// ordering is actually meant to be keyed on.
    internal static func formatMetadata(_ metadata: LogMetadata) -> String {
        var result = ""
        var first = true
        for key in metadata.keys.sorted() {
            if !first { result += ", " }
            result += "\(key)=\(metadata[key]!)"
            first = false
        }
        return result
    }
}

/// Protocol for log output backends. Each destination owns its own
/// synchronization and receives entries after the global level gate passes.
///
/// Destinations may receive `write()` and `flush()` calls concurrently from
/// arbitrary threads. Conforming types must handle their own synchronization.
public protocol LogDestination: Sendable {
    var label: String { get }
    var isEnabled: Bool { get }
    var minimumLevel: LogLevel? { get }
    func write(_ entry: LogEntry)
    func flush()
}

public extension LogDestination {
    func flush() {}
    var minimumLevel: LogLevel? { nil }
}

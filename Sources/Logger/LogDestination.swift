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

    /// Builds the default line in a single reserved buffer.
    ///
    /// The output is byte-identical to the interpolation-per-part version this
    /// replaced (pinned by the characterization tests in `LogFormatterTests`);
    /// what changes is that the intermediate `tags` and `body` strings, and the
    /// separate metadata string, are gone. Every piece is appended straight
    /// into one buffer whose capacity is computed up front.
    internal func computeDefaultFormat() -> String {
        LogEntryFormatCache.noteComputation()

        let levelTag = level.tag
        let lineNumber = String(line)

        // "TAG | HH:mm:ss.SSS | file:line | " is the fixed scaffolding; the
        // rest is a close-enough estimate to avoid a reallocation.
        var capacity = levelTag.utf8.count + 3 + 12 + 3
            + fileName.utf8.count + 1 + lineNumber.utf8.count + 3
            + message.utf8.count
        if let correlation { capacity += correlation.utf8.count + 3 }
        if let subsystem { capacity += subsystem.utf8.count + 3 }
        if let metadata, !metadata.isEmpty { capacity += metadata.count * 24 + 2 }

        var out = ""
        out.reserveCapacity(capacity)

        out += levelTag
        out += " | "
        out += TimestampFormatter.string(from: timestamp)
        out += " | "
        out += fileName
        out += ":"
        out += lineNumber
        out += " | "
        if let correlation {
            out += "["
            Self.appendEscapingControlCharacters(correlation, to: &out)
            out += "] "
        }
        if let subsystem {
            out += "["
            Self.appendEscapingControlCharacters(subsystem, to: &out)
            out += "] "
        }
        out += message
        if let metadata, !metadata.isEmpty {
            out += " {"
            Self.appendMetadata(metadata, to: &out)
            out += "}"
        }

        return out
    }

    /// Appends `field` with C0 control characters rendered as escapes.
    ///
    /// The default format is one entry per line, so a newline inside a
    /// *structured* field — a correlation ID, a subsystem, a metadata value —
    /// lets attacker-controlled input forge whole log entries. Anything that
    /// reaches these fields from a request header, a username, or a URL can
    /// otherwise write a convincing fake line into the log.
    ///
    /// Deliberately NOT applied to `message`: the crash handler logs multi-line
    /// stack traces through it by design, and messages are documented as
    /// free-form. The JSON formatter escapes everything already.
    ///
    /// Clean fields — essentially all of them — are scanned once and appended
    /// whole, so this costs nothing in the normal case.
    internal static func appendEscapingControlCharacters(_ field: String, to out: inout String) {
        guard field.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
            out += field
            return
        }
        for scalar in field.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "\\u{"
                    out += String(scalar.value, radix: 16, uppercase: true)
                    out += "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
    }

    /// Appends metadata as `key=value` pairs ordered by key.
    ///
    /// Sorting the keys rather than the rendered pairs avoids building a
    /// throwaway string per entry just to order them, and sorts by what the
    /// ordering is actually meant to be keyed on.
    internal static func appendMetadata(_ metadata: LogMetadata, to out: inout String) {
        var first = true
        for key in metadata.keys.sorted() {
            if !first { out += ", " }
            // Keys as well as values: both can carry attacker-controlled text.
            appendEscapingControlCharacters(key, to: &out)
            out += "="
            appendEscapingControlCharacters(metadata[key]!.description, to: &out)
            first = false
        }
    }

    /// Renders metadata as `key=value` pairs ordered by key. Kept so callers
    /// that need the fragment on its own — `OSLogDestination` — stay consistent
    /// with the default text format.
    internal static func formatMetadata(_ metadata: LogMetadata) -> String {
        var result = ""
        appendMetadata(metadata, to: &result)
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

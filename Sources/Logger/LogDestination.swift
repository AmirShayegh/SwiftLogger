import Foundation

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
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.metadata = metadata
        self.correlation = correlation
        self.subsystem = subsystem
        self.fileName = fileName
        self.function = function
        self.line = line
    }

    public func format() -> String {
        let formattedTimestamp = Self.formatTimestamp(timestamp)

        var tags = ""
        if let corr = correlation {
            tags += "[\(corr)] "
        }
        if let sub = subsystem {
            tags += "[\(sub)] "
        }

        var body = "\(tags)\(message)"
        if let meta = metadata, !meta.isEmpty {
            let pairs = meta.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            body += " {\(pairs)}"
        }

        return "\(level.tag) | \(formattedTimestamp) | \(fileName):\(line) | \(body)"
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = Thread.current.threadDictionary["LoggerDateFormatter"] as? DateFormatter ?? {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            Thread.current.threadDictionary["LoggerDateFormatter"] = f
            return f
        }()
        return formatter.string(from: date)
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

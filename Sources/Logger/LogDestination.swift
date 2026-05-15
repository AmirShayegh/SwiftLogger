import Foundation

/// Structured representation of a single log event, passed to destinations.
struct LogEntry: Sendable {
    let timestamp: Date
    let level: LogLevel
    let message: String
    let metadata: LogMetadata?
    let correlation: String?
    let subsystem: String?
    let fileName: String
    let function: String
    let line: Int

    func format() -> String {
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

/// Internal protocol for log output backends. Each destination owns its own
/// synchronization and receives entries after the global level gate passes.
protocol LogDestination: Sendable {
    var label: String { get }
    var isEnabled: Bool { get }
    func write(_ entry: LogEntry)
    func flush()
}

extension LogDestination {
    func flush() {}
}

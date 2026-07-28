#if canImport(os)
import os
import Foundation

/// A log destination that forwards entries to Apple's unified logging system
/// via the modern `os.Logger` API.
///
/// All content is logged with `.public` privacy. Applications requiring private
/// log data should implement a custom `LogDestination` using `%{private}@`.
///
///     Log.addDestination(OSLogDestination(subsystem: "com.myapp", category: "networking"))
/// Every stored property is an immutable `Sendable` value — `os.Logger` is
/// itself `Sendable` — so this needs no `@unchecked` escape hatch and no lock.
public final class OSLogDestination: LogDestination, Sendable {
    public let label: String
    public let minimumLevel: LogLevel?
    public var isEnabled: Bool { true }

    private let osLogger: os.Logger

    public init(
        subsystem: String,
        category: String,
        label: String = "oslog",
        minimumLevel: LogLevel? = nil
    ) {
        self.label = label
        self.minimumLevel = minimumLevel
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
    }

    public func write(_ entry: LogEntry) {
        let message = Self.formatMessage(entry)

        switch Self.mapLevel(entry.level) {
        case .debug:   osLogger.debug("\(message, privacy: .public)")
        case .info:    osLogger.info("\(message, privacy: .public)")
        case .error:   osLogger.error("\(message, privacy: .public)")
        case .fault:   osLogger.fault("\(message, privacy: .public)")
        default:       osLogger.log("\(message, privacy: .public)")
        }
    }

    // MARK: - Level Mapping

    static func mapLevel(_ level: LogLevel) -> OSLogType {
        switch level {
        case .verbose: return .debug
        case .debug:   return .debug
        case .info:    return .info
        case .warning: return .default
        case .error:   return .error
        case .todo:    return .fault
        }
    }

    // MARK: - Message Formatting

    /// Structured fields are escaped for control characters, matching the
    /// default text format; the message itself stays free-form.
    internal static func formatMessage(_ entry: LogEntry) -> String {
        var parts: [String] = []

        if let corr = entry.correlation {
            var escaped = "["
            LogEntry.appendEscapingControlCharacters(corr, to: &escaped)
            parts.append(escaped + "]")
        }
        if let sub = entry.subsystem {
            var escaped = "["
            LogEntry.appendEscapingControlCharacters(sub, to: &escaped)
            parts.append(escaped + "]")
        }
        parts.append(entry.message)

        if let meta = entry.metadata, !meta.isEmpty {
            parts.append("{\(LogEntry.formatMetadata(meta))}")
        }

        return parts.joined(separator: " ")
    }
}
#endif

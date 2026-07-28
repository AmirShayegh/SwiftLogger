import Foundation

/// Renders a ``LogEntry`` as the line a destination writes.
///
/// Destinations take a formatter so the same entry can be human-readable on the
/// console and machine-parseable in a file:
///
///     Log.addDestination(ConsoleDestination())
///        .fileLogging(url: logURL, formatter: JSONLogFormatter())
public protocol LogFormatter: Sendable {
    func format(_ entry: LogEntry) -> String
}

/// The library's default layout:
///
///     LEVEL | HH:mm:ss.SSS | File.swift:42 | [correlation] [subsystem] message {key=value}
///
/// Entries fanning out to several destinations share one rendered line, so
/// using this formatter everywhere costs a single format per message.
public struct DefaultLogFormatter: LogFormatter {
    public init() {}

    public func format(_ entry: LogEntry) -> String {
        // Routes through LogEntry.format() rather than duplicating the layout,
        // so it picks up the shared per-entry cache.
        entry.format()
    }
}

/// Renders each entry as a single-line JSON object, for logs that are shipped
/// to an aggregator or parsed by tooling.
///
/// Keys are emitted in a fixed order — `timestamp`, `level`, `message`, then
/// the optional `correlation`, `subsystem`, `file`, `function`, `line`, and
/// `metadata` — so output diffs cleanly. Absent optionals are omitted rather
/// than written as null. Metadata values keep their JSON type: `LogValue.int`
/// becomes a number, `.bool` a boolean, and so on.
public struct JSONLogFormatter: LogFormatter {
    /// Whether timestamps are rendered as ISO 8601 with milliseconds
    /// (`2026-07-27T12:15:30.842Z`) or as a Unix epoch value in seconds.
    public enum TimestampStyle: Sendable {
        case iso8601
        case epochSeconds
    }

    public let timestampStyle: TimestampStyle

    public init(timestampStyle: TimestampStyle = .iso8601) {
        self.timestampStyle = timestampStyle
    }

    public func format(_ entry: LogEntry) -> String {
        var json = "{"

        switch timestampStyle {
        case .iso8601:
            appendString(&json, key: "timestamp", value: Self.iso8601(entry.timestamp), isFirst: true)
        case .epochSeconds:
            json += "\"timestamp\":\(entry.timestamp.timeIntervalSince1970)"
        }

        appendString(&json, key: "level", value: entry.level.rawValue)
        appendString(&json, key: "message", value: entry.message)

        if let correlation = entry.correlation {
            appendString(&json, key: "correlation", value: correlation)
        }
        if let subsystem = entry.subsystem {
            appendString(&json, key: "subsystem", value: subsystem)
        }
        if !entry.fileName.isEmpty {
            appendString(&json, key: "file", value: entry.fileName)
        }
        if !entry.function.isEmpty {
            appendString(&json, key: "function", value: entry.function)
        }
        json += ",\"line\":\(entry.line)"

        if let metadata = entry.metadata, !metadata.isEmpty {
            json += ",\"metadata\":{"
            var first = true
            for key in metadata.keys.sorted() {
                if !first { json += "," }
                json += "\(Self.quoted(key)):\(Self.jsonValue(metadata[key]!))"
                first = false
            }
            json += "}"
        }

        json += "}"
        return json
    }

    private func appendString(_ json: inout String, key: String, value: String, isFirst: Bool = false) {
        if !isFirst { json += "," }
        json += "\(Self.quoted(key)):\(Self.quoted(value))"
    }

    private static func jsonValue(_ value: LogValue) -> String {
        switch value {
        case .string(let s): return quoted(s)
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .double(let d):
            // JSON has no representation for these, so fall back to a string
            // rather than emitting something no parser will accept.
            guard d.isFinite else { return quoted(String(d)) }
            return String(d)
        }
    }

    /// Escapes per RFC 8259: the two mandatory escapes, the shorthand control
    /// characters, and `\u00XX` for the rest of C0.
    private static func quoted(_ string: String) -> String {
        var out = "\""
        out.reserveCapacity(string.utf8.count + 2)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // One shared formatter behind a lock. Allocating an ISO8601DateFormatter per
    // entry would cost more than everything else in this method combined, and
    // the class is not documented as thread-safe.
    private static let iso8601Lock = UnfairLock()
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func iso8601(_ date: Date) -> String {
        iso8601Lock.withLock { iso8601Formatter.string(from: date) }
    }
}

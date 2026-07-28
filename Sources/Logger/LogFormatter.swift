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
        var json = ""
        // Fixed scaffolding is ~90 bytes; the rest is a close-enough estimate
        // to avoid growing the buffer mid-render.
        var capacity = 96 + entry.message.utf8.count
            + entry.fileName.utf8.count + entry.function.utf8.count
        if let correlation = entry.correlation { capacity += correlation.utf8.count + 18 }
        if let subsystem = entry.subsystem { capacity += subsystem.utf8.count + 16 }
        if let metadata = entry.metadata { capacity += metadata.count * 24 + 14 }
        json.reserveCapacity(capacity)

        // The fixed keys are written as literals. They contain nothing the
        // escaper could change, so running them through it every time was pure
        // overhead — only values and user-supplied metadata keys need it.
        json += "{\"timestamp\":"
        switch timestampStyle {
        case .iso8601:
            Self.appendQuoted(Self.iso8601(entry.timestamp), to: &json)
        case .epochSeconds:
            json += String(entry.timestamp.timeIntervalSince1970)
        }

        json += ",\"level\":"
        Self.appendQuoted(entry.level.rawValue, to: &json)
        json += ",\"message\":"
        Self.appendQuoted(entry.message, to: &json)

        if let correlation = entry.correlation {
            json += ",\"correlation\":"
            Self.appendQuoted(correlation, to: &json)
        }
        if let subsystem = entry.subsystem {
            json += ",\"subsystem\":"
            Self.appendQuoted(subsystem, to: &json)
        }
        if !entry.fileName.isEmpty {
            json += ",\"file\":"
            Self.appendQuoted(entry.fileName, to: &json)
        }
        if !entry.function.isEmpty {
            json += ",\"function\":"
            Self.appendQuoted(entry.function, to: &json)
        }
        json += ",\"line\":"
        json += String(entry.line)

        if let metadata = entry.metadata, !metadata.isEmpty {
            json += ",\"metadata\":{"
            var first = true
            for key in metadata.keys.sorted() {
                if !first { json += "," }
                Self.appendQuoted(key, to: &json)
                json += ":"
                Self.appendValue(metadata[key]!, to: &json)
                first = false
            }
            json += "}"
        }

        json += "}"
        return json
    }

    private static func appendValue(_ value: LogValue, to out: inout String) {
        switch value {
        case .string(let s): appendQuoted(s, to: &out)
        case .int(let i): out += String(i)
        case .bool(let b): out += b ? "true" : "false"
        case .double(let d):
            // JSON has no representation for these, so fall back to a string
            // rather than emitting something no parser will accept.
            if d.isFinite { out += String(d) } else { appendQuoted(String(d), to: &out) }
        }
    }

    /// Appends `string` as a quoted JSON string, escaped per RFC 8259.
    ///
    /// Almost every string a logger sees contains nothing to escape, so it is
    /// scanned first and appended whole in that case. The scan works on UTF-8
    /// bytes, which is safe for non-ASCII text: every byte of a multi-byte
    /// scalar is >= 0x80, so no continuation byte can be mistaken for a quote,
    /// a backslash, or a control character.
    internal static func appendQuoted(_ string: String, to out: inout String) {
        out += "\""
        if string.utf8.contains(where: { $0 < 0x20 || $0 == 0x22 || $0 == 0x5C }) {
            appendEscaped(string, to: &out)
        } else {
            out += string
        }
        out += "\""
    }

    /// The cold path: the two mandatory escapes, the shorthand control
    /// characters, and `\u00XX` for the rest of C0.
    private static func appendEscaped(_ string: String, to out: inout String) {
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
                    // Everything reaching here is < 0x20, so the escape is
                    // always \u00 followed by two hex digits — no need for the
                    // general-purpose (and far slower) String(format:).
                    let byte = UInt8(scalar.value)
                    out += "\\u00"
                    out.unicodeScalars.append(hexDigit(byte >> 4))
                    out.unicodeScalars.append(hexDigit(byte & 0xF))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
    }

    /// Lowercase hex, matching what `String(format: "%04x")` produced.
    @inline(__always)
    private static func hexDigit(_ nibble: UInt8) -> Unicode.Scalar {
        Unicode.Scalar(nibble < 10 ? 0x30 + nibble : 0x61 + (nibble - 10))
    }

    private static func iso8601(_ date: Date) -> String {
        TimestampFormatter.iso8601String(from: date)
    }
}

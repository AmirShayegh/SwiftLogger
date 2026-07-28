import Testing
import Foundation
@testable import Logger

extension AllLoggerTests {

    struct LogFormatterTests {

        init() { Logger.shared.reset() }

        private func makeTempDir() throws -> URL {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("logger-fmt-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            return tmp
        }

        private func decode(_ line: String) throws -> [String: Any] {
            let data = Data(line.utf8)
            let object = try JSONSerialization.jsonObject(with: data)
            return try #require(object as? [String: Any])
        }

        // MARK: - Default formatter

        @Test func defaultFormatterMatchesEntryFormat() {
            let entry = LogEntry(
                level: .warning,
                message: "hello",
                metadata: ["k": 1],
                correlation: "corr",
                subsystem: "sub",
                fileName: "F.swift",
                line: 12
            )
            #expect(DefaultLogFormatter().format(entry) == entry.format())
        }

        // MARK: - JSON formatter

        @Test func jsonOutputIsValidAndCarriesEveryField() throws {
            let entry = LogEntry(
                timestamp: Date(timeIntervalSince1970: 1_752_003_661.234),
                level: .error,
                message: "something broke",
                metadata: ["count": 42, "ratio": 1.5, "ok": false, "name": "widget"],
                correlation: "req-7",
                subsystem: "network.api",
                fileName: "API.swift",
                function: "fetch()",
                line: 88
            )

            let json = try decode(JSONLogFormatter().format(entry))

            // Always UTC, regardless of the machine's zone.
            #expect(json["timestamp"] as? String == "2025-07-08T19:41:01.234Z")
            #expect(json["level"] as? String == "ERROR")
            #expect(json["message"] as? String == "something broke")
            #expect(json["correlation"] as? String == "req-7")
            #expect(json["subsystem"] as? String == "network.api")
            #expect(json["file"] as? String == "API.swift")
            #expect(json["function"] as? String == "fetch()")
            #expect(json["line"] as? Int == 88)

            let metadata = try #require(json["metadata"] as? [String: Any])
            // Metadata values keep their JSON types rather than all becoming strings.
            #expect(metadata["count"] as? Int == 42)
            #expect(metadata["ratio"] as? Double == 1.5)
            #expect(metadata["ok"] as? Bool == false)
            #expect(metadata["name"] as? String == "widget")
        }

        @Test func jsonOmitsAbsentOptionalsRatherThanEmittingNull() throws {
            let entry = LogEntry(level: .info, message: "bare")
            let line = JSONLogFormatter().format(entry)
            let json = try decode(line)

            #expect(json["correlation"] == nil)
            #expect(json["subsystem"] == nil)
            #expect(json["metadata"] == nil)
            // fileName/function default to "" and are skipped too.
            #expect(json["file"] == nil)
            #expect(json["function"] == nil)
            #expect(!line.contains("null"))
        }

        @Test func jsonEscapesControlCharactersAndQuotes() throws {
            let entry = LogEntry(
                level: .info,
                message: "quote:\" backslash:\\ newline:\n tab:\t bell:\u{07}",
                metadata: ["tricky\"key": "line1\nline2"]
            )
            let json = try decode(JSONLogFormatter().format(entry))

            #expect(json["message"] as? String == "quote:\" backslash:\\ newline:\n tab:\t bell:\u{07}")
            let metadata = try #require(json["metadata"] as? [String: Any])
            #expect(metadata["tricky\"key"] as? String == "line1\nline2")
        }

        @Test func jsonHandlesNonFiniteDoublesWithoutProducingInvalidJSON() throws {
            let entry = LogEntry(
                level: .info,
                message: "edge",
                metadata: ["inf": .double(.infinity), "nan": .double(.nan)]
            )
            // JSON has no literal for these; they must not break the parse.
            let json = try decode(JSONLogFormatter().format(entry))
            let metadata = try #require(json["metadata"] as? [String: Any])
            #expect(metadata["inf"] as? String == "inf")
            #expect(metadata["nan"] as? String == "nan")
        }

        @Test func jsonEpochTimestampStyle() throws {
            let entry = LogEntry(
                timestamp: Date(timeIntervalSince1970: 1_752_003_661.5),
                level: .info,
                message: "epoch"
            )
            let json = try decode(JSONLogFormatter(timestampStyle: .epochSeconds).format(entry))
            #expect(json["timestamp"] as? Double == 1_752_003_661.5)
        }

        @Test func jsonKeyOrderIsStable() {
            let entry = LogEntry(
                level: .info,
                message: "m",
                metadata: ["b": 2, "a": 1, "c": 3],
                correlation: "c1",
                subsystem: "s"
            )
            let formatter = JSONLogFormatter()
            // Same input, same bytes — output diffs cleanly across runs.
            #expect(formatter.format(entry) == formatter.format(entry))
            #expect(formatter.format(entry).contains("\"metadata\":{\"a\":1,\"b\":2,\"c\":3}"))
        }

        @Test func jsonOutputIsSingleLinePerEntry() {
            let entry = LogEntry(level: .info, message: "multi\nline\nmessage")
            let line = JSONLogFormatter().format(entry)
            #expect(!line.contains("\n"))
        }

        // MARK: - Destination integration

        @Test func fileDestinationWritesJSONLines() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("json.log")

            Logger.shared.consoleLogging(false)
            Logger.shared.fileLogging(url: url, label: "json", formatter: JSONLogFormatter())

            Logger.shared.log("first", level: .info, metadata: ["n": 1])
            Logger.shared.log("second", level: .error)
            Logger.shared.flush()

            let lines = (try String(contentsOf: url, encoding: .utf8))
                .split(separator: "\n", omittingEmptySubsequences: true)
            #expect(lines.count == 2)

            // Every line stands alone as a JSON object — the point of JSON lines.
            let first = try decode(String(lines[0]))
            let second = try decode(String(lines[1]))
            #expect(first["message"] as? String == "first")
            #expect(second["message"] as? String == "second")
            #expect(second["level"] as? String == "ERROR")
        }

        @Test func consoleAndFileCanUseDifferentFormatters() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("mixed.log")

            var consoleLines: [String] = []
            Logger.shared.consoleLogging(false)
            Logger.shared.setOutputSink { consoleLines.append($0) }
            Logger.shared.fileLogging(url: url, label: "json", formatter: JSONLogFormatter())

            Logger.shared.log("dual", level: .warning)
            Logger.shared.flush()

            // Human-readable on the console, machine-readable on disk.
            #expect(consoleLines.count == 1)
            #expect(consoleLines[0].contains(" WARN |"))

            let fileLine = (try String(contentsOf: url, encoding: .utf8))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(try decode(fileLine)["message"] as? String == "dual")
        }

        @Test func droppedNoticeUsesTheDestinationFormatter() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("dropped.log")

            let fd = FileDestination(
                url: url,
                formatter: JSONLogFormatter(),
                tunables: .init(maxBufferedEntries: 2, flushInterval: 600, flushByteThreshold: 1_000_000)
            )!

            for i in 0..<5 { fd.write(LogEntry(level: .info, message: "e\(i)")) }
            fd.flush()

            let lines = (try String(contentsOf: url, encoding: .utf8))
                .split(separator: "\n", omittingEmptySubsequences: true)

            // The overflow notice must be parseable like every other line, not
            // plain text wedged into a JSON log.
            let notice = try decode(String(lines[lines.count - 1]))
            let message = try #require(notice["message"] as? String)
            #expect(message.contains("dropped 3 messages"))
        }

        @Test func customFormatterIsUsedVerbatim() throws {
            struct MinimalFormatter: LogFormatter {
                func format(_ entry: LogEntry) -> String { "<\(entry.level.rawValue)>\(entry.message)" }
            }

            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("custom.log")

            let fd = FileDestination(url: url, formatter: MinimalFormatter())!
            fd.write(LogEntry(level: .info, message: "terse"))
            fd.flush()

            #expect(try String(contentsOf: url, encoding: .utf8) == "<INFO>terse\n")
        }

        // MARK: - JSON escaping

        /// The pre-optimisation escaper, kept here verbatim as an independent
        /// reference implementation. The fast-path scanner must agree with it
        /// on every input — that is the whole safety argument for skipping the
        /// per-scalar walk.
        private static func legacyQuoted(_ string: String) -> String {
            var out = "\""
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

        private func quoted(_ string: String) -> String {
            var out = ""
            JSONLogFormatter.appendQuoted(string, to: &out)
            return out
        }

        @Test func jsonQuotedMatchesLegacyEscaperOnAdversarialTable() {
            let cases: [String] = [
                "",
                "plain",
                "\"", "\\", "\n", "\r", "\t", "\u{08}", "\u{0C}",
                "\u{00}", "\u{01}", "\u{07}", "\u{0B}", "\u{0E}", "\u{1F}",
                "\u{7F}",                       // DEL is NOT escaped by JSON
                "leading\"quote", "trailing\\", "\nleading-newline", "trailing-newline\n",
                "mixed \" and \\ and \n together",
                "héllo wörld", "🌍🌏", "日本語のログ", "e\u{0301}gal",
                "emoji\u{0}with\u{1}nulls🌍",
                "line1\r\nline2",
                String(repeating: "a", count: 200),
                String(repeating: "\"", count: 20),
                "\u{1F}\u{1E}\u{1D}\u{1C}",
                "tab\tin\tthe\tmiddle",
            ]
            for input in cases {
                #expect(quoted(input) == Self.legacyQuoted(input), "diverged on \(input.debugDescription)")
            }
        }

        @Test func jsonControlEscapesKeepLowercaseFourDigitForm() {
            #expect(quoted("\u{01}") == "\"\\u0001\"")
            #expect(quoted("\u{1F}") == "\"\\u001f\"")
            #expect(quoted("\u{0B}") == "\"\\u000b\"")
            #expect(quoted("\u{00}") == "\"\\u0000\"")
        }

        @Test func jsonFastPathPreservesMultiByteStringsVerbatim() {
            // Every byte of a multi-byte scalar is >= 0x80, so the byte-level
            // scan can never mistake one for a control character — these must
            // take the fast path and come through untouched.
            #expect(quoted("héllo 🌍 日本語") == "\"héllo 🌍 日本語\"")
            #expect(quoted("\u{7F}") == "\"\u{7F}\"")
        }

        @Test func jsonEscapesAtFirstAndLastPosition() {
            #expect(quoted("\nstart") == "\"\\nstart\"")
            #expect(quoted("end\n") == "\"end\\n\"")
            #expect(quoted("\"") == "\"\\\"\"")
        }

        @Test func jsonEscapedOutputStillParses() throws {
            let entry = LogEntry(
                level: .error,
                message: "he said \"hi\"\nthen \\left\u{01}",
                metadata: ["key\"with quote": "value\nwith newline"],
                correlation: "c\t1",
                subsystem: "sub\\system",
                fileName: "F.swift",
                line: 1
            )
            let object = try decode(JSONLogFormatter().format(entry))
            #expect(object["message"] as? String == "he said \"hi\"\nthen \\left\u{01}")
            #expect(object["correlation"] as? String == "c\t1")
            #expect(object["subsystem"] as? String == "sub\\system")
            let metadata = try #require(object["metadata"] as? [String: Any])
            #expect(metadata["key\"with quote"] as? String == "value\nwith newline")
        }

        // MARK: - Log injection

        @Test func forgedLineViaMetadataValueStaysOnOneLine() {
            // The classic log-injection payload: a newline plus a plausible
            // second entry. Anything reaching metadata from a request header, a
            // username, or a URL is attacker-controlled, and the default format
            // is one entry per line — so an unescaped newline writes a fake log
            // entry that a human or a parser will believe.
            let entry = LogEntry(
                level: .info,
                message: "login",
                metadata: ["user": "bob\n INFO | 00:00:00.000 | Auth.swift:1 | admin granted"],
                fileName: "Auth.swift",
                line: 4
            )
            let line = entry.format()
            #expect(!line.contains("\n"))
            #expect(line.contains("\\n"))
            #expect(line.hasSuffix("admin granted}"))
        }

        @Test func forgedLineViaCorrelationOrSubsystemStaysOnOneLine() {
            let entry = LogEntry(
                level: .info,
                message: "m",
                correlation: "c\r\nforged",
                subsystem: "sub\nforged",
                fileName: "F.swift",
                line: 1
            )
            let line = entry.format()
            #expect(!line.contains("\n"))
            #expect(!line.contains("\r"))
            #expect(line.contains("[c\\r\\nforged]"))
            #expect(line.contains("[sub\\nforged]"))
        }

        @Test func metadataKeysAreEscapedToo() {
            let entry = LogEntry(level: .info, message: "m", metadata: ["a\nb": 1])
            let line = entry.format()
            #expect(!line.contains("\n"))
            #expect(line.contains("{a\\nb=1}"))
        }

        @Test func otherControlCharactersRenderAsUnicodeEscapes() {
            let entry = LogEntry(level: .info, message: "m", metadata: ["k": "a\u{07}b\u{00}c\u{7F}d\te"])
            let line = entry.format()
            #expect(line.contains("a\\u{7}b\\u{0}c\\u{7F}d\\te"))
        }

        @Test func cleanFieldsAreUntouchedByEscaping() {
            // The fast path must not disturb ordinary text, including non-ASCII.
            let entry = LogEntry(
                level: .info,
                message: "m",
                metadata: ["path": "/users/José/naïve 🌍"],
                correlation: "req-42",
                subsystem: "net.api",
                fileName: "F.swift",
                line: 1
            )
            let line = entry.format()
            #expect(line.contains("[req-42] [net.api]"))
            #expect(line.contains("{path=/users/José/naïve 🌍}"))
        }

        @Test func multiLineMessagesStillRenderMultiLine() {
            // Messages are free-form on purpose: the uncaught-exception handler
            // logs a whole stack trace through one. Escaping it would turn every
            // crash report into an unreadable single line.
            let trace = "Crash occurred:\nException Name: NSInvalidArgument\nStack Trace:\n0  frame\n1  frame"
            let entry = LogEntry(level: .error, message: trace, fileName: "Logger.swift", line: 1)
            let line = entry.format()
            #expect(line.contains("\n"))
            #expect(line.hasSuffix("1  frame"))
        }

        // MARK: - Default format, byte for byte

        // Characterization pins for the default text line. Every separator,
        // space, and bracket is asserted literally, so a rewrite of the
        // formatter that changes the output by even one character fails here
        // rather than silently breaking everyone's log parsers. The timestamp
        // is spliced in from TimestampFormatter rather than hardcoded, so these
        // are independent of the machine's time zone.

        @Test func defaultFormatExactLineShape() {
            let timestamp = Date(timeIntervalSince1970: 1_752_003_661.234)
            let entry = LogEntry(
                timestamp: timestamp,
                level: .warning,
                message: "hello",
                metadata: ["k": 1],
                correlation: "corr",
                subsystem: "sub",
                fileName: "F.swift",
                function: "f()",
                line: 12
            )

            let ts = TimestampFormatter.string(from: timestamp)
            #expect(entry.format() == " WARN | \(ts) | F.swift:12 | [corr] [sub] hello {k=1}")
        }

        @Test func defaultFormatExactLineShapeWithoutTags() {
            let timestamp = Date(timeIntervalSince1970: 1_752_003_661.234)
            let entry = LogEntry(
                timestamp: timestamp,
                level: .error,
                message: "plain",
                fileName: "G.swift",
                line: 3
            )

            let ts = TimestampFormatter.string(from: timestamp)
            #expect(entry.format() == "ERROR | \(ts) | G.swift:3 | plain")
        }

        @Test func defaultFormatOmitsEmptyMetadataBraces() {
            let timestamp = Date(timeIntervalSince1970: 1_752_003_661.234)
            let entry = LogEntry(
                timestamp: timestamp,
                level: .info,
                message: "no meta",
                metadata: [:],
                correlation: "c-1",
                fileName: "H.swift",
                line: 1
            )

            let ts = TimestampFormatter.string(from: timestamp)
            #expect(entry.format() == " INFO | \(ts) | H.swift:1 | [c-1] no meta")
        }

        @Test func defaultFormatRendersEveryLevelTagAtFixedWidth() {
            let timestamp = Date(timeIntervalSince1970: 1_752_003_661.234)
            let ts = TimestampFormatter.string(from: timestamp)
            let expected: [(LogLevel, String)] = [
                (.verbose, "TRACE"),
                (.debug, "DEBUG"),
                (.info, " INFO"),
                (.warning, " WARN"),
                (.error, "ERROR"),
                (.todo, " TODO"),
            ]
            for (level, tag) in expected {
                let entry = LogEntry(
                    timestamp: timestamp, level: level, message: "m", fileName: "I.swift", line: 9
                )
                #expect(entry.format() == "\(tag) | \(ts) | I.swift:9 | m")
            }
        }

        @Test func defaultFormatSortsMetadataAndSeparatesWithCommaSpace() {
            let entry = LogEntry(
                level: .info,
                message: "m",
                metadata: ["zebra": 1, "alpha": "a", "middle": true, "delta": 2.5]
            )
            #expect(entry.format().hasSuffix(" | m {alpha=a, delta=2.5, middle=true, zebra=1}"))
        }

        @Test func multiByteMessagesSurviveLineEncodingIntact() throws {
            struct PassthroughFormatter: LogFormatter {
                func format(_ entry: LogEntry) -> String { entry.message }
            }

            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("unicode.log")

            // The line encoder memcpys UTF-8 out of the String's contiguous
            // storage rather than going through an intermediate String, so
            // multi-byte scalars and combining marks are worth pinning: a
            // count/byte mismatch would truncate exactly here.
            let messages = ["héllo wörld", "🌍🌏 emoji", "日本語のログ", "e\u{0301}gal"]
            let fd = FileDestination(url: url, formatter: PassthroughFormatter())!
            for message in messages {
                fd.write(LogEntry(level: .info, message: message))
            }
            fd.flush()

            #expect(try String(contentsOf: url, encoding: .utf8) == messages.joined(separator: "\n") + "\n")
        }
    }
}

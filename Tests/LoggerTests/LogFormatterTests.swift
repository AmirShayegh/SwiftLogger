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

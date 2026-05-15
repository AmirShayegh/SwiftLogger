import Testing
import Foundation
@testable import Logger

final class MockDestination: LogDestination, @unchecked Sendable {
    let label: String
    let minimumLevel: LogLevel?
    var isEnabled: Bool { true }
    private let lock = NSLock()
    private var _entries: [LogEntry] = []

    var entries: [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    init(label: String = "mock", minimumLevel: LogLevel? = nil) {
        self.label = label
        self.minimumLevel = minimumLevel
    }

    func write(_ entry: LogEntry) {
        lock.lock()
        _entries.append(entry)
        lock.unlock()
    }
}

extension AllLoggerTests {

    struct DestinationTests {

        init() { Logger.shared.reset() }

        @Test func addCustomDestinationReceivesEntries() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("hello", level: .info)

            #expect(mock.entries.count == 1)
            #expect(mock.entries[0].message == "hello")
            #expect(mock.entries[0].level == .info)
        }

        @Test func removeDestinationStopsReceiving() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.removeDestination(label: "mock")
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("should not arrive", level: .info)

            #expect(mock.entries.isEmpty)
        }

        @Test func sameLabelReplacement() {
            Logger.shared.consoleLogging(false)
            let first = MockDestination(label: "test")
            let second = MockDestination(label: "test")
            Logger.shared.addDestination(first)
            Logger.shared.addDestination(second)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("msg", level: .info)

            #expect(first.entries.isEmpty)
            #expect(second.entries.count == 1)
        }

        @Test func perDestinationMinimumLevelFilters() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination(label: "strict", minimumLevel: .warning)
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("debug msg", level: .debug)
            Logger.shared.log("warning msg", level: .warning)
            Logger.shared.log("error msg", level: .error)

            #expect(mock.entries.count == 2)
            #expect(mock.entries[0].message == "warning msg")
            #expect(mock.entries[1].message == "error msg")
        }

        @Test func globalGateStillApplies() {
            Logger.shared.consoleLogging(false)
            Logger.shared.minimumLevel(.error)
            let mock = MockDestination(label: "permissive", minimumLevel: .debug)
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("should be filtered", level: .info)

            #expect(mock.entries.isEmpty)
        }

        @Test func multipleDestinationsDifferentLevels() {
            Logger.shared.consoleLogging(false)
            let all = MockDestination(label: "all")
            let errorsOnly = MockDestination(label: "errors", minimumLevel: .error)
            Logger.shared.addDestination(all)
            Logger.shared.addDestination(errorsOnly)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("debug", level: .debug)
            Logger.shared.log("error", level: .error)

            #expect(all.entries.count == 2)
            #expect(errorsOnly.entries.count == 1)
            #expect(errorsOnly.entries[0].message == "error")
        }

        @Test func addDestinationFluentChaining() {
            let mock = MockDestination()
            let result = Logger.shared.addDestination(mock)
            #expect(result === Logger.shared)
        }

        @Test func removeDestinationFluentChaining() {
            let result = Logger.shared.removeDestination(label: "nonexistent")
            #expect(result === Logger.shared)
        }

        @Test func logEntryPublicInit() {
            let entry = LogEntry(level: .warning, message: "test")
            #expect(entry.level == .warning)
            #expect(entry.message == "test")
            #expect(entry.metadata == nil)
            #expect(entry.correlation == nil)
            #expect(entry.subsystem == nil)

            let formatted = entry.format()
            #expect(formatted.contains(" WARN"))
            #expect(formatted.contains("test"))
        }

        @Test func logEntryFormatIncludesAllFields() {
            let entry = LogEntry(
                level: .debug,
                message: "decoded",
                metadata: ["pts": 42],
                correlation: "job-1",
                subsystem: "decoder",
                fileName: "Test.swift",
                line: 99
            )
            let formatted = entry.format()
            #expect(formatted.contains("DEBUG"))
            #expect(formatted.contains("[job-1]"))
            #expect(formatted.contains("[decoder]"))
            #expect(formatted.contains("decoded"))
            #expect(formatted.contains("{pts=42}"))
            #expect(formatted.contains("Test.swift:99"))
        }

        @Test func fileDestinationCustomURL() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let logURL = tmp.appendingPathComponent("test.log")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let fd = FileDestination(url: logURL)
            #expect(fd != nil)
            #expect(fd!.label == "file")

            fd!.write(LogEntry(level: .info, message: "hello file"))
            fd!.flush()

            let content = try String(contentsOf: logURL, encoding: .utf8)
            #expect(content.contains("hello file"))
        }

        @Test func consoleDestinationPublicInit() {
            let console = ConsoleDestination(minimumLevel: .warning)
            #expect(console.label == "console")
            #expect(console.minimumLevel == .warning)
        }
    }
}

#if canImport(os)
import Testing
import os
@testable import Logger

extension AllLoggerTests {

    struct OSLogDestinationTests {

        init() { Logger.shared.reset() }

        @Test func initSetsProperties() {
            let dest = OSLogDestination(subsystem: "com.test", category: "general")
            #expect(dest.label == "oslog")
            #expect(dest.minimumLevel == nil)
            #expect(dest.isEnabled)
        }

        @Test func initWithCustomLabel() {
            let dest = OSLogDestination(subsystem: "com.test", category: "net", label: "custom-os", minimumLevel: .warning)
            #expect(dest.label == "custom-os")
            #expect(dest.minimumLevel == .warning)
        }

        @Test func levelMappingCoversAllLevels() {
            #expect(OSLogDestination.mapLevel(.verbose) == .debug)
            #expect(OSLogDestination.mapLevel(.debug) == .debug)
            #expect(OSLogDestination.mapLevel(.info) == .info)
            #expect(OSLogDestination.mapLevel(.warning) == .default)
            #expect(OSLogDestination.mapLevel(.error) == .error)
            #expect(OSLogDestination.mapLevel(.todo) == .fault)
        }

        @Test func fluentConvenienceReturnsShared() {
            let result = Logger.shared.osLogDestination(subsystem: "com.test", category: "test")
            #expect(result === Logger.shared)
        }

        @Test func writeDoesNotCrash() {
            let dest = OSLogDestination(subsystem: "com.test.logger", category: "unit-test")
            let entry = LogEntry(
                level: .info,
                message: "test message",
                metadata: ["key": "value"],
                correlation: "corr-1",
                subsystem: "test"
            )
            dest.write(entry)
        }

        // MARK: - Message Formatting

        // os.Logger swallows what it is handed, so the only way to pin the
        // rendering is to call the formatter directly. Without these the
        // subsystem/correlation escaping added for log injection had no
        // coverage on this path at all.

        @Test func formatMessageJoinsCorrelationSubsystemMessageAndSortedMetadata() {
            let line = OSLogDestination.formatMessage(
                LogEntry(
                    level: .info,
                    message: "req done",
                    metadata: ["b": 2, "a": 1],
                    correlation: "corr-1",
                    subsystem: "net.api"
                )
            )
            #expect(line == "[corr-1] [net.api] req done {a=1, b=2}")
        }

        @Test func formatMessageOmitsAbsentParts() {
            #expect(OSLogDestination.formatMessage(LogEntry(level: .info, message: "bare")) == "bare")
            #expect(
                OSLogDestination.formatMessage(
                    LogEntry(level: .info, message: "tagged", subsystem: "net")
                ) == "[net] tagged"
            )
            #expect(
                OSLogDestination.formatMessage(
                    LogEntry(level: .info, message: "tagged", correlation: "c-9")
                ) == "[c-9] tagged"
            )
        }

        @Test func formatMessageSkipsEmptyMetadata() {
            let line = OSLogDestination.formatMessage(
                LogEntry(level: .info, message: "no fields", metadata: [:])
            )
            #expect(line == "no fields")
        }

        @Test func formatMessageEscapesControlCharactersInStructuredFields() {
            let line = OSLogDestination.formatMessage(
                LogEntry(
                    level: .info,
                    message: "ok",
                    metadata: ["note": "line1\nline2"],
                    correlation: "c\n1",
                    subsystem: "net\ttab"
                )
            )
            // A forged newline in a structured field must not split the entry
            // into two apparent log lines in Console.app.
            #expect(!line.contains("\n"))
            #expect(line.contains("\\n"))
            #expect(line.contains("\\t"))
        }
    }
}
#endif

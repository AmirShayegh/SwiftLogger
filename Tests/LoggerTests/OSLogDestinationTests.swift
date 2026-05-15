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
    }
}
#endif

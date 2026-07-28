import Testing
import Logging
@testable import Logger

extension AllLoggerTests {

    struct SwiftLogHandlerTests {

        init() { Logger.shared.reset() }

        private func makeHandler(label: String = "test") -> SwiftLogHandler {
            SwiftLogHandler(label: label)
        }

        private func makeEvent(
            level: Logging.Logger.Level = .info,
            message: String = "test",
            metadata: Logging.Logger.Metadata? = nil,
            file: String = "Test.swift",
            function: String = "testFunc()",
            line: UInt = 42
        ) -> LogEvent {
            LogEvent(level: level, message: "\(message)", metadata: metadata, source: nil, file: file, function: function, line: line)
        }

        @Test func handlerForwardsToMockDestination() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            let handler = makeHandler(label: "com.test.module")
            handler.log(event: makeEvent(message: "hello from swift-log"))

            #expect(mock.entries.count == 1)
            #expect(mock.entries[0].message == "hello from swift-log")
            #expect(mock.entries[0].subsystem == "com.test.module")
        }

        @Test func levelMappingCoversAllSwiftLogLevels() {
            #expect(SwiftLogHandler.mapLevel(.trace) == .verbose)
            #expect(SwiftLogHandler.mapLevel(.debug) == .debug)
            #expect(SwiftLogHandler.mapLevel(.info) == .info)
            #expect(SwiftLogHandler.mapLevel(.notice) == .info)
            #expect(SwiftLogHandler.mapLevel(.warning) == .warning)
            #expect(SwiftLogHandler.mapLevel(.error) == .error)
            #expect(SwiftLogHandler.mapLevel(.critical) == .error)
        }

        @Test func arrayMetadataPreservesOrder() {
            let value = SwiftLogHandler.mapMetadataValue(.array(["step10", "step2", "step1"]))
            #expect(value.description == "[step10, step2, step1]")
        }

        @Test func dictionaryMetadataIsSortedForDeterminism() {
            let value = SwiftLogHandler.mapMetadataValue(.dictionary(["b": "2", "a": "1"]))
            #expect(value.description == "{a=1, b=2}")
        }

        @Test func metadataBridging() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            let handler = makeHandler()
            handler.log(event: makeEvent(metadata: ["key": "value", "count": "42"]))

            #expect(mock.entries.count == 1)
            let meta = mock.entries[0].metadata
            #expect(meta != nil)
            #expect(meta?["key"]?.description == "value")
            #expect(meta?["count"]?.description == "42")
        }

        @Test func perMessageMetadataOverridesHandler() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            var handler = makeHandler()
            handler.metadata = ["env": "staging", "app": "myapp"]
            handler.log(event: makeEvent(metadata: ["env": "production"]))

            #expect(mock.entries.count == 1)
            #expect(mock.entries[0].metadata?["env"]?.description == "production")
            #expect(mock.entries[0].metadata?["app"]?.description == "myapp")
        }

        @Test func labelBecomesSubsystem() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            let handler = makeHandler(label: "network.api")
            handler.log(event: makeEvent(message: "request sent"))

            #expect(mock.entries.count == 1)
            #expect(mock.entries[0].subsystem == "network.api")
        }

        @Test func subsystemFilteringWorksForSwiftLogMessages() {
            Logger.shared.consoleLogging(false)
            Logger.shared.minimumLevel(.error)
            Logger.shared.subsystem("decoder", level: .debug)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            let decoderHandler = makeHandler(label: "decoder")
            decoderHandler.log(event: makeEvent(level: .debug, message: "should pass via subsystem"))

            let encoderHandler = makeHandler(label: "encoder")
            encoderHandler.log(event: makeEvent(level: .debug, message: "should be filtered"))

            #expect(mock.entries.count == 1)
            #expect(mock.entries[0].message == "should pass via subsystem")
        }

        @Test func metadataSubscript() {
            var handler = makeHandler()
            handler[metadataKey: "request-id"] = "abc123"
            #expect(handler[metadataKey: "request-id"] == "abc123")
            handler[metadataKey: "request-id"] = nil
            #expect(handler[metadataKey: "request-id"] == nil)
        }

        // A distinct error type so its `String(describing:)` is easy to assert on.
        private struct SampleError: Error, CustomStringConvertible {
            var description: String { "sample-error-detail" }
        }

        @Test func errorParameterIsBridgedToMetadata() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            // Drive the real swift-log frontend; `Logger(label:factory:)` avoids
            // the once-per-process `LoggingSystem.bootstrap`.
            let error = SampleError()
            let swiftLog = Logging.Logger(label: "test.err") { SwiftLogHandler(label: $0) }
            swiftLog.error("boom", error: error)

            #expect(mock.entries.count == 1)
            #expect(mock.entries[0].metadata?["error"]?.description == String(describing: error))
        }

        @Test func explicitErrorMetadataKeyWins() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            let swiftLog = Logging.Logger(label: "test.err") { SwiftLogHandler(label: $0) }
            swiftLog.error("boom", error: SampleError(), metadata: ["error": "explicit"])

            #expect(mock.entries.count == 1)
            #expect(mock.entries[0].metadata?["error"]?.description == "explicit")
        }

        @Test func debugMessagesReachPipelineByDefault() {
            Logger.shared.consoleLogging(false)
            // Allow the whole range through this library's pipeline so the only
            // possible gate is the handler's swift-log-side `logLevel`.
            Logger.shared.minimumLevel(.verbose)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            // Default handler: no swift-log-side pre-filtering, so both .debug and
            // .trace reach the mock destination.
            let swiftLog = Logging.Logger(label: "test.pipeline") { SwiftLogHandler(label: $0) }
            swiftLog.debug("debug msg")
            swiftLog.trace("trace msg")

            #expect(mock.entries.count == 2)
            #expect(mock.entries.contains { $0.message == "debug msg" })
            #expect(mock.entries.contains { $0.message == "trace msg" })

            // Escape hatch: a handler built with a higher level pre-filters on the
            // swift-log side, so .info never reaches the pipeline.
            let filtered = Logging.Logger(label: "test.filtered") { SwiftLogHandler(label: $0, level: .warning) }
            filtered.info("info msg")

            #expect(!mock.entries.contains { $0.message == "info msg" })
        }
    }
}

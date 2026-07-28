import Testing
import Logging
import Foundation
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

        // MARK: - Pre-filtering

        /// Counts how many times its `description` is read, so a test can prove
        /// a filtered message never stringified it.
        private final class CountingConvertible: CustomStringConvertible, @unchecked Sendable {
            private let lock = NSLock()
            private var _reads = 0
            var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
            var description: String {
                lock.lock(); _reads += 1; lock.unlock()
                return "expensive"
            }
        }

        private struct CountingError: Error, CustomStringConvertible {
            let probe: CountingConvertible
            var description: String { probe.description }
        }

        @Test func filteredBridgedMessageDoesNotBridgeMetadata() {
            Logger.shared.consoleLogging(false)
            Logger.shared.minimumLevel(.error)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            let probe = CountingConvertible()
            let handler = makeHandler(label: "bridge.filter")
            handler.log(event: makeEvent(
                level: .debug,
                message: "filtered out",
                metadata: ["expensive": .stringConvertible(probe)]
            ))

            #expect(mock.entries.isEmpty)
            // The whole point: a message that will be discarded must not pay to
            // convert its metadata first.
            #expect(probe.reads == 0)
        }

        @Test func filteredBridgedMessageSkipsErrorStringification() {
            Logger.shared.consoleLogging(false)
            Logger.shared.minimumLevel(.error)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            let probe = CountingConvertible()
            var handler = makeHandler(label: "bridge.error")
            handler.logLevel = .trace
            handler.log(event: LogEvent(
                level: .debug,
                message: "filtered out",
                error: CountingError(probe: probe),
                metadata: nil,
                source: nil,
                file: "Test.swift",
                function: "f()",
                line: 1
            ))

            #expect(mock.entries.isEmpty)
            #expect(probe.reads == 0)
        }

        @Test func passingBridgedMessageStillBridgesMetadataAndError() {
            Logger.shared.consoleLogging(false)
            Logger.shared.minimumLevel(.debug)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            let handler = makeHandler(label: "bridge.pass")
            handler.log(event: LogEvent(
                level: .warning,
                message: "kept",
                error: SampleError(),
                metadata: ["k": "v"],
                source: nil,
                file: "Test.swift",
                function: "f()",
                line: 1
            ))

            #expect(mock.entries.count == 1)
            let metadata = mock.entries[0].metadata
            #expect(metadata?["k"]?.description == "v")
            #expect(metadata?["error"]?.description == "sample-error-detail")
        }

        @Test func preFilterRespectsSubsystemLevelsNotJustTheGlobalMinimum() {
            Logger.shared.consoleLogging(false)
            // Global minimum would reject .debug, but the subsystem level — which
            // is the swift-log label — permits it. A pre-filter that only
            // consulted the global minimum would wrongly drop this.
            Logger.shared.minimumLevel(.error).subsystem("chatty.module", level: .debug)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            let handler = makeHandler(label: "chatty.module")
            handler.log(event: makeEvent(level: .debug, message: "kept", metadata: ["k": "v"]))

            #expect(mock.entries.count == 1)
            #expect(mock.entries[0].message == "kept")
        }

        @Test func wouldLogAgreesWithLogMessageGate() {
            Logger.shared.consoleLogging(false)
            Logger.shared.setOutputSink { _ in }
            Logger.shared
                .minimumLevel(.info)
                .subsystem("net", level: .warning)
                .subsystem("net.debug", level: .verbose)
                .logLevel(.error, forFile: "Loud.swift")

            let mock = MockDestination()
            Logger.shared.addDestination(mock)

            let levels: [LogLevel] = [.verbose, .debug, .info, .warning, .error, .todo]
            let subsystems: [String?] = [nil, "net", "net.debug", "net.http", "other"]
            let files = ["Quiet.swift", "Loud.swift", "Module/Loud.swift"]

            // wouldLog is a second implementation of the same gate, so it is
            // checked against the ground truth — whether the message actually
            // reached a destination — for every combination. This is what keeps
            // the two from drifting apart later.
            for level in levels {
                for subsystem in subsystems {
                    for file in files {
                        let predicted = Logger.shared.wouldLog(
                            level: level, subsystem: subsystem, file: file
                        )
                        let before = mock.entries.count
                        Logger.shared.logMessage(
                            { "probe" }, level: level, subsystem: subsystem, file: file
                        )
                        let actuallyLogged = mock.entries.count > before
                        #expect(
                            predicted == actuallyLogged,
                            "level \(level) subsystem \(subsystem ?? "nil") file \(file)"
                        )
                    }
                }
            }
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

import Testing
import Foundation
@testable import Logger

extension AllLoggerTests {

    /// Verifies that the `metadata:` parameter is lazy end-to-end: the builder is
    /// evaluated only after a log call clears BOTH the level gate and the
    /// active-destination gate, and that when it *is* evaluated the forwarded
    /// content is identical to the previous eager behavior.
    struct LazyMetadataTests {

        init() { Logger.shared.reset() }

        // MARK: - Lazy: not evaluated when the level gate suppresses the call

        @Test func metadataNotEvaluatedWhenLevelSuppressed_LoggerDirect() {
            var evaluated = false
            Logger.shared.minimumLevel(.error).consoleLogging(false)

            Logger.shared.log("suppressed", level: .debug, metadata: {
                evaluated = true
                return ["pts": 42, "keyframe": true]
            }())

            #expect(!evaluated)
        }

        @Test func metadataNotEvaluatedWhenLevelSuppressed_Scoped() {
            var evaluated = false
            Logger.shared.minimumLevel(.error).consoleLogging(false)

            let scoped = Logger.shared.scoped(correlation: "job-1")
            scoped.debug("suppressed", metadata: {
                evaluated = true
                return ["pts": 42]
            }())

            #expect(!evaluated)
        }

        @Test func metadataNotEvaluatedWhenLevelSuppressed_GlobalFunction() {
            var evaluated = false
            Logger.shared.minimumLevel(.error).consoleLogging(false)

            logDebug("suppressed", metadata: {
                evaluated = true
                return ["pts": 42]
            }())

            #expect(!evaluated)
        }

        // MARK: - Eager-equivalent when the level is enabled

        @Test func metadataEvaluatedOnceAndForwardedWhenEnabled() {
            var evalCount = 0
            Logger.shared.minimumLevel(.debug).consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("emitted", level: .debug, metadata: {
                evalCount += 1
                return ["pts": 42, "keyframe": true]
            }())

            // Evaluated exactly once — same as the eager parameter would have been.
            #expect(evalCount == 1)
            #expect(mock.entries.count == 1)
            let meta = mock.entries[0].metadata
            #expect(meta?["pts"]?.description == "42")
            #expect(meta?["keyframe"]?.description == "true")
        }

        @Test func scopedMetadataEvaluatedOnceAndForwardedWhenEnabled() {
            var evalCount = 0
            Logger.shared.minimumLevel(.debug).consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            let scoped = Logger.shared.scoped(correlation: "job-9", subsystem: "decoder")
            scoped.info("emitted", metadata: {
                evalCount += 1
                return ["size": 2048]
            }())

            #expect(evalCount == 1)
            #expect(mock.entries.count == 1)
            #expect(mock.entries[0].metadata?["size"]?.description == "2048")
            #expect(mock.entries[0].correlation == "job-9")
        }

        // MARK: - No-destination gate: evaluation point is AFTER hasActiveDestination

        @Test func metadataNotEvaluatedWhenNoActiveDestination() {
            var evaluated = false
            // Level gate passes (.info >= .debug default) but no destination is
            // active: console printing is off and no output sink is installed,
            // so ConsoleDestination.isEnabled is false and no other destination
            // exists. This locks the metadata evaluation point AFTER the
            // hasActiveDestination check.
            Logger.shared.minimumLevel(.debug).consoleLogging(false)

            Logger.shared.log("no active destination", level: .info, metadata: {
                evaluated = true
                return ["pts": 42]
            }())

            #expect(!evaluated)
        }
    }
}

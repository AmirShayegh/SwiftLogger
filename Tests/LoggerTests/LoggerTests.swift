import Testing
import Foundation
@testable import Logger

@Suite(.serialized)
struct AllLoggerTests {

    // MARK: - Core

    struct CoreTests {

        init() { Logger.shared.reset() }

        @Test func logLevelOrdering() {
            #expect(LogLevel.verbose < LogLevel.debug)
            #expect(LogLevel.debug < LogLevel.info)
            #expect(LogLevel.info < LogLevel.warning)
            #expect(LogLevel.warning < LogLevel.error)
            #expect(LogLevel.error < LogLevel.todo)
        }

        @Test func logLevelTagIsFixedWidth() {
            for level in LogLevel.allCases {
                #expect(level.tag.count == 5)
            }
        }

        @Test func fluentConfigurationReturnsShared() {
            let result = Logger.shared
                .minimumLevel(.info)
                .consoleLogging(true)
                .fileLogging(false)
            #expect(result === Logger.shared)
        }

        @Test func minimumLevelFiltersLowerLevels() {
            var messages: [String] = []
            Logger.shared.minimumLevel(.warning).consoleLogging(false)
            Logger.shared.setOutputSink { messages.append($0) }

            Logger.shared.log("filtered", level: .debug)
            Logger.shared.log("passed", level: .error)

            #expect(messages.count == 1)
            #expect(messages[0].contains("passed"))
        }

        @Test func fileHighlightToggle() {
            Logger.shared.highlight("TestFile.swift").removeHighlight("TestFile.swift")
        }

        @Test func perFileLevelOverrideFilters() {
            var messages: [String] = []
            Logger.shared
                .minimumLevel(.debug)
                .logLevel(.error, forFile: "Noisy.swift")
                .consoleLogging(false)
            Logger.shared.setOutputSink { messages.append($0) }

            // The override raises Noisy.swift to .error: a .debug from it is
            // filtered and a .error from it passes, while an unrelated file falls
            // back to the global .debug minimum.
            Logger.shared.log("noisy debug", level: .debug, file: "Noisy.swift")
            Logger.shared.log("noisy error", level: .error, file: "Noisy.swift")
            Logger.shared.log("other debug", level: .debug, file: "Other.swift")

            #expect(messages.count == 2)
            #expect(messages.contains { $0.contains("noisy error") })
            #expect(messages.contains { $0.contains("other debug") })
            #expect(!messages.contains { $0.contains("noisy debug") })

            // Resolution precedence: a subsystem level outranks the per-file
            // override, so a .debug from Noisy.swift tagged subsystem "net"
            // (level .verbose) passes despite the file being pinned to .error.
            messages.removeAll()
            Logger.shared.subsystem("net", level: .verbose)
            Logger.shared.log("noisy net debug", level: .debug, subsystem: "net", file: "Noisy.swift")

            #expect(messages.count == 1)
            #expect(messages[0].contains("noisy net debug"))

            // Clearing the override lets Noisy.swift fall back to the global
            // .debug minimum, so a .debug from it passes again.
            messages.removeAll()
            Logger.shared.resetLogLevel(forFile: "Noisy.swift")
            Logger.shared.log("noisy debug again", level: .debug, file: "Noisy.swift")

            #expect(messages.count == 1)
            #expect(messages[0].contains("noisy debug again"))
        }

        @Test func fileLoggingReportsActiveState() {
            #expect(!Logger.shared.isFileLoggingActive)
            Logger.shared.fileLogging(true)
            Logger.shared.fileLogging(false)
            #expect(!Logger.shared.isFileLoggingActive)
        }

        @Test func isFileLoggingActiveIgnoresCustomLabelledFileDestinations() throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("custom-label-\(UUID().uuidString).log")
            defer { try? FileManager.default.removeItem(at: url) }

            // A file destination under a non-default label must not make the
            // default-file-logging flag report active.
            Logger.shared.fileLogging(url: url, label: "crashlog")
            #expect(!Logger.shared.isFileLoggingActive)

            Logger.shared.fileLogging(true)
            #expect(Logger.shared.isFileLoggingActive)

            // Disabling the default leaves the custom destination in place.
            Logger.shared.fileLogging(false)
            #expect(!Logger.shared.isFileLoggingActive)

            Logger.shared.removeDestination(label: "crashlog")
        }

        // Exception-handler coverage lives in ExceptionHandlerTests, which
        // saves and restores the process-global handler around every case.
    }

    // MARK: - Subsystems

    struct SubsystemTests {

        init() {
            Logger.shared.reset()
            Logger.shared.consoleLogging(false)
        }

        @Test func subsystemFluentConfiguration() {
            let logger = Logger.shared
                .subsystem("decoder", level: .verbose)
                .subsystem("encoder", level: .warning)
            #expect(logger === Logger.shared)
        }

        @Test func subsystemLevelOverridesGlobal() {
            var messages: [String] = []
            Logger.shared
                .minimumLevel(.error)
                .subsystem("decoder", level: .debug)
            Logger.shared.setOutputSink { messages.append($0) }

            Logger.shared.log("decode started", level: .debug, subsystem: "decoder")
            Logger.shared.log("should be filtered", level: .debug)

            #expect(messages.count == 1)
            #expect(messages[0].contains("decode started"))
            #expect(messages[0].contains("[decoder]"))
        }

        @Test func hierarchicalSubsystemResolution() {
            var messages: [String] = []
            Logger.shared
                .minimumLevel(.error)
                .subsystem("ffmpeg", level: .info)
            Logger.shared.setOutputSink { messages.append($0) }

            Logger.shared.log("packet read", level: .info, subsystem: "ffmpeg.demuxer")
            Logger.shared.log("frame decoded", level: .info, subsystem: "ffmpeg.decoder.h264")
            Logger.shared.log("should be filtered", level: .info)

            #expect(messages.count == 2)
            #expect(messages[0].contains("[ffmpeg.demuxer]"))
            #expect(messages[1].contains("[ffmpeg.decoder.h264]"))
        }

        @Test func childSubsystemOverridesParent() {
            var messages: [String] = []
            Logger.shared
                .subsystem("ffmpeg", level: .warning)
                .subsystem("ffmpeg.decoder", level: .debug)
            Logger.shared.setOutputSink { messages.append($0) }

            Logger.shared.log("decode detail", level: .debug, subsystem: "ffmpeg.decoder")
            Logger.shared.log("should be filtered", level: .info, subsystem: "ffmpeg.encoder")

            #expect(messages.count == 1)
            #expect(messages[0].contains("decode detail"))
        }

        @Test func resetSubsystem() {
            var messages: [String] = []
            Logger.shared
                .subsystem("decoder", level: .verbose)
                .resetSubsystem("decoder")
                .minimumLevel(.warning)
            Logger.shared.setOutputSink { messages.append($0) }

            Logger.shared.log("should be filtered", level: .debug, subsystem: "decoder")

            #expect(messages.isEmpty)
        }

        // MARK: - Resolution memoisation

        @Test func subsystemLevelMutationInvalidatesMemoizedResolution() {
            var messages: [String] = []
            Logger.shared.minimumLevel(.error).subsystem("net", level: .debug)
            Logger.shared.setOutputSink { messages.append($0) }

            // Resolve once so the answer is memoised...
            Logger.shared.log("first", level: .debug, subsystem: "net.http")
            #expect(messages.count == 1)

            // ...then change the level. The memo lives on the configuration
            // snapshot, which is replaced wholesale by any mutation, so a stale
            // answer is structurally impossible rather than merely unlikely.
            Logger.shared.subsystem("net", level: .error)
            Logger.shared.log("second", level: .debug, subsystem: "net.http")
            #expect(messages.count == 1)

            // And back again.
            Logger.shared.subsystem("net", level: .debug)
            Logger.shared.log("third", level: .debug, subsystem: "net.http")
            #expect(messages.count == 2)
            #expect(messages[1].contains("third"))
        }

        @Test func resolvedToNilIsMemoizedDistinctlyFromUnresolved() {
            var messages: [String] = []
            Logger.shared.minimumLevel(.warning).subsystem("configured", level: .debug)
            Logger.shared.setOutputSink { messages.append($0) }

            // "unconfigured" walks the whole hierarchy and finds nothing. That
            // nil is itself worth caching, so the second call must behave
            // identically to the first — a memo that stored nil as "not yet
            // computed" would still be correct here, but one that mistook a
            // cached nil for a *level* would wrongly let this through.
            for _ in 0..<3 {
                Logger.shared.log("filtered", level: .debug, subsystem: "unconfigured.deep.name")
            }
            #expect(messages.isEmpty)

            // The global minimum still applies to the unresolved subsystem.
            Logger.shared.log("passes", level: .warning, subsystem: "unconfigured.deep.name")
            #expect(messages.count == 1)

            // A configured sibling is unaffected by the cached nil.
            Logger.shared.log("configured passes", level: .debug, subsystem: "configured.child")
            #expect(messages.count == 2)
        }

        @Test func concurrentSubsystemResolutionIsSafe() {
            Logger.shared.minimumLevel(.error)
            for i in 0..<20 {
                Logger.shared.subsystem("zone\(i)", level: .debug)
            }
            let sink = MockDestination(label: "concurrent-resolve")
            Logger.shared.addDestination(sink)

            // Hammers the memo from many threads at once: reads, first-time
            // inserts, and repeat hits all interleaved. The thread sanitiser
            // lane is what actually polices this.
            DispatchQueue.concurrentPerform(iterations: 200) { i in
                Logger.shared.log("m", level: .debug, subsystem: "zone\(i % 20).child.leaf")
                Logger.shared.log("m", level: .debug, subsystem: "unconfigured\(i % 20)")
            }

            // Only the configured zones pass the gate; each of the 200
            // iterations logs exactly one qualifying message.
            #expect(sink.entries.count == 200)
        }

        @Test func memoizationHasNoUpperBoundOnDistinctNames() {
            Logger.shared.minimumLevel(.error).subsystem("capped", level: .debug)
            let sink = MockDestination(label: "capped-sink")
            Logger.shared.addDestination(sink)

            // Far more distinct names than the memo can hold, to prove the
            // insert cap degrades to "resolve every time" rather than to a
            // wrong answer.
            for i in 0..<3_000 {
                Logger.shared.log("m", level: .debug, subsystem: "capped.request-\(i)")
            }
            #expect(sink.entries.count == 3_000)

            // Still correct after the cap is reached.
            Logger.shared.log("m", level: .debug, subsystem: "uncapped.other")
            #expect(sink.entries.count == 3_000)
        }
    }

    // MARK: - Scoped Loggers

    struct ScopedLoggerTests {

        init() {
            Logger.shared.reset()
            Logger.shared.consoleLogging(false)
        }

        @Test func scopedLoggerCarriesCorrelation() {
            var messages: [String] = []
            Logger.shared.setOutputSink { messages.append($0) }

            let jobLog = Logger.shared.scoped(correlation: "job-abc123")
            #expect(jobLog.correlation == "job-abc123")
            #expect(jobLog.subsystem == nil)

            jobLog.info("started")

            #expect(messages.count == 1)
            #expect(messages[0].contains("[job-abc123]"))
            #expect(messages[0].contains("started"))
        }

        @Test func scopedLoggerWithSubsystem() {
            var messages: [String] = []
            Logger.shared.setOutputSink { messages.append($0) }

            let decoderLog = Logger.shared.scoped(correlation: "job-42", subsystem: "decoder")
            decoderLog.debug("keyframe decoded")

            #expect(messages.count == 1)
            #expect(messages[0].contains("[job-42]"))
            #expect(messages[0].contains("[decoder]"))
            #expect(messages[0].contains("keyframe decoded"))
        }

        @Test func scopedLoggerRespectsSubsystemLevel() {
            var messages: [String] = []
            Logger.shared
                .minimumLevel(.error)
                .subsystem("decoder", level: .debug)
            Logger.shared.setOutputSink { messages.append($0) }

            let decoderLog = Logger.shared.scoped(correlation: "job-1", subsystem: "decoder")
            decoderLog.debug("this should log")

            #expect(messages.count == 1)
        }

        @Test func scopedLoggerFiltersWhenSubsystemLevelHigh() {
            var messages: [String] = []
            Logger.shared
                .minimumLevel(.debug)
                .subsystem("encoder", level: .error)
            Logger.shared.setOutputSink { messages.append($0) }

            let encoderLog = Logger.shared.scoped(correlation: "job-2", subsystem: "encoder")
            encoderLog.debug("should be filtered")

            #expect(messages.isEmpty)
        }

        @Test func scopedLoggerAllLevelMethods() {
            var messages: [String] = []
            Logger.shared.minimumLevel(.verbose)
            Logger.shared.setOutputSink { messages.append($0) }

            let log = Logger.shared.scoped(correlation: "test")
            log.verbose("v")
            log.debug("d")
            log.info("i")
            log.warning("w")
            log.error("e")
            log.todo("t")

            #expect(messages.count == 6)
        }

        @Test func nestedScopedLogger() {
            let parent = Logger.shared.scoped(correlation: "parent", subsystem: "pipeline")
            let child = parent.scoped(correlation: "child")
            #expect(child.correlation == "child")
            #expect(child.subsystem == "pipeline")
        }

        @Test func nestedScopedLoggerCanOverrideSubsystem() {
            let parent = Logger.shared.scoped(correlation: "parent", subsystem: "pipeline")
            let child = parent.scoped(correlation: "child", subsystem: "decoder")
            #expect(child.subsystem == "decoder")
        }

        // MARK: - Scope metadata

        @Test func scopeMetadataAppearsInEveryMessage() {
            let mock = MockDestination()
            Logger.shared.addDestination(mock)

            let session = Logger.shared.scoped(correlation: "s-1", metadata: ["user": "u42", "tier": "pro"])
            session.info("first")
            session.error("second")

            #expect(mock.entries.count == 2)
            for entry in mock.entries {
                #expect(entry.metadata?["user"]?.description == "u42")
                #expect(entry.metadata?["tier"]?.description == "pro")
            }
        }

        @Test func perCallMetadataMergesWithScopeMetadata() {
            let mock = MockDestination()
            Logger.shared.addDestination(mock)

            let session = Logger.shared.scoped(correlation: "s-1", metadata: ["user": "u42"])
            session.info("done", metadata: ["ms": 17])

            let meta = mock.entries[0].metadata
            #expect(meta?["user"]?.description == "u42")
            #expect(meta?["ms"]?.description == "17")
        }

        @Test func perCallMetadataWinsOnKeyCollision() {
            let mock = MockDestination()
            Logger.shared.addDestination(mock)

            // A message reporting a specific state must not be overridden by the
            // scope's default for that key.
            let session = Logger.shared.scoped(correlation: "s-1", metadata: ["state": "running"])
            session.error("it failed", metadata: ["state": "failed"])

            #expect(mock.entries[0].metadata?["state"]?.description == "failed")
        }

        @Test func scopeMetadataAppliesToTheGenericLogMethodToo() {
            let mock = MockDestination()
            Logger.shared.addDestination(mock)

            let session = Logger.shared.scoped(correlation: "s-1", metadata: ["user": "u42"])
            session.log("via log()", level: .warning, metadata: ["extra": true])

            let meta = mock.entries[0].metadata
            #expect(meta?["user"]?.description == "u42")
            #expect(meta?["extra"]?.description == "true")
        }

        @Test func childScopeInheritsAndExtendsParentMetadata() {
            let mock = MockDestination()
            Logger.shared.addDestination(mock)

            let parent = Logger.shared.scoped(correlation: "p", metadata: ["app": "demo", "user": "u1"])
            let child = parent.scoped(correlation: "c", metadata: ["task": "sync", "user": "u2"])

            // Inherited keys survive, new keys are added, and the child's own
            // value wins where they collide.
            #expect(child.metadata?["app"]?.description == "demo")
            #expect(child.metadata?["task"]?.description == "sync")
            #expect(child.metadata?["user"]?.description == "u2")

            child.info("child message")
            #expect(mock.entries[0].metadata?["app"]?.description == "demo")

            // The parent is a value type and is left untouched.
            #expect(parent.metadata?["user"]?.description == "u1")
            #expect(parent.metadata?["task"] == nil)
        }

        @Test func scopeWithoutMetadataPassesCallSiteMetadataThroughUnchanged() {
            let mock = MockDestination()
            Logger.shared.addDestination(mock)

            let plain = Logger.shared.scoped(correlation: "s-1")
            #expect(plain.metadata == nil)

            plain.info("only call-site", metadata: ["k": 1])
            #expect(mock.entries[0].metadata?["k"]?.description == "1")

            plain.info("none at all")
            #expect(mock.entries[1].metadata == nil)
        }
    }

    // MARK: - Metadata

    struct MetadataTests {

        init() {
            Logger.shared.reset()
            Logger.shared.consoleLogging(false)
        }

        @Test func logValueInitializersWrapRuntimeValues() {
            // The literal conformances cannot help here: these are variables,
            // and Swift performs no implicit conversion. Without these inits
            // the only spelling is `.string(name)`, which leaks the case names
            // into every call site.
            let name = "amir"
            let count = 7
            let ratio = 0.25
            let flag = true

            #expect(LogValue(name).description == "amir")
            #expect(LogValue(count).description == "7")
            #expect(LogValue(ratio).description == "0.25")
            #expect(LogValue(flag).description == "true")

            let metadata: LogMetadata = [
                "name": LogValue(name),
                "count": LogValue(count),
                "flag": LogValue(flag)
            ]
            #expect(metadata["count"]?.description == "7")
        }

        @Test func logValueUnlabeledInitPicksExpectedCaseForLiterals() {
            // Passing a literal to the unlabeled init must not become ambiguous
            // with the ExpressibleBy* conformances. Integer literals default to
            // Int, float literals to Double.
            func caseName(_ value: LogValue) -> String {
                switch value {
                case .string: return "string"
                case .int: return "int"
                case .double: return "double"
                case .bool: return "bool"
                }
            }

            #expect(caseName(LogValue(5)) == "int")
            #expect(caseName(LogValue(5.0)) == "double")
            #expect(caseName(LogValue("5")) == "string")
            #expect(caseName(LogValue(false)) == "bool")

            // Dictionary literals still take the literal path, unchanged.
            let literals: LogMetadata = ["a": 1, "b": 1.5, "c": "x", "d": true]
            #expect(caseName(literals["a"]!) == "int")
            #expect(caseName(literals["b"]!) == "double")
            #expect(caseName(literals["c"]!) == "string")
            #expect(caseName(literals["d"]!) == "bool")
        }

        @Test func logWithMetadataFormatsCorrectly() {
            var messages: [String] = []
            Logger.shared.setOutputSink { messages.append($0) }

            Logger.shared.log(
                "frame decoded",
                level: .debug,
                metadata: ["pts": 42, "size": 1024, "keyframe": true]
            )

            #expect(messages.count == 1)
            #expect(messages[0].contains("frame decoded"))
            #expect(messages[0].contains("{keyframe=true, pts=42, size=1024}"))
        }

        @Test func logValueTypes() {
            let str: LogValue = "hello"
            let int: LogValue = 42
            let dbl: LogValue = 3.14
            let flag: LogValue = true
            #expect(str.description == "hello")
            #expect(int.description == "42")
            #expect(dbl.description == "3.14")
            #expect(flag.description == "true")
        }

        @Test func logValueStringInterpolation() {
            let val: LogValue = "count: \(42)"
            #expect(val.description == "count: 42")
        }

        @Test func globalFunctionWithMetadata() {
            var messages: [String] = []
            Logger.shared.setOutputSink { messages.append($0) }

            logDebug("packet read", subsystem: "demuxer", metadata: ["size": 2048])

            #expect(messages.count == 1)
            #expect(messages[0].contains("[demuxer]"))
            #expect(messages[0].contains("{size=2048}"))
        }

        @Test func scopedLoggerWithMetadata() {
            var messages: [String] = []
            Logger.shared.setOutputSink { messages.append($0) }

            let log = Logger.shared.scoped(correlation: "job-1", subsystem: "decoder")
            log.debug("frame decoded", metadata: ["pts": 42, "keyframe": true])

            #expect(messages.count == 1)
            #expect(messages[0].contains("[job-1]"))
            #expect(messages[0].contains("{keyframe=true, pts=42}"))
        }

        @Test func emptyMetadataProducesNoSuffix() {
            var messages: [String] = []
            Logger.shared.setOutputSink { messages.append($0) }

            Logger.shared.log("clean message", metadata: [:])

            #expect(messages.count == 1)
            #expect(!messages[0].contains("{"))
        }
    }

    // MARK: - Autoclosure

    struct AutoclosureTests {

        init() { Logger.shared.reset() }

        @Test func messageNotEvaluatedWhenFiltered() {
            var evaluated = false
            Logger.shared.minimumLevel(.error).consoleLogging(false)

            Logger.shared.log({
                evaluated = true
                return "expensive message"
            }(), level: .debug)

            #expect(!evaluated)
        }

        @Test func messageEvaluatedWhenNotFiltered() {
            var evaluated = false
            Logger.shared.minimumLevel(.debug).consoleLogging(false)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log({
                evaluated = true
                return "should evaluate"
            }(), level: .error)

            #expect(evaluated)
        }

        @Test func callAsFunctionSkipsEvaluationWhenFiltered() {
            var evaluated = false
            Logger.shared.minimumLevel(.error).consoleLogging(false)

            Log({
                evaluated = true
                return "expensive"
            }(), level: .debug)

            #expect(!evaluated)
        }

        @Test func globalFunctionSkipsEvaluationWhenFiltered() {
            var evaluated = false
            Logger.shared.minimumLevel(.error).consoleLogging(false)

            logDebug({
                evaluated = true
                return "expensive"
            }())

            #expect(!evaluated)
        }

        @Test func scopedLoggerSkipsEvaluationWhenFiltered() {
            var evaluated = false
            Logger.shared.minimumLevel(.error).consoleLogging(false)

            let scoped = Logger.shared.scoped(correlation: "test")
            scoped.debug({
                evaluated = true
                return "expensive"
            }())

            #expect(!evaluated)
        }

        @Test func scopedInfoSkipsEvaluationWhenFiltered() {
            var evaluated = false
            Logger.shared.minimumLevel(.error).consoleLogging(false)

            let scoped = Logger.shared.scoped(correlation: "test")
            scoped.info({
                evaluated = true
                return "expensive"
            }())

            #expect(!evaluated)
        }
    }

    // MARK: - Concurrency

    struct ConcurrencyTests {

        init() { Logger.shared.reset() }

        @Test func concurrentLoggingDoesNotCrash() async {
            Logger.shared.minimumLevel(.verbose).consoleLogging(false)

            await withTaskGroup(of: Void.self) { group in
                for i in 0..<100 {
                    group.addTask {
                        Logger.shared.log("concurrent message \(i)", level: .info)
                    }
                }
            }
        }

        @Test func concurrentScopedLoggingDoesNotCrash() async {
            Logger.shared.minimumLevel(.verbose).consoleLogging(false)

            await withTaskGroup(of: Void.self) { group in
                for i in 0..<100 {
                    group.addTask {
                        let log = Logger.shared.scoped(correlation: "job-\(i)", subsystem: "worker")
                        log.info("working", metadata: ["index": .int(i)])
                    }
                }
            }
        }

        /// Readers work against an immutable configuration snapshot, so a config
        /// change mid-flight means a message observes either the old or the new
        /// configuration — never a torn mix, and never a lost message when every
        /// level in play passes both. Best run under `--sanitize=thread`.
        @Test func loggingDeliversEveryMessageWhileConfigurationMutates() async {
            Logger.shared.consoleLogging(false)
            Logger.shared.minimumLevel(.verbose)

            let mock = MockDestination()
            Logger.shared.addDestination(mock)

            let taskCount = 4
            let messagesPerTask = 500

            await withTaskGroup(of: Void.self) { group in
                for taskIndex in 0..<taskCount {
                    group.addTask {
                        for i in 0..<messagesPerTask {
                            Logger.shared.log(
                                "task \(taskIndex) message \(i)",
                                level: .error,
                                subsystem: "stress.task\(taskIndex)"
                            )
                        }
                    }
                }

                // Churn every field of the snapshot underneath the loggers. All
                // minimums cycled through are at or below .error, so no message
                // above may be dropped regardless of which snapshot it observes.
                group.addTask {
                    for i in 0..<200 {
                        Logger.shared.minimumLevel(i.isMultiple(of: 2) ? .verbose : .debug)
                        Logger.shared.subsystem("stress", level: .verbose)
                        Logger.shared.logLevel(.verbose, forFile: "LoggerTests.swift")
                        Logger.shared.resetLogLevel(forFile: "LoggerTests.swift")
                        Logger.shared.resetSubsystem("stress")
                    }
                }
            }

            #expect(mock.entries.count == taskCount * messagesPerTask)
        }

        /// Destination registration is a read-modify-write over the destination
        /// list; without end-to-end serialization of mutations, concurrent
        /// registrations would clobber each other.
        @Test func concurrentDestinationRegistrationDoesNotLoseUpdates() async {
            Logger.shared.consoleLogging(false)

            await withTaskGroup(of: Void.self) { group in
                for i in 0..<32 {
                    group.addTask {
                        Logger.shared.addDestination(MockDestination(label: "concurrent-\(i)"))
                    }
                }
            }

            Logger.shared.log("fan out", level: .error)

            let delivered = (0..<32).filter { i in
                let dest = Logger.shared.destinationForTesting(label: "concurrent-\(i)") as? MockDestination
                return dest?.entries.count == 1
            }.count
            #expect(delivered == 32)
        }

        @Test func concurrentConfigurationDoesNotCrash() async {
            Logger.shared.consoleLogging(false)

            await withTaskGroup(of: Void.self) { group in
                for i in 0..<50 {
                    group.addTask {
                        Logger.shared
                            .minimumLevel(i % 2 == 0 ? .debug : .warning)
                            .subsystem("worker.\(i)", level: .verbose)
                            .highlight("File\(i).swift")
                            .logLevel(.verbose, forFile: "File\(i).swift")

                        Logger.shared.log("config test \(i)", level: .info, subsystem: "worker.\(i)")

                        Logger.shared
                            .removeHighlight("File\(i).swift")
                            .resetLogLevel(forFile: "File\(i).swift")
                            .resetSubsystem("worker.\(i)")
                    }
                }
            }
        }
    }
}

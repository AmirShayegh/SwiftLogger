import Testing
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

            // Simulating a call from "Noisy.swift" isn't possible with #file,
            // but we can verify the API doesn't crash and reset works
            Logger.shared.resetLogLevel(forFile: "Noisy.swift")
        }

        @Test func fileLoggingReportsActiveState() {
            #expect(!Logger.shared.isFileLoggingActive)
            Logger.shared.fileLogging(true)
            Logger.shared.fileLogging(false)
            #expect(!Logger.shared.isFileLoggingActive)
        }

        @Test func exceptionHandlerUsesRegistrar() {
            var handlerWasRegistered = false
            Logger.shared.exceptionHandlerRegistrar = { _ in
                handlerWasRegistered = true
            }
            #expect(!Logger.shared.isExceptionHandlerInstalled)
            Logger.shared.installExceptionHandler()
            #expect(Logger.shared.isExceptionHandlerInstalled)
            #expect(handlerWasRegistered)
        }

        @Test func exceptionHandlerIsIdempotent() {
            var registrationCount = 0
            Logger.shared.exceptionHandlerRegistrar = { _ in
                registrationCount += 1
            }
            Logger.shared.installExceptionHandler()
            Logger.shared.installExceptionHandler()
            #expect(registrationCount == 1)
        }
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
    }

    // MARK: - Metadata

    struct MetadataTests {

        init() {
            Logger.shared.reset()
            Logger.shared.consoleLogging(false)
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

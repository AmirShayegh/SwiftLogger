import Testing
import Foundation
@testable import Logger

extension AllLoggerTests {

    /// `FileDestination` buffers entries and coalesces them into batched writes,
    /// bounded so a burst cannot grow memory without limit.
    struct FileBufferingTests {

        private func makeTempDir() throws -> URL {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("logger-buf-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            return tmp
        }

        private func contents(of url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        private func lines(of url: URL) -> [String] {
            contents(of: url).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }

        @Test func flushLandsBufferedEntriesImmediately() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("flush.log")

            // Long interval: only an explicit flush can get these to disk in time.
            let fd = FileDestination(url: url, tunables: .init(flushInterval: 60))!

            fd.write(LogEntry(level: .info, message: "buffered one"))
            fd.write(LogEntry(level: .info, message: "buffered two"))
            fd.flush()

            let written = contents(of: url)
            #expect(written.contains("buffered one"))
            #expect(written.contains("buffered two"))
        }

        @Test func entriesCoalesceIntoOneWriteRatherThanLandingImmediately() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("coalesce.log")

            let fd = FileDestination(
                url: url,
                tunables: .init(flushInterval: 60, flushByteThreshold: 1_000_000)  // never trip the size trigger
            )!

            fd.write(LogEntry(level: .info, message: "still buffered"))

            // Nothing is on disk yet: the entry is waiting in the buffer.
            #expect(contents(of: url).isEmpty)

            fd.flush()
            #expect(contents(of: url).contains("still buffered"))
        }

        @Test func delayedFlushWritesWithoutAnExplicitFlush() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("timer.log")

            let fd = FileDestination(
                url: url,
                tunables: .init(flushInterval: 0.02, flushByteThreshold: 1_000_000)
            )!

            fd.write(LogEntry(level: .info, message: "timer driven"))

            // Poll rather than sleeping a fixed amount, so a slow machine does
            // not turn this into a flake.
            let deadline = Date().addingTimeInterval(5)
            while !contents(of: url).contains("timer driven") && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(contents(of: url).contains("timer driven"))
        }

        @Test func crossingTheByteThresholdWritesWithoutWaitingForTheInterval() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("threshold.log")

            let fd = FileDestination(
                url: url,
                tunables: .init(flushInterval: 600, flushByteThreshold: 200)  // interval effectively never
            )!

            for i in 0..<20 {
                fd.write(LogEntry(level: .info, message: "threshold entry \(i)"))
            }

            let deadline = Date().addingTimeInterval(5)
            while !contents(of: url).contains("threshold entry 0") && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(contents(of: url).contains("threshold entry 0"))
        }

        @Test func burstBeyondCapacityDropsNewestAndReportsTheCount() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("drop.log")

            // Hold everything in the buffer so the cap is reached deterministically.
            let fd = FileDestination(
                url: url,
                tunables: .init(maxBufferedEntries: 50, flushInterval: 600, flushByteThreshold: 1_000_000)
            )!

            let overflow = 17
            for i in 0..<(50 + overflow) {
                fd.write(LogEntry(level: .info, message: "burst \(i)"))
            }
            fd.flush()

            let written = lines(of: url)

            // 50 buffered entries plus one notice line about the rest.
            #expect(written.count == 51)
            #expect(written.last?.contains("dropped \(overflow) messages") == true)

            // Drop-newest: the first 50 survive, the tail is gone.
            #expect(written[0].contains("burst 0"))
            #expect(written[49].contains("burst 49"))
            #expect(!contents(of: url).contains("burst 50"))
        }

        @Test func droppedNoticeIsSingularForASingleDroppedMessage() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("drop-one.log")

            let fd = FileDestination(
                url: url,
                tunables: .init(maxBufferedEntries: 2, flushInterval: 600, flushByteThreshold: 1_000_000)
            )!

            for i in 0..<3 { fd.write(LogEntry(level: .info, message: "x\(i)")) }
            fd.flush()

            #expect(contents(of: url).contains("dropped 1 message —"))
        }

        @Test func droppedCountResetsAfterBeingReported() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("drop-reset.log")

            let fd = FileDestination(
                url: url,
                tunables: .init(maxBufferedEntries: 2, flushInterval: 600, flushByteThreshold: 1_000_000)
            )!

            for i in 0..<4 { fd.write(LogEntry(level: .info, message: "a\(i)")) }
            fd.flush()

            // Second round stays under capacity, so it must report no drops.
            fd.write(LogEntry(level: .info, message: "recovered"))
            fd.flush()

            let all = contents(of: url)
            #expect(all.contains("dropped 2 messages"))
            #expect(all.contains("recovered"))
            // Exactly one notice overall — the counter reset when it was reported.
            #expect(all.components(separatedBy: "write buffer full").count - 1 == 1)
        }

        @Test func deinitDrainsBufferedEntriesToDisk() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("deinit.log")

            do {
                let fd = FileDestination(
                    url: url,
                    tunables: .init(flushInterval: 600, flushByteThreshold: 1_000_000)
                )!
                fd.write(LogEntry(level: .info, message: "written at deinit"))
                // fd goes out of scope here with the entry still buffered.
            }

            let deadline = Date().addingTimeInterval(5)
            while !contents(of: url).contains("written at deinit") && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(contents(of: url).contains("written at deinit"))
        }

        @Test func forceSaveWritesBufferedEntriesBeforeTheCrashLog() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("crash.log")

            let fd = FileDestination(
                url: url,
                tunables: .init(flushInterval: 600, flushByteThreshold: 1_000_000)
            )!

            fd.write(LogEntry(level: .info, message: "led up to the crash"))
            fd.forceSave("CRASH REPORT")

            let written = contents(of: url)
            let leadUp = try #require(written.range(of: "led up to the crash"))
            let crash = try #require(written.range(of: "CRASH REPORT"))
            #expect(leadUp.lowerBound < crash.lowerBound)
        }

        @Test func sustainedWritingStillReachesDisk() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("sustained.log")

            let fd = FileDestination(url: url, tunables: .init(flushByteThreshold: 256))!

            // A tight loop must not be able to starve the flush by continually
            // re-scheduling it.
            for i in 0..<5_000 {
                fd.write(LogEntry(level: .info, message: "sustained \(i)"))
            }
            fd.flush()

            let written = lines(of: url)
            // Buffer cap is 1000 with no drops expected here, since the byte
            // threshold keeps draining it. Every line should be present.
            #expect(written.count == 5_000)
            #expect(written.first?.contains("sustained 0") == true)
            #expect(written.last?.contains("sustained 4999") == true)
        }

        @Test func concurrentWritersLoseNothing() async throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("concurrent.log")

            let fd = FileDestination(url: url, tunables: .init(flushByteThreshold: 512))!

            let writers = 8
            let perWriter = 250

            await withTaskGroup(of: Void.self) { group in
                for w in 0..<writers {
                    group.addTask {
                        for i in 0..<perWriter {
                            fd.write(LogEntry(level: .info, message: "w\(w)-i\(i)"))
                        }
                    }
                }
            }
            fd.flush()

            #expect(lines(of: url).count == writers * perWriter)
        }

        @Test func rotationThresholdClampsTheBufferSize() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("clamp.log")

            // Buffering more than a whole log file would guarantee overshooting
            // maxFileSize before rotation could look at it.
            let fd = FileDestination(
                url: url,
                rotation: FileRotationConfig(maxFileSize: 128, maxArchivedFilesCount: 2)
            )!
            #expect(fd.flushByteThreshold == 128)

            let unrotated = FileDestination(url: dir.appendingPathComponent("plain.log"))!
            #expect(unrotated.flushByteThreshold == FileDestination.defaultFlushByteThreshold)
        }
    }
}

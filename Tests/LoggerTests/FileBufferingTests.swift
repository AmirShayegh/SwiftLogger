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

            // The cap is raised above the entry count on purpose. This test is
            // about flush starvation — a tight loop repeatedly re-scheduling
            // the flush so it never runs — and the buffer cap is a *separate*,
            // deliberate drop mechanism with its own tests. Leaving the default
            // 1000 cap here made the assertion race the drain: whether all 5000
            // survived depended on how fast the queue kept up, so the test
            // failed intermittently for a reason that was not the bug it guards.
            let fd = FileDestination(
                url: url,
                tunables: .init(maxBufferedEntries: 10_000, flushByteThreshold: 256)
            )!

            for i in 0..<5_000 {
                fd.write(LogEntry(level: .info, message: "sustained \(i)"))
            }
            fd.flush()

            let written = lines(of: url)
            #expect(written.count == 5_000)
            #expect(written.first?.contains("sustained 0") == true)
            #expect(written.last?.contains("sustained 4999") == true)
            // Starvation would show up as a drop notice, not just a short file.
            #expect(!contents(of: url).contains("write buffer full"))
        }

        @Test func concurrentWritersLoseNothing() async throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("concurrent.log")

            let writers = 8
            let perWriter = 250

            // Cap raised above writers * perWriter so overflow cannot occur:
            // this test is about the buffer's *concurrency* correctness, not
            // its overflow policy (which burstBeyondCapacityDropsNewestAndReportsTheCount
            // covers). With the default 1000 cap, eight threads could outrun the
            // drain and legitimately drop, which made a passing run depend on
            // machine load rather than on the code being correct.
            let fd = FileDestination(
                url: url,
                tunables: .init(maxBufferedEntries: writers * perWriter * 2, flushByteThreshold: 512)
            )!

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

            let written = lines(of: url)
            #expect(written.count == writers * perWriter)
            #expect(!contents(of: url).contains("write buffer full"))

            // Every single entry, not just the right count — a lost entry
            // paired with a duplicate would otherwise pass.
            let found = Set(written.compactMap { line -> String? in
                guard let range = line.range(of: #"w\d+-i\d+"#, options: .regularExpression) else { return nil }
                return String(line[range])
            })
            #expect(found.count == writers * perWriter)
        }

        @Test func appendModeAllowsTwoHandlesOnOneFileWithoutOverwrite() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("shared.log")

            // Two destinations on one file — the shape a replaced destination's
            // late drain produces. With per-handle offsets each handle would
            // write from its own stale position and silently overwrite the
            // other's bytes; O_APPEND makes the kernel pick end-of-file at
            // every write, so all lines must survive.
            let a = FileDestination(
                url: url, label: "a",
                tunables: .init(flushInterval: 600, flushByteThreshold: 1_000_000)
            )!
            let b = FileDestination(
                url: url, label: "b",
                tunables: .init(flushInterval: 600, flushByteThreshold: 1_000_000)
            )!

            for i in 0..<10 {
                a.write(LogEntry(level: .info, message: "handle-a \(i)"))
                a.flush()
                b.write(LogEntry(level: .info, message: "handle-b \(i)"))
                b.flush()
            }

            let written = lines(of: url)
            #expect(written.count == 20)
            for i in 0..<10 {
                #expect(written.contains { $0.contains("handle-a \(i)") })
                #expect(written.contains { $0.contains("handle-b \(i)") })
            }
        }

        @Test func reentrantFormatterDoesNotAbortTheDroppedNotice() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("reentrant.log")

            // A formatter that logs back into its own destination — user
            // formatters do this for diagnostics. The drop notice is rendered
            // with the user formatter, and rendering it under the non-recursive
            // stateLock would abort the process the moment the formatter
            // re-entered write().
            final class ChattyFormatter: LogFormatter, @unchecked Sendable {
                weak var destination: FileDestination?
                func format(_ entry: LogEntry) -> String {
                    if entry.message.contains("dropped") {
                        destination?.write(LogEntry(level: .debug, message: "formatter side-effect"))
                    }
                    return entry.message
                }
            }

            let formatter = ChattyFormatter()
            let fd = FileDestination(
                url: url,
                formatter: formatter,
                tunables: .init(maxBufferedEntries: 2, flushInterval: 600, flushByteThreshold: 1_000_000)
            )!
            formatter.destination = fd

            for i in 0..<4 { fd.write(LogEntry(level: .info, message: "kept \(i)")) }
            fd.flush()

            let content = contents(of: url)
            #expect(content.contains("dropped 2 messages"))
        }

        @Test func writeFailureIsCountedAsDropped() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("failing.log")

            let fd = FileDestination(
                url: url,
                tunables: .init(flushInterval: 600, flushByteThreshold: 1_000_000)
            )!

            fd.write(LogEntry(level: .info, message: "casualty"))
            fd.closeHandleForTesting()
            fd.flush()  // The write fails; the entry is lost but must be counted.

            // forceSave's crash path reopens immediately, recovering the handle;
            // the next flush then reports the loss.
            fd.forceSave("CRASH")
            fd.flush()

            let content = contents(of: url)
            #expect(!content.contains("casualty"))
            #expect(content.contains("CRASH"))
            #expect(content.contains("dropped 1 message —"))
        }

        // MARK: - Degraded-state durability

        /// Degrades `fd` by making its path un-openable, then restores the path
        /// while leaving the destination degraded and inside its backoff.
        private func degradeThenRestore(_ fd: FileDestination, at url: URL) throws {
            // Kill the descriptor, then park a directory on the path so the
            // recovery reopen fails with EISDIR and the destination goes
            // degraded rather than quietly reopening.
            fd.closeHandleForTesting()
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            fd.write(LogEntry(level: .info, message: "degrading write"))
            fd.flush()
            #expect(!fd.isHealthyForTesting)
            // Path is writable again, but the destination will not retry until
            // reopenBackoff elapses — which is the window under test.
            try FileManager.default.removeItem(at: url)
        }

        @Test func forceSavePreservesTheBufferedTailWhenDegraded() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("crash-degraded.log")

            // Long backoff so the destination is definitely still throttled.
            let fd = FileDestination(
                url: url,
                tunables: .init(flushInterval: 600, flushByteThreshold: 1_000_000, reopenBackoff: 600)
            )!
            try degradeThenRestore(fd, at: url)

            fd.write(LogEntry(level: .error, message: "LEADING_UP_TO_CRASH"))
            fd.forceSave("CRASH REPORT")

            // forceSave used to drain the buffer *before* attempting a reopen,
            // so a degraded destination wrote the crash text alone and threw
            // away exactly the entries explaining it.
            let content = contents(of: url)
            #expect(content.contains("LEADING_UP_TO_CRASH"))
            #expect(content.contains("CRASH REPORT"))
            let leadUp = try #require(content.range(of: "LEADING_UP_TO_CRASH"))
            let crash = try #require(content.range(of: "CRASH REPORT"))
            #expect(leadUp.lowerBound < crash.lowerBound)
        }

        @Test func flushPreservesTheBufferWhenDegraded() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("flush-degraded.log")

            let fd = FileDestination(
                url: url,
                tunables: .init(flushInterval: 600, flushByteThreshold: 1_000_000, reopenBackoff: 600)
            )!
            try degradeThenRestore(fd, at: url)

            fd.write(LogEntry(level: .info, message: "MUST_BE_ON_DISK"))
            fd.flush()

            // flush() promises the buffer is on storage when it returns. Waiting
            // out the backoff and discarding it instead is the
            // applicationWillTerminate data-loss case.
            #expect(contents(of: url).contains("MUST_BE_ON_DISK"))
        }

        @Test func deinitPreservesTheBufferWhenDegraded() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("deinit-degraded.log")

            do {
                let fd = FileDestination(
                    url: url,
                    tunables: .init(flushInterval: 600, flushByteThreshold: 1_000_000, reopenBackoff: 600)
                )!
                try degradeThenRestore(fd, at: url)
                fd.write(LogEntry(level: .info, message: "FINAL_TAIL"))
                // fd goes out of scope degraded, with the entry still buffered.
            }

            let deadline = Date().addingTimeInterval(5)
            while !contents(of: url).contains("FINAL_TAIL") && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(contents(of: url).contains("FINAL_TAIL"))
        }

        @Test func reopenIsThrottledByTheBackoffOnTheBackgroundPath() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("throttled.log")

            // flushByteThreshold 1 makes every write drive an immediate
            // background flush, which is the path the backoff governs.
            let fd = FileDestination(
                url: url,
                tunables: .init(flushByteThreshold: 1, reopenBackoff: 600)
            )!
            try degradeThenRestore(fd, at: url)

            // The path is writable again, but ordinary buffered writes must NOT
            // retry the open until the backoff elapses — without that throttle a
            // persistently failing destination hammers the filesystem on every
            // single flush.
            for i in 0..<20 {
                fd.write(LogEntry(level: .info, message: "still degraded \(i)"))
            }
            // Deliberately not fd.flush(): that path ignores the backoff by
            // design. Let the background flushes run instead.
            Thread.sleep(forTimeInterval: 0.2)
            #expect(!fd.isHealthyForTesting)
            #expect(!FileManager.default.fileExists(atPath: url.path))

            // Same situation, zero backoff: the very next background flush
            // recovers, so the throttle above is the backoff and not a
            // permanently wedged destination.
            let promptURL = dir.appendingPathComponent("prompt.log")
            let prompt = FileDestination(
                url: promptURL,
                tunables: .init(flushByteThreshold: 1, reopenBackoff: 0)
            )!
            try degradeThenRestore(prompt, at: promptURL)
            prompt.write(LogEntry(level: .info, message: "RECOVERED_IN_BACKGROUND"))

            let deadline = Date().addingTimeInterval(5)
            while !contents(of: promptURL).contains("RECOVERED_IN_BACKGROUND") && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            #expect(contents(of: promptURL).contains("RECOVERED_IN_BACKGROUND"))
        }

        @Test func writeFailuresAreReportedSeparatelyFromBufferOverflow() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("attribution.log")

            let fd = FileDestination(
                url: url,
                tunables: .init(flushInterval: 600, flushByteThreshold: 1_000_000, reopenBackoff: 0)
            )!

            fd.write(LogEntry(level: .info, message: "casualty"))
            fd.closeHandleForTesting()
            fd.flush()
            fd.write(LogEntry(level: .info, message: "after"))
            fd.flush()

            // A dead descriptor and a full buffer call for completely different
            // responses, so the notice must not blame the buffer for a write
            // failure — an operator would raise maxBufferedEntries and never
            // look at the real fault.
            let content = contents(of: url)
            #expect(content.contains("could not be written to attribution.log"))
            #expect(!content.contains("write buffer full"))
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

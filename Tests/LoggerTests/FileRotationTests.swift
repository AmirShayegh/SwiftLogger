import Testing
import Foundation
@testable import Logger

extension AllLoggerTests {

    struct FileRotationTests {

        private func makeTempDir() throws -> URL {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-rot-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            return tmp
        }

        private func archives(in dir: URL, baseName: String) -> [URL] {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
            let prefix = baseName + "."
            return contents
                .filter { url in
                    let name = url.lastPathComponent
                    guard name.hasPrefix(prefix) else { return false }
                    let suffix = String(name.dropFirst(prefix.count))
                    return suffix.range(of: #"^\d{8}T\d{6}Z_[a-f0-9]{8}$"#, options: .regularExpression) != nil
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        @Test func rotationTriggersAtMaxSize() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("test.log")

            let fd = FileDestination(url: logURL, rotation: FileRotationConfig(maxFileSize: 100, maxArchivedFilesCount: 5))!

            for i in 0..<20 {
                fd.write(LogEntry(level: .info, message: "message \(i) with padding to exceed threshold"))
            }
            fd.flush()

            let found = archives(in: dir, baseName: "test.log")
            #expect(!found.isEmpty)
        }

        @Test func archiveNamingMatchesPattern() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("app.log")

            let fd = FileDestination(url: logURL, rotation: FileRotationConfig(maxFileSize: 50, maxArchivedFilesCount: 5))!

            for i in 0..<10 {
                fd.write(LogEntry(level: .info, message: "msg \(i) padding to trigger rotation"))
            }
            fd.flush()

            let found = archives(in: dir, baseName: "app.log")
            #expect(!found.isEmpty)
            for archive in found {
                let name = archive.lastPathComponent
                #expect(name.hasPrefix("app.log."))
                let suffix = String(name.dropFirst("app.log.".count))
                #expect(suffix.range(of: #"^\d{8}T\d{6}Z_[a-f0-9]{8}$"#, options: .regularExpression) != nil)
            }
        }

        @Test func prunesOldArchives() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("test.log")

            let fd = FileDestination(url: logURL, rotation: FileRotationConfig(maxFileSize: 50, maxArchivedFilesCount: 2))!

            for i in 0..<50 {
                fd.write(LogEntry(level: .info, message: "entry \(i) with enough padding to rotate multiple times"))
            }
            fd.flush()

            let found = archives(in: dir, baseName: "test.log")
            #expect(found.count <= 2)
        }

        @Test func zeroArchivesRetainsNone() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("test.log")

            let fd = FileDestination(url: logURL, rotation: FileRotationConfig(maxFileSize: 50, maxArchivedFilesCount: 0))!

            for i in 0..<20 {
                fd.write(LogEntry(level: .info, message: "entry \(i) with enough padding to trigger rotation"))
            }
            fd.flush()

            let found = archives(in: dir, baseName: "test.log")
            #expect(found.isEmpty)
        }

        @Test func postRotationWritesToFreshFile() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("test.log")

            // Each setup line on its own exceeds maxFileSize, so rotation fires
            // on every setup batch no matter how GCD coalesced the writes, and
            // currentFileSize is deterministically 0 when the marker is written.
            //
            // With the old sizing (50-byte limit, 48-byte lines) the outcome
            // depended on batching: if the last batch happened to be a partial
            // one, the residual plus the 41-byte marker crossed the threshold
            // and rotation archived the marker, leaving the current file empty.
            // That failed roughly 1 run in 100.
            let fd = FileDestination(url: logURL, rotation: FileRotationConfig(maxFileSize: 100, maxArchivedFilesCount: 5))!

            for i in 0..<10 {
                fd.write(LogEntry(level: .info, message: "old entry \(i) " + String(repeating: "padding ", count: 20)))
            }
            fd.flush()

            // Rotation really did happen, so the marker below is genuinely
            // landing in a post-rotation file rather than a never-rotated one.
            #expect(!archives(in: dir, baseName: "test.log").isEmpty)

            fd.write(LogEntry(level: .info, message: "FRESH_MARKER"))
            fd.flush()

            // Deliberately reads the current file only, not the archives: the
            // point of this test is that writes resume into the *fresh* file.
            let content = try String(contentsOf: logURL, encoding: .utf8)
            #expect(content.contains("FRESH_MARKER"))
        }

        @Test func noRotationWhenConfigIsNil() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("test.log")

            let fd = FileDestination(url: logURL)!

            for i in 0..<20 {
                fd.write(LogEntry(level: .info, message: "entry \(i) with lots of padding text to make file large"))
            }
            fd.flush()

            let found = archives(in: dir, baseName: "test.log")
            #expect(found.isEmpty)
        }

        @Test func preExistingLargeFileTriggersRotation() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("test.log")

            // Create a file that's already over threshold
            let bigData = Data(repeating: 65, count: 200)
            try bigData.write(to: logURL)

            let fd = FileDestination(url: logURL, rotation: FileRotationConfig(maxFileSize: 100, maxArchivedFilesCount: 5))!

            fd.write(LogEntry(level: .info, message: "trigger"))
            fd.flush()

            let found = archives(in: dir, baseName: "test.log")
            #expect(!found.isEmpty)
        }

        @Test func concurrentWritesWithRotationNoCrash() async throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("test.log")

            let fd = FileDestination(url: logURL, rotation: FileRotationConfig(maxFileSize: 200, maxArchivedFilesCount: 10))!

            await withTaskGroup(of: Void.self) { group in
                for i in 0..<100 {
                    group.addTask {
                        fd.write(LogEntry(level: .info, message: "concurrent-\(i)-padding-text-to-grow-file"))
                    }
                }
            }
            fd.flush()

            // Verify current file exists and is readable
            let content = try String(contentsOf: logURL, encoding: .utf8)
            #expect(!content.isEmpty || FileManager.default.fileExists(atPath: logURL.path))
        }

        @Test func allEntriesPreservedAcrossRotation() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("test.log")

            let fd = FileDestination(url: logURL, rotation: FileRotationConfig(maxFileSize: 100, maxArchivedFilesCount: 50))!

            let count = 30
            for i in 0..<count {
                fd.write(LogEntry(level: .info, message: "SEQ_\(i)_END"))
            }
            fd.flush()

            // Read all files: current + archives
            var allContent = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let archiveURLs = archives(in: dir, baseName: "test.log")
            for archive in archiveURLs {
                allContent += (try? String(contentsOf: archive, encoding: .utf8)) ?? ""
            }

            for i in 0..<count {
                #expect(allContent.contains("SEQ_\(i)_END"))
            }
        }

        @Test func deinitWithPendingWritesDoesNotCrash() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("deinit.log")

            // Repeatedly create a destination, enqueue a write, then drop the only
            // strong reference while the write may still be in flight. When the
            // pending block is the last owner, deinit runs on the queue's own worker
            // thread — pre-fix this SIGTRAPs in queue.sync; post-fix reaching the end
            // of the loop is the assertion.
            for i in 0..<50 {
                var fd: FileDestination? = FileDestination(url: logURL)
                fd?.write(LogEntry(level: .info, message: "pending write \(i)"))
                fd = nil
            }

            // The async deinit cleanup must complete and leave the file usable.
            let fd = FileDestination(url: logURL)
            #expect(fd != nil)
            fd?.flush()

            let handle = try FileHandle(forWritingTo: logURL)
            try? handle.close()
        }

        @Test func reopenAfterExternalDeletionRecreatesFile() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("test.log")

            // healthCheckStride: 1 makes recovery depend on the number of
            // flushes rather than on how many entries GCD happened to coalesce
            // into each batch. Without it, whether this passed came down to
            // scheduling: if all the post-deletion entries landed in a single
            // batch, that one write went to the orphaned inode and nothing was
            // left to find.
            let fd = FileDestination(
                url: logURL,
                rotation: FileRotationConfig(maxFileSize: 64, maxArchivedFilesCount: 10),
                tunables: .init(reopenBackoff: 0, healthCheckStride: 1)
            )!

            fd.write(LogEntry(level: .info, message: "before deletion"))
            fd.flush()

            // Simulate the live log file being deleted out from under us. The open
            // handle still points at the now-unlinked inode, so writes keep going
            // nowhere until the handle is noticed to be unlinked and replaced.
            try FileManager.default.removeItem(at: logURL)

            // Flush per entry so each one is its own batch: the first is lost to
            // the orphaned inode, and every later one must reach a real file.
            for i in 0..<30 {
                fd.write(LogEntry(level: .info, message: "POSTDEL_\(i)_END padding to cross threshold"))
                fd.flush()
            }

            // The log file must have been recreated at its original path...
            #expect(FileManager.default.fileExists(atPath: logURL.path))

            // ...and the post-deletion entries must be recoverable from the current
            // file plus any archives created by subsequent rotations.
            var allContent = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            for archive in archives(in: dir, baseName: "test.log") {
                allContent += (try? String(contentsOf: archive, encoding: .utf8)) ?? ""
            }
            #expect(allContent.contains("POSTDEL_"))
        }

        @Test func externalDeletionWithoutRotationConfigRecovers() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("nodrot.log")

            // No rotation configured: nothing ever calls moveItem, so the old
            // recovery path (which only ran from rotation) never fired. Writes
            // to the unlinked inode succeeded forever and landed nowhere.
            // healthCheckStride: 1 checks after every flush so the test does
            // not depend on batching cadence.
            let fd = FileDestination(
                url: logURL,
                tunables: .init(reopenBackoff: 0, healthCheckStride: 1)
            )!

            fd.write(LogEntry(level: .info, message: "before deletion"))
            fd.flush()
            #expect(try String(contentsOf: logURL, encoding: .utf8).contains("before deletion"))

            try FileManager.default.removeItem(at: logURL)

            // First write after the delete lands in the unlinked inode and is
            // lost; the health check that follows it notices st_nlink == 0 and
            // reopens, so subsequent entries reach a readable file.
            fd.write(LogEntry(level: .info, message: "first after deletion"))
            fd.flush()
            fd.write(LogEntry(level: .info, message: "AFTER_RECOVERY"))
            fd.flush()

            #expect(FileManager.default.fileExists(atPath: logURL.path))
            #expect(try String(contentsOf: logURL, encoding: .utf8).contains("AFTER_RECOVERY"))
        }

        @Test func deleteAndRecreateIsDetectedByLinkCount() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("recreated.log")

            let fd = FileDestination(
                url: logURL,
                tunables: .init(reopenBackoff: 0, healthCheckStride: 1)
            )!
            fd.write(LogEntry(level: .info, message: "original inode"))
            fd.flush()

            // Delete *and recreate* at the same path — the case a plain
            // fileExists check cannot see, because the path is occupied again
            // while our descriptor still points at the orphaned inode.
            try FileManager.default.removeItem(at: logURL)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)

            fd.write(LogEntry(level: .info, message: "lost to the orphan"))
            fd.flush()
            fd.write(LogEntry(level: .info, message: "REACHES_NEW_INODE"))
            fd.flush()

            #expect(try String(contentsOf: logURL, encoding: .utf8).contains("REACHES_NEW_INODE"))
        }

        @Test func failedReopenBacksOffWithoutChurningArchives() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logDir = dir.appendingPathComponent("logs")
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logURL = logDir.appendingPathComponent("churn.log")

            let fd = FileDestination(
                url: logURL,
                rotation: FileRotationConfig(maxFileSize: 80, maxArchivedFilesCount: 5),
                tunables: .init(reopenBackoff: 0.05, healthCheckStride: 1)
            )!

            for i in 0..<10 {
                fd.write(LogEntry(level: .info, message: "healthy entry \(i) with padding"))
                fd.flush()
            }
            let archivesBefore = archives(in: logDir, baseName: "churn.log")
            #expect(!archivesBefore.isEmpty)

            // Replace the log *file* with a directory: open(O_WRONLY) then
            // fails with EISDIR for as long as it stays that way, while the log
            // directory and its archives remain on disk to be counted.
            try FileManager.default.removeItem(at: logURL)
            try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: false)

            for i in 0..<40 {
                fd.write(LogEntry(level: .info, message: "degraded entry \(i) with padding"))
                fd.flush()
            }

            #expect(!fd.isHealthyForTesting)

            // The point of the test: resetting the size and age counters on the
            // way down kept rotation from re-entering. Pre-fix currentFileSize
            // stayed above maxFileSize, so every write archived the missing
            // file again until pruning had eaten every real archive.
            let archivesDuring = archives(in: logDir, baseName: "churn.log")
            #expect(archivesDuring.map(\.lastPathComponent) == archivesBefore.map(\.lastPathComponent))

            // Restore the path; the destination must come back on its own.
            try FileManager.default.removeItem(at: logURL)
            Thread.sleep(forTimeInterval: 0.1)  // outlast reopenBackoff

            fd.write(LogEntry(level: .info, message: "RECOVERED_ENTRY"))
            fd.flush()

            #expect(fd.isHealthyForTesting)

            // The recovery batch carries the drop notice for everything lost
            // while degraded, which is itself enough to trip the 80-byte
            // rotation threshold — so the entry may be in the current file or
            // in the archive that write produced.
            var allContent = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            for archive in archives(in: logDir, baseName: "churn.log") {
                allContent += (try? String(contentsOf: archive, encoding: .utf8)) ?? ""
            }
            #expect(allContent.contains("RECOVERED_ENTRY"))
            #expect(allContent.contains("dropped"))
        }

        // Locked probe (bug category: destructive edge case). A fast burst rotates
        // many times within the same wall-clock second, so every archive shares the
        // 1-second-resolution timestamp in its name. Retention must still keep the
        // NEWEST archives. Pre-fix, pruning sorted by filename and fell through to
        // the random UUID suffix on the tied timestamps, keeping arbitrary (often
        // older) archives and silently deleting newer logs — a probe of this saw an
        // archive from entry ~46 survive while archives around entry ~150–330 were
        // deleted. Post-fix, sorting by modification date keeps a contiguous newest
        // suffix.
        @Test func pruningKeepsNewestArchivesUnderSameSecondBurst() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("burst.log")

            let fd = FileDestination(url: logURL, rotation: FileRotationConfig(maxFileSize: 60, maxArchivedFilesCount: 3))!

            // Flush per entry so each one is its own batch and rotation fires as
            // often as possible, reproducing the same-second archive burst this
            // test is about. Without it, batching coalesces the writes into a
            // handful of large batches and only a few rotations happen — which
            // exercises the batching, not the pruning order under test.
            let count = 200
            for i in 0..<count {
                fd.write(LogEntry(level: .info, message: "SEQ_\(String(format: "%05d", i))_END"))
                fd.flush()
            }

            var surviving = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            for archive in archives(in: dir, baseName: "burst.log") {
                surviving += (try? String(contentsOf: archive, encoding: .utf8)) ?? ""
            }

            // The most recent entry is always retained (it lives in the current file).
            #expect(surviving.contains("SEQ_\(String(format: "%05d", count - 1))_END"))

            // With retention 3 and a tiny threshold, only the last handful of entries
            // can survive. No entry from the first half of the run may remain — pre-fix,
            // random-UUID tiebreaking let early archives slip through and this fails.
            for i in 0..<(count / 2) {
                #expect(
                    !surviving.contains("SEQ_\(String(format: "%05d", i))_END"),
                    "early entry SEQ_\(i) should have been pruned but survived"
                )
            }
        }
    }
}

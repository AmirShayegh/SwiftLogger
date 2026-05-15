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

            let fd = FileDestination(url: logURL, rotationConfig: FileRotationConfig(maxFileSize: 100, maxArchivedFilesCount: 5))!

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

            let fd = FileDestination(url: logURL, rotationConfig: FileRotationConfig(maxFileSize: 50, maxArchivedFilesCount: 5))!

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

            let fd = FileDestination(url: logURL, rotationConfig: FileRotationConfig(maxFileSize: 50, maxArchivedFilesCount: 2))!

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

            let fd = FileDestination(url: logURL, rotationConfig: FileRotationConfig(maxFileSize: 50, maxArchivedFilesCount: 0))!

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

            let fd = FileDestination(url: logURL, rotationConfig: FileRotationConfig(maxFileSize: 50, maxArchivedFilesCount: 5))!

            for i in 0..<10 {
                fd.write(LogEntry(level: .info, message: "old entry \(i) padding"))
            }
            fd.flush()

            // The current file should exist and be writable
            fd.write(LogEntry(level: .info, message: "FRESH_MARKER"))
            fd.flush()

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

            let fd = FileDestination(url: logURL, rotationConfig: FileRotationConfig(maxFileSize: 100, maxArchivedFilesCount: 5))!

            fd.write(LogEntry(level: .info, message: "trigger"))
            fd.flush()

            let found = archives(in: dir, baseName: "test.log")
            #expect(!found.isEmpty)
        }

        @Test func concurrentWritesWithRotationNoCrash() async throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("test.log")

            let fd = FileDestination(url: logURL, rotationConfig: FileRotationConfig(maxFileSize: 200, maxArchivedFilesCount: 10))!

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

            let fd = FileDestination(url: logURL, rotationConfig: FileRotationConfig(maxFileSize: 100, maxArchivedFilesCount: 50))!

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
    }
}

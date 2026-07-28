import Testing
import Foundation
#if canImport(Compression)
import Compression
#endif
@testable import Logger

extension AllLoggerTests {

    /// Age-based rotation and gzipped archives.
    struct RotationPolicyTests {

        private func makeTempDir() throws -> URL {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("logger-pol-\(UUID().uuidString)")
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
                    return suffix.range(
                        of: #"^\d{8}T\d{6}Z_[a-f0-9]{8}(\.gz)?$"#,
                        options: .regularExpression
                    ) != nil
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        // MARK: - Age-based rotation

        @Test func ageTriggersRotationBelowTheSizeThreshold() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("aged.log")

            // Huge size limit so only age can trigger rotation.
            let fd = FileDestination(
                url: url,
                rotation: FileRotationConfig(
                    maxFileSize: 10_000_000,
                    maxArchivedFilesCount: 5,
                    maxFileAge: 0.05
                )
            )!

            fd.write(LogEntry(level: .info, message: "before the deadline"))
            fd.flush()
            #expect(archives(in: dir, baseName: "aged.log").isEmpty)

            Thread.sleep(forTimeInterval: 0.1)

            fd.write(LogEntry(level: .info, message: "after the deadline"))
            fd.flush()

            let found = archives(in: dir, baseName: "aged.log")
            #expect(found.count == 1)

            // Rotation is checked after the write, so the entry that trips the
            // deadline is archived along with everything before it and the fresh
            // file starts empty — the same ordering size-based rotation has.
            let archived = try String(contentsOf: found[0], encoding: .utf8)
            #expect(archived.contains("before the deadline"))
            #expect(archived.contains("after the deadline"))
            #expect(try String(contentsOf: url, encoding: .utf8).isEmpty)
        }

        @Test func ageRotationDoesNotFireWhileIdle() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("idle.log")

            let fd = FileDestination(
                url: url,
                rotation: FileRotationConfig(
                    maxFileSize: 10_000_000,
                    maxArchivedFilesCount: 5,
                    maxFileAge: 0.05
                )
            )!
            fd.write(LogEntry(level: .info, message: "only entry"))
            fd.flush()

            Thread.sleep(forTimeInterval: 0.1)

            // Rotation is checked after a write, so an app that stops logging
            // must not accumulate empty archives.
            #expect(archives(in: dir, baseName: "idle.log").isEmpty)
        }

        @Test func sizeStillTriggersRotationWhenAgeIsAlsoConfigured() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("both.log")

            let fd = FileDestination(
                url: url,
                rotation: FileRotationConfig(
                    maxFileSize: 80,
                    maxArchivedFilesCount: 5,
                    maxFileAge: 3600  // far away; size must be what fires
                )
            )!

            for i in 0..<10 {
                fd.write(LogEntry(level: .info, message: "size driven entry \(i)"))
                fd.flush()
            }

            #expect(!archives(in: dir, baseName: "both.log").isEmpty)
        }

        @Test func nilMaxFileAgeKeepsSizeOnlyBehaviour() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("sizeonly.log")

            let fd = FileDestination(
                url: url,
                rotation: FileRotationConfig(maxFileSize: 10_000_000, maxArchivedFilesCount: 5)
            )!
            fd.write(LogEntry(level: .info, message: "entry"))
            fd.flush()
            Thread.sleep(forTimeInterval: 0.05)
            fd.write(LogEntry(level: .info, message: "another"))
            fd.flush()

            #expect(archives(in: dir, baseName: "sizeonly.log").isEmpty)
        }

        // MARK: - Gzip

        #if canImport(Compression)

        @Test func gzipRoundTripsThroughTheSystemGunzip() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // Realistic log-shaped input, repetitive enough to actually compress.
            let original = (0..<400)
                .map { " INFO | 12:15:30.842 | File.swift:\($0) | message number \($0)" }
                .joined(separator: "\n")
            let raw = Data(original.utf8)

            let gzipped = try #require(Gzip.compress(raw))

            // Magic number and DEFLATE method, per RFC 1952.
            #expect(gzipped[0] == 0x1f)
            #expect(gzipped[1] == 0x8b)
            #expect(gzipped[2] == 0x08)
            #expect(gzipped.count < raw.count)

            // The real test: the system gunzip must accept it and return the
            // original bytes. A hand-built container that only our own code can
            // read would be worthless.
            let gzURL = dir.appendingPathComponent("probe.gz")
            try gzipped.write(to: gzURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            process.arguments = ["-c", gzURL.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let decompressed = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            #expect(process.terminationStatus == 0)
            #expect(decompressed == raw)
            #expect(String(data: decompressed, encoding: .utf8) == original)
        }

        /// Round-trips `url` through the system gunzip and returns the bytes.
        private func gunzip(_ url: URL) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            process.arguments = ["-c", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let decompressed = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return decompressed
        }

        @Test func compressFileRoundTripsThroughTheSystemGunzip() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // Comfortably more than the 64 KB chunk size, so the streaming
            // encoder has to carry state across several reads and the CRC has
            // to accumulate across them. A single-chunk input would not
            // exercise either.
            let original = (0..<4_000)
                .map { " INFO | 12:15:30.842 | File.swift:\($0) | streamed message number \($0)" }
                .joined(separator: "\n")
            let raw = Data(original.utf8)
            #expect(raw.count > 64 * 1024)

            let source = dir.appendingPathComponent("big.log")
            try raw.write(to: source)
            let gzURL = dir.appendingPathComponent("big.log.gz")

            #expect(Gzip.compressFile(at: source, to: gzURL))

            let produced = try Data(contentsOf: gzURL)
            #expect(produced[0] == 0x1f && produced[1] == 0x8b && produced[2] == 0x08)
            #expect(produced.count < raw.count)
            #expect(try gunzip(gzURL) == raw)
        }

        @Test func compressFileMatchesTheInMemoryEncoderOnSmallInput() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // Both encoders must produce containers gunzip reads back
            // identically — the streaming trailer computes its CRC and length
            // incrementally, so a divergence here would mean silent corruption.
            let cases = [
                "",
                "x",
                "short line\n",
                String(repeating: "ab", count: 5_000),
                // Exactly one and exactly two chunk-sized inputs: the read loop
                // then takes an extra empty read to learn it is done, which is
                // where a finalize-on-the-wrong-pass bug would show up.
                String(repeating: "c", count: 64 * 1024),
                String(repeating: "d", count: 128 * 1024),
            ]
            for text in cases {
                let raw = Data(text.utf8)
                let source = dir.appendingPathComponent("probe-\(raw.count).log")
                try raw.write(to: source)
                let gzURL = dir.appendingPathComponent("probe-\(raw.count).log.gz")

                #expect(Gzip.compressFile(at: source, to: gzURL))
                #expect(try gunzip(gzURL) == raw)
            }
        }

        @Test func compressFileFailureLeavesNoPartialOutput() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // Case 1: the source cannot be opened at all. This bails before any
            // output file is created, so on its own it does NOT exercise the
            // partial-output cleanup — case 2 is what does.
            let missing = dir.appendingPathComponent("does-not-exist.log")
            let missingGz = dir.appendingPathComponent("does-not-exist.log.gz")
            #expect(!Gzip.compressFile(at: missing, to: missingGz))
            #expect(!FileManager.default.fileExists(atPath: missingGz.path))

            // Case 2: the source opens fine but the *destination* cannot be
            // written, so compressFile fails partway through having already
            // created the .gz. That is the path where a leftover half-written
            // archive would be counted as a real one by pruning.
            let source = dir.appendingPathComponent("real.log")
            try Data(String(repeating: "log line\n", count: 20_000).utf8).write(to: source)

            let readOnlyDir = dir.appendingPathComponent("readonly")
            try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
            let blockedGz = readOnlyDir.appendingPathComponent("real.log.gz")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDir.path) }

            #expect(!Gzip.compressFile(at: source, to: blockedGz))
            #expect(!FileManager.default.fileExists(atPath: blockedGz.path))
        }

        @Test func compressFileTruncatedByAReadErrorIsReportedAsFailure() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }

            // A source that disappears mid-stream. read(upToCount:) returns nil
            // at EOF and *throws* on error; collapsing the two with `try?` made
            // an I/O failure look like end-of-input, so compressFile finalized
            // over a partial file, wrote a matching CRC and length, and returned
            // true — a .gz that `gunzip -t` verifies while compressArchive
            // deletes the complete original.
            let source = dir.appendingPathComponent("vanishing.log")
            try Data(String(repeating: "log line for compression\n", count: 40_000).utf8).write(to: source)
            let gzURL = dir.appendingPathComponent("vanishing.log.gz")

            // Sanity: intact source compresses and round-trips.
            #expect(Gzip.compressFile(at: source, to: gzURL))
            let original = try Data(contentsOf: source)
            #expect(try gunzip(gzURL) == original)
            try FileManager.default.removeItem(at: gzURL)

            // Whatever the outcome on a mid-stream failure, it must never be
            // "success plus a short archive": either the call fails and leaves
            // no output, or it succeeds and the output is complete.
            let succeeded = Gzip.compressFile(at: source, to: gzURL)
            if succeeded {
                #expect(try gunzip(gzURL) == original)
            } else {
                #expect(!FileManager.default.fileExists(atPath: gzURL.path))
            }
        }

        @Test func rotationCompressesArchivesWithTheirContentIntact() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("content.log")

            // The existing compression tests only checked the gzip magic bytes
            // and the file names — a rotation that compressed the wrong bytes,
            // or empty ones, passed them. This reads every archive back and
            // requires the entries to actually be in there.
            let fd = FileDestination(
                url: url,
                rotation: FileRotationConfig(
                    maxFileSize: 200, maxArchivedFilesCount: 100, compressArchives: true
                )
            )!

            let count = 60
            for i in 0..<count {
                fd.write(LogEntry(level: .info, message: "CONTENT_\(String(format: "%03d", i))_END padding padding"))
                fd.flush()
            }

            var recovered = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let found = archives(in: dir, baseName: "content.log")
            #expect(!found.isEmpty)
            for archive in found {
                #expect(archive.pathExtension == "gz")
                let data = try gunzip(archive)
                recovered += String(decoding: data, as: UTF8.self)
            }

            for i in 0..<count {
                #expect(
                    recovered.contains("CONTENT_\(String(format: "%03d", i))_END"),
                    "entry \(i) missing from current file plus archives"
                )
            }
        }

        @Test func gzipHandlesEmptyAndTinyInput() throws {
            let empty = try #require(Gzip.compress(Data()))
            #expect(empty[0] == 0x1f && empty[1] == 0x8b)

            let tiny = try #require(Gzip.compress(Data("x".utf8)))
            #expect(tiny[0] == 0x1f && tiny[1] == 0x8b)
        }

        @Test func crc32MatchesKnownVectors() {
            // Standard CRC-32 check values.
            #expect(Gzip.crc32(Data()) == 0)
            #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
            #expect(Gzip.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
        }

        @Test func rotationWritesGzippedArchives() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("gz.log")

            let fd = FileDestination(
                url: url,
                rotation: FileRotationConfig(
                    maxFileSize: 200,
                    maxArchivedFilesCount: 5,
                    compressArchives: true
                )
            )!

            for i in 0..<40 {
                fd.write(LogEntry(level: .info, message: "compressible entry \(i) padding padding"))
                fd.flush()
            }

            let found = archives(in: dir, baseName: "gz.log")
            #expect(!found.isEmpty)

            // Every archive is gzipped, and none of the uncompressed originals
            // were left behind.
            #expect(found.allSatisfy { $0.pathExtension == "gz" })

            // Contents must survive the round trip.
            let first = try Data(contentsOf: found[0])
            #expect(first[0] == 0x1f && first[1] == 0x8b)
        }

        @Test func gzippedArchivesAreCountedWhenPruning() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("prune.log")

            let keep = 2
            let fd = FileDestination(
                url: url,
                rotation: FileRotationConfig(
                    maxFileSize: 100,
                    maxArchivedFilesCount: keep,
                    compressArchives: true
                )
            )!

            for i in 0..<40 {
                fd.write(LogEntry(level: .info, message: "prune entry \(i) with padding to roll over"))
                fd.flush()
            }

            // Pruning must recognise .gz names, or archives would accumulate
            // without bound.
            #expect(archives(in: dir, baseName: "prune.log").count <= keep)
        }

        @Test func compressionIsOptOut() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("plain.log")

            let fd = FileDestination(
                url: url,
                rotation: FileRotationConfig(maxFileSize: 100, maxArchivedFilesCount: 5)
            )!
            for i in 0..<20 {
                fd.write(LogEntry(level: .info, message: "plain entry \(i) with padding to roll over"))
                fd.flush()
            }

            let found = archives(in: dir, baseName: "plain.log")
            #expect(!found.isEmpty)
            #expect(found.allSatisfy { $0.pathExtension != "gz" })
        }

        #endif

        // MARK: - Deprecated spelling

        @Test func deprecatedRotationConfigLabelStillConstructsAndRotates() throws {
            let dir = try makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("legacy.log")

            // The old rotationConfig: label is deprecated, not removed — existing
            // adopters must keep compiling and rotating. The deprecation warning
            // this line emits is the point of the test.
            let fd = FileDestination(
                url: url,
                rotationConfig: FileRotationConfig(maxFileSize: 80, maxArchivedFilesCount: 5)
            )!

            for i in 0..<10 {
                fd.write(LogEntry(level: .info, message: "legacy entry \(i) with padding"))
                fd.flush()
            }

            #expect(!archives(in: dir, baseName: "legacy.log").isEmpty)
        }
    }
}

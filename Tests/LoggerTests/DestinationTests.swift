import Testing
import Foundation
@testable import Logger

final class MockDestination: LogDestination, @unchecked Sendable {
    let label: String
    let minimumLevel: LogLevel?
    var isEnabled: Bool { true }
    private let lock = NSLock()
    private var _entries: [LogEntry] = []

    var entries: [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    private var _flushCount = 0
    var flushCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _flushCount
    }

    init(label: String = "mock", minimumLevel: LogLevel? = nil) {
        self.label = label
        self.minimumLevel = minimumLevel
    }

    func write(_ entry: LogEntry) {
        lock.lock()
        _entries.append(entry)
        lock.unlock()
    }

    func flush() {
        lock.lock()
        _flushCount += 1
        lock.unlock()
    }
}

/// A destination that formats every entry, mirroring what the built-in console
/// and file destinations do.
final class FormattingDestination: LogDestination, @unchecked Sendable {
    let label: String
    var isEnabled: Bool { true }
    var minimumLevel: LogLevel? { nil }

    private let lock = NSLock()
    private var _lines: [String] = []
    private var _entries: [LogEntry] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }

    var entries: [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    init(label: String) { self.label = label }

    func write(_ entry: LogEntry) {
        let line = entry.format()
        lock.lock()
        _lines.append(line)
        _entries.append(entry)
        lock.unlock()
    }
}

extension AllLoggerTests {

    /// The default-format line is computed once per entry and shared when an
    /// entry fans out to several destinations.
    struct FormatCacheTests {

        // The compute counter is compiled out of release builds, and
        // `swift test -c release` builds the test target without DEBUG too — so
        // every reference to it is gated at source level. The behavioural
        // assertions stay unconditional in both configurations.

        init() {
            Logger.shared.reset()
            #if DEBUG
            LogEntryFormatCache.resetComputeCountForTesting()
            #endif
        }

        @Test func fanOutToMultipleDestinationsFormatsOnce() {
            Logger.shared.consoleLogging(false)

            // Three destinations that each call entry.format(), as the built-in
            // console and file destinations do.
            let a = FormattingDestination(label: "fmt-a")
            let b = FormattingDestination(label: "fmt-b")
            let c = FormattingDestination(label: "fmt-c")
            Logger.shared.addDestination(a).addDestination(b).addDestination(c)

            #if DEBUG
            LogEntryFormatCache.resetComputeCountForTesting()
            #endif
            Logger.shared.log("shared line", level: .error)

            #if DEBUG
            #expect(LogEntryFormatCache.computeCount == 1)
            #endif
            #expect(a.lines == b.lines)
            #expect(b.lines == c.lines)
            #expect(a.lines.first?.contains("shared line") == true)
        }

        @Test func singleDestinationSkipsTheCacheAllocation() {
            Logger.shared.consoleLogging(false)
            let only = FormattingDestination(label: "fmt-only")
            Logger.shared.addDestination(only)

            #if DEBUG
            LogEntryFormatCache.resetComputeCountForTesting()
            #endif
            Logger.shared.log("solo line", level: .error)

            // One destination, one computation — and no cache box was allocated.
            #if DEBUG
            #expect(LogEntryFormatCache.computeCount == 1)
            #endif
            #expect(only.lines.count == 1)
            #expect(only.entries[0].hasFormatCacheForTesting == false)
        }

        @Test func repeatedFormatCallsOnCopiesComputeOnce() {
            Logger.shared.consoleLogging(false)
            let a = FormattingDestination(label: "fmt-a")
            let b = FormattingDestination(label: "fmt-b")
            Logger.shared.addDestination(a).addDestination(b)

            #if DEBUG
            LogEntryFormatCache.resetComputeCountForTesting()
            #endif
            Logger.shared.log("copy me", level: .error)

            // Re-format the entry a destination kept, plus a struct copy of it:
            // the cache reference is shared across copies, so still one compute.
            let kept = a.entries[0]
            let copy = kept
            let fromKept = kept.format()
            let fromCopy = copy.format()

            #if DEBUG
            #expect(LogEntryFormatCache.computeCount == 1)
            #endif
            #expect(kept.hasFormatCacheForTesting)
            #expect(fromKept == fromCopy)
            #expect(fromKept == a.lines[0])
        }

        @Test func directlyConstructedEntriesStillFormat() {
            // A LogEntry built through the public initialiser has no cache box.
            // It must still format correctly, just without sharing.
            #if DEBUG
            LogEntryFormatCache.resetComputeCountForTesting()
            #endif
            let entry = LogEntry(level: .warning, message: "manual", fileName: "Manual.swift", line: 7)

            #expect(entry.format() == entry.format())
            #expect(entry.format().contains("manual"))
            #expect(entry.hasFormatCacheForTesting == false)
            #if DEBUG
            #expect(LogEntryFormatCache.computeCount == 3)
            #endif
        }

        @Test func metadataIsOrderedByKey() {
            let entry = LogEntry(
                level: .info,
                message: "m",
                metadata: ["zebra": 1, "alpha": 2, "middle": 3]
            )
            #expect(entry.format().contains("{alpha=2, middle=3, zebra=1}"))
        }
    }

    struct DestinationTests {

        init() { Logger.shared.reset() }

        @Test func addCustomDestinationReceivesEntries() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("hello", level: .info)

            #expect(mock.entries.count == 1)
            #expect(mock.entries[0].message == "hello")
            #expect(mock.entries[0].level == .info)
        }

        @Test func removeDestinationStopsReceiving() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination()
            Logger.shared.addDestination(mock)
            Logger.shared.removeDestination(label: "mock")
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("should not arrive", level: .info)

            #expect(mock.entries.isEmpty)
        }

        @Test func sameLabelReplacement() {
            Logger.shared.consoleLogging(false)
            let first = MockDestination(label: "test")
            let second = MockDestination(label: "test")
            Logger.shared.addDestination(first)
            Logger.shared.addDestination(second)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("msg", level: .info)

            #expect(first.entries.isEmpty)
            #expect(second.entries.count == 1)
        }

        @Test func perDestinationMinimumLevelFilters() {
            Logger.shared.consoleLogging(false)
            let mock = MockDestination(label: "strict", minimumLevel: .warning)
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("debug msg", level: .debug)
            Logger.shared.log("warning msg", level: .warning)
            Logger.shared.log("error msg", level: .error)

            #expect(mock.entries.count == 2)
            #expect(mock.entries[0].message == "warning msg")
            #expect(mock.entries[1].message == "error msg")
        }

        @Test func globalGateStillApplies() {
            Logger.shared.consoleLogging(false)
            Logger.shared.minimumLevel(.error)
            let mock = MockDestination(label: "permissive", minimumLevel: .debug)
            Logger.shared.addDestination(mock)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("should be filtered", level: .info)

            #expect(mock.entries.isEmpty)
        }

        @Test func multipleDestinationsDifferentLevels() {
            Logger.shared.consoleLogging(false)
            let all = MockDestination(label: "all")
            let errorsOnly = MockDestination(label: "errors", minimumLevel: .error)
            Logger.shared.addDestination(all)
            Logger.shared.addDestination(errorsOnly)
            Logger.shared.setOutputSink { _ in }

            Logger.shared.log("debug", level: .debug)
            Logger.shared.log("error", level: .error)

            #expect(all.entries.count == 2)
            #expect(errorsOnly.entries.count == 1)
            #expect(errorsOnly.entries[0].message == "error")
        }

        @Test func addDestinationFluentChaining() {
            let mock = MockDestination()
            let result = Logger.shared.addDestination(mock)
            #expect(result === Logger.shared)
        }

        @Test func removeDestinationFluentChaining() {
            let result = Logger.shared.removeDestination(label: "nonexistent")
            #expect(result === Logger.shared)
        }

        // Locked probe (bug category: silent no-op at a boundary). File destinations
        // write asynchronously, and a singleton-owned destination cannot be reached
        // by the caller to drain it — so at process exit the tail of the log was
        // silently lost. Logger.flush() must forward to every destination.
        @Test func loggerFlushForwardsToAllDestinations() {
            let a = MockDestination(label: "flush-a")
            let b = MockDestination(label: "flush-b")
            Logger.shared.addDestination(a).addDestination(b)

            Logger.shared.flush()

            #expect(a.flushCount >= 1)
            #expect(b.flushCount >= 1)
        }

        // Locked probe (bug category: silent no-op at a boundary). A real end-to-end
        // durability assertion: 500 entries logged through the full pipeline into an
        // async file destination, then flush() with NO sleep. flush() must act as a
        // barrier that drains the write queue, so every entry is on disk immediately.
        // Pre-fix there was no Logger.flush(), and the singleton-owned destination
        // could not be drained at all.
        @Test func loggerFlushPersistsQueuedFileWrites() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("logger-flush-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("flush.log")

            let fd = FileDestination(url: logURL)!
            Logger.shared.consoleLogging(false)
            Logger.shared.addDestination(fd)

            let count = 500
            for i in 0..<count {
                Logger.shared.log("FLUSH_\(i)_END", level: .info)
            }
            Logger.shared.flush()

            let content = try String(contentsOf: logURL, encoding: .utf8)
            for i in 0..<count {
                #expect(content.contains("FLUSH_\(i)_END"))
            }
        }

        @Test func logEntryPublicInit() {
            let entry = LogEntry(level: .warning, message: "test")
            #expect(entry.level == .warning)
            #expect(entry.message == "test")
            #expect(entry.metadata == nil)
            #expect(entry.correlation == nil)
            #expect(entry.subsystem == nil)

            let formatted = entry.format()
            #expect(formatted.contains(" WARN"))
            #expect(formatted.contains("test"))
        }

        @Test func logEntryFormatIncludesAllFields() {
            let entry = LogEntry(
                level: .debug,
                message: "decoded",
                metadata: ["pts": 42],
                correlation: "job-1",
                subsystem: "decoder",
                fileName: "Test.swift",
                line: 99
            )
            let formatted = entry.format()
            #expect(formatted.contains("DEBUG"))
            #expect(formatted.contains("[job-1]"))
            #expect(formatted.contains("[decoder]"))
            #expect(formatted.contains("decoded"))
            #expect(formatted.contains("{pts=42}"))
            #expect(formatted.contains("Test.swift:99"))
        }

        @Test func fileDestinationCustomURL() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let logURL = tmp.appendingPathComponent("test.log")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let fd = FileDestination(url: logURL)
            #expect(fd != nil)
            #expect(fd!.label == "file")

            fd!.write(LogEntry(level: .info, message: "hello file"))
            fd!.flush()

            let content = try String(contentsOf: logURL, encoding: .utf8)
            #expect(content.contains("hello file"))
        }

        @Test func consoleDestinationPublicInit() {
            let console = ConsoleDestination(minimumLevel: .warning)
            #expect(console.label == "console")
            #expect(console.minimumLevel == .warning)
        }

        // MARK: - Default vs. Custom File Destination Scoping

        /// Reads `url` repeatedly until it contains `marker` or `timeout` elapses.
        /// Logger-owned file destinations write asynchronously and cannot be reached
        /// for a direct `flush()`, so polling stands in for one.
        private func waitForContent(
            of url: URL,
            containing marker: String,
            timeout: TimeInterval = 2.0
        ) -> String {
            let deadline = Date().addingTimeInterval(timeout)
            var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            while !content.contains(marker) && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
                content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            return content
        }

        @Test func fileLoggingFalsePreservesCustomFileDestinations() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let customURL = tmp.appendingPathComponent("custom.log")

            Logger.shared.consoleLogging(false)
            Logger.shared.fileLogging(url: customURL, label: "custom")

            // Disabling the default file destination is scoped to the "file" label,
            // so a differently-labelled custom destination must survive. The flag is
            // label-scoped too, so it reports false here — survival is proven by the
            // custom destination still receiving writes below.
            Logger.shared.fileLogging(false)
            #expect(!Logger.shared.isFileLoggingActive)

            Logger.shared.log("survives default disable", level: .info)

            let content = waitForContent(of: customURL, containing: "survives default disable")
            #expect(content.contains("survives default disable"))
        }

        @Test func fileLoggingTrueCreatesDefaultAlongsideCustom() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let customURL = tmp.appendingPathComponent("custom.log")

            // fileLogging(true) writes the default destination to the real
            // ~/Library/Logs/app.log. Track whether it pre-existed so we can remove
            // any empty file we create and keep the test hermetic.
            let defaultURL = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Logs/app.log")
            let defaultExistedBefore = defaultURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
            defer {
                if let defaultURL, !defaultExistedBefore {
                    try? FileManager.default.removeItem(at: defaultURL)
                }
            }

            Logger.shared.consoleLogging(false)
            Logger.shared.fileLogging(url: customURL, label: "custom")

            // With only a "custom"-labelled file destination present, enabling the
            // default must add a "file" destination alongside it rather than silently
            // no-opping (the old type-based guard would have skipped creation).
            Logger.shared.fileLogging(true)
            #expect(Logger.shared.isFileLoggingActive)

            // Disabling again removes only the "file" destination; the custom one is
            // left intact and still active. Under the old type-based behaviour this
            // removeAll would have destroyed the custom destination too.
            Logger.shared.fileLogging(false)
            #expect(!Logger.shared.isFileLoggingActive)

            Logger.shared.log("custom survives round trip", level: .info)

            let content = waitForContent(of: customURL, containing: "custom survives round trip")
            #expect(content.contains("custom survives round trip"))
        }

        // MARK: - Drain on Replace / Remove

        @Test func replacingFileDestinationDrainsItsBuffer() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let url = tmp.appendingPathComponent("replace.log")

            Logger.shared.consoleLogging(false)
            Logger.shared.fileLogging(url: url, label: "replaced")
            Logger.shared.log("first generation", level: .info)

            // Same label, same URL: the predecessor's buffered entry must be
            // drained by the replacement — before the successor writes — not
            // left to race the deinit drain or be overwritten.
            Logger.shared.fileLogging(url: url, label: "replaced")
            Logger.shared.log("second generation", level: .info)
            Logger.shared.flush()

            let content = try String(contentsOf: url, encoding: .utf8)
            let first = try #require(content.range(of: "first generation"))
            let second = try #require(content.range(of: "second generation"))
            #expect(first.lowerBound < second.lowerBound)

            // Each entry exactly once — nothing lost, nothing duplicated.
            #expect(content.components(separatedBy: "first generation").count == 2)
            #expect(content.components(separatedBy: "second generation").count == 2)
        }

        @Test func removingFileDestinationDrainsSynchronously() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let url = tmp.appendingPathComponent("removed.log")

            Logger.shared.consoleLogging(false)
            Logger.shared.fileLogging(url: url, label: "removed")
            Logger.shared.log("buffered before removal", level: .info)
            Logger.shared.removeDestination(label: "removed")

            // No polling on purpose: the drain is part of removeDestination's
            // contract, so the entry must be on disk the moment it returns.
            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(content.contains("buffered before removal"))
        }

        @Test func addDestinationDrainsTheDestinationItDisplaces() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let url = tmp.appendingPathComponent("displaced.log")

            Logger.shared.consoleLogging(false)
            Logger.shared.addDestination(FileDestination(url: url, label: "swapped")!)
            Logger.shared.log("buffered in predecessor", level: .info)

            // addDestination replaces a same-labelled destination. The one being
            // displaced is about to be released, so its buffer has to be drained
            // as part of the swap rather than left to the deinit race.
            Logger.shared.addDestination(FileDestination(url: url, label: "swapped")!)

            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(content.contains("buffered in predecessor"))
        }

        @Test func disablingFileLoggingDrainsTheBuffer() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let url = tmp.appendingPathComponent("disabled.log")

            Logger.shared.consoleLogging(false)
            Logger.shared.fileLogging(url: url, label: "file")
            Logger.shared.log("buffered before disable", level: .info)
            Logger.shared.fileLogging(false)

            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(content.contains("buffered before disable"))
        }

        /// A formatter that reconfigures the logger while rendering a drop
        /// notice. Real formatters reach back into the logger for diagnostics,
        /// and the notice is the one line rendered from inside the drain.
        private final class ReconfiguringFormatter: LogFormatter, @unchecked Sendable {
            private let lock = NSLock()
            private var _reentered = false
            var reentered: Bool { lock.withLock { _reentered } }

            func format(_ entry: LogEntry) -> String {
                if entry.message.contains("dropped") {
                    lock.withLock { _reentered = true }
                    Logger.shared.minimumLevel(.debug)
                }
                return entry.message
            }
        }

        /// Runs `work` on a background thread, failing rather than hanging the
        /// whole suite if it never returns.
        private func expectCompletes(
            within timeout: TimeInterval = 10,
            _ description: String,
            _ work: @escaping @Sendable () -> Void
        ) {
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                work()
                done.signal()
            }
            #expect(done.wait(timeout: .now() + timeout) == .success, "\(description) did not return")
        }

        @Test func retiringADestinationWhoseFormatterReconfiguresDoesNotDeadlock() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let url = tmp.appendingPathComponent("reentrant-retire.log")

            let formatter = ReconfiguringFormatter()
            let fd = FileDestination(
                url: url,
                label: "reentrant",
                formatter: formatter,
                tunables: .init(maxBufferedEntries: 2, flushInterval: 600, flushByteThreshold: 1_000_000)
            )!

            Logger.shared.consoleLogging(false)
            Logger.shared.addDestination(fd)
            // Overflow the buffer so the drain has a drop notice to render —
            // that notice is what runs the user's formatter.
            for i in 0..<6 { fd.write(LogEntry(level: .info, message: "kept \(i)")) }

            // removeDestination drains the outgoing destination. If that drain
            // happens while writeLock is held, the formatter's minimumLevel call
            // blocks on the very lock this thread owns and nothing ever returns.
            expectCompletes("removeDestination") {
                Logger.shared.removeDestination(label: "reentrant")
            }
            #expect(formatter.reentered)
        }

        @Test func resetWithAReconfiguringFormatterDoesNotDeadlock() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let url = tmp.appendingPathComponent("reentrant-reset.log")

            let formatter = ReconfiguringFormatter()
            let fd = FileDestination(
                url: url,
                label: "reentrant",
                formatter: formatter,
                tunables: .init(maxBufferedEntries: 2, flushInterval: 600, flushByteThreshold: 1_000_000)
            )!

            Logger.shared.consoleLogging(false)
            Logger.shared.addDestination(fd)
            for i in 0..<6 { fd.write(LogEntry(level: .info, message: "kept \(i)")) }

            expectCompletes("reset") {
                Logger.shared.reset()
            }
            #expect(formatter.reentered)
        }

        @Test func resetDrainsFileDestinationBuffers() throws {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logger-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let url = tmp.appendingPathComponent("reset.log")

            Logger.shared.consoleLogging(false)
            Logger.shared.fileLogging(url: url, label: "custom")
            Logger.shared.log("buffered before reset", level: .info)

            // reset() drops every destination at once. Each one is the last
            // reference to its write queue, so the buffers must be drained
            // before the release or the tail of the log is simply gone.
            Logger.shared.reset()

            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(content.contains("buffered before reset"))
        }
    }
}

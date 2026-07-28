import Foundation

/// Configuration for automatic log file rotation.
public struct FileRotationConfig: Sendable {
    /// Maximum file size in bytes before rotation triggers. Default: 10 MB.
    /// This is a soft threshold: writes are batched, so the file may exceed it
    /// by up to one batch.
    public var maxFileSize: UInt64
    /// Maximum number of archived log files to keep. 0 means no archives retained. Default: 5.
    public var maxArchivedFilesCount: Int
    /// How old the current file may get before it is rotated regardless of size.
    /// `nil` (the default) rotates on size alone.
    ///
    /// Age is measured from the file's creation date, so it survives process
    /// restarts. Like `maxFileSize` this is checked after a write, so a file
    /// only rotates once something is actually logged past the deadline — an
    /// idle app does not roll its log over.
    public var maxFileAge: TimeInterval?
    /// Whether to gzip archives as they are rotated out. Default: `false`.
    ///
    /// Compressed archives get a `.gz` suffix. Log text typically compresses by
    /// around 10:1, so this trades a little CPU at rotation for a lot of disk.
    public var compressArchives: Bool

    public init(
        maxFileSize: UInt64 = 10_485_760,
        maxArchivedFilesCount: Int = 5,
        maxFileAge: TimeInterval? = nil,
        compressArchives: Bool = false
    ) {
        self.maxFileSize = maxFileSize
        self.maxArchivedFilesCount = max(0, maxArchivedFilesCount)
        self.maxFileAge = maxFileAge.map { max(0, $0) }
        self.compressArchives = compressArchives
    }
}

public final class FileDestination: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<Bool>()
    public let label: String
    private let queue: DispatchQueue
    private let fileURL: URL
    private let rotationConfig: FileRotationConfig?
    private let _minimumLevel: LogLevel?

    /// Renders each entry. Immutable, so it needs no lock.
    public let formatter: any LogFormatter

    // MARK: - Serial-queue-only state
    //
    // `fileHandle`, `currentFileSize`, and everything rotation touches are read
    // and written exclusively on `queue`, so they need no lock.

    private var fileHandle: FileHandle
    private var currentFileSize: UInt64
    /// When the current log file came into being, for age-based rotation. Read
    /// from the file on open so it survives a process restart.
    private var currentFileStart: Date

    // MARK: - Buffer state (guarded by `stateLock`)

    private let stateLock = UnfairLock()
    private var pending = Data()
    private var pendingCount = 0
    private var droppedCount = 0
    private var scheduledFlush: DispatchWorkItem?
    /// Whether `scheduledFlush` was dispatched to run immediately rather than
    /// after `flushInterval`.
    private var scheduledFlushIsImmediate = false

    /// Entries buffered before new ones are dropped. Bounds the memory a burst
    /// of logging can consume when the disk cannot keep up.
    internal var maxBufferedEntries = 1_000
    /// How long a partial buffer waits before being written.
    internal var flushInterval: TimeInterval = 0.1
    /// Buffer size that triggers an immediate write rather than waiting out the
    /// interval.
    ///
    /// Clamped to the rotation threshold in `init`: buffering more than a whole
    /// log file's worth guarantees blowing past `maxFileSize` before rotation
    /// gets a chance to look, so the overshoot stays bounded by one batch.
    internal var flushByteThreshold = defaultFlushByteThreshold

    internal static let defaultFlushByteThreshold = 4_096

    public init?(
        url: URL,
        label: String = "file",
        minimumLevel: LogLevel? = nil,
        rotation: FileRotationConfig? = nil,
        formatter: any LogFormatter = DefaultLogFormatter()
    ) {
        self.label = label
        self.fileURL = url
        self._minimumLevel = minimumLevel
        self.rotationConfig = rotation
        self.formatter = formatter

        if !FileManager.default.fileExists(atPath: url.path) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil) else {
                return nil
            }
        }

        guard let handle = try? FileHandle(forWritingTo: url) else {
            return nil
        }

        self.fileHandle = handle
        self.currentFileSize = handle.seekToEndOfFile()
        self.currentFileStart = Self.creationDate(of: url)
        self.queue = DispatchQueue(label: "com.logger.filewriter.\(label)")
        self.queue.setSpecific(key: Self.queueKey, value: true)

        if let maxFileSize = rotation?.maxFileSize {
            self.flushByteThreshold = max(
                1,
                Int(min(maxFileSize, UInt64(Self.defaultFlushByteThreshold)))
            )
        }
    }

    /// Deprecated spelling of ``init(url:label:minimumLevel:rotation:formatter:)``.
    ///
    /// `rotationConfig:` deliberately has no default value — giving it one would
    /// make `FileDestination(url:)` ambiguous between the two initializers.
    @available(*, deprecated, renamed: "init(url:label:minimumLevel:rotation:formatter:)")
    public convenience init?(
        url: URL,
        label: String = "file",
        minimumLevel: LogLevel? = nil,
        rotationConfig: FileRotationConfig?,
        formatter: any LogFormatter = DefaultLogFormatter()
    ) {
        self.init(
            url: url,
            label: label,
            minimumLevel: minimumLevel,
            rotation: rotationConfig,
            formatter: formatter
        )
    }

    internal convenience init?() {
        let logsDir: URL
        if let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            logsDir = lib.appendingPathComponent("Logs")
        } else {
            logsDir = FileManager.default.temporaryDirectory
        }
        self.init(url: logsDir.appendingPathComponent("app.log"))
    }

    deinit {
        // A pending flush block may be the last owner of `self`, in which case
        // GCD runs this deinit on the serial queue's own worker thread. Calling
        // queue.sync here would trap (sync-onto-owned-queue) or deadlock, so we
        // capture what we need and enqueue the final write asynchronously instead.
        // Safe because the queue is serial+FIFO: any flush enqueued before deinit
        // held `self` strongly for its duration and has already drained, and this
        // block captures only the handle and the leftover bytes — never `self`.
        let handle = fileHandle
        let remaining = stateLock.withLock { () -> Data in
            scheduledFlush?.cancel()
            scheduledFlush = nil

            scheduledFlushIsImmediate = false
            var data = pending
            if droppedCount > 0 {
                data.append(droppedNoticeData(count: droppedCount))
                droppedCount = 0
            }
            pending = Data()
            pendingCount = 0
            return data
        }

        queue.async {
            if !remaining.isEmpty {
                try? handle.write(contentsOf: remaining)
            }
            try? handle.synchronize()
            try? handle.close()
        }
    }

    public func forceSave(_ message: String) {
        // Swift strings are always representable as UTF-8, so this cannot fail —
        // unlike `data(using:)`, which forces an optional for no reason here.
        let data = Data((message + "\n").utf8)
        let work = { [self] in
            // Drain anything buffered first so the crash log lands after the
            // entries that led up to it rather than jumping ahead of them.
            self.performFlush()
            try? self.fileHandle.write(contentsOf: data)
            self.currentFileSize += UInt64(data.count)
            try? self.fileHandle.synchronize()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    // MARK: - Buffering

    private func droppedNoticeData(count: Int) -> Data {
        let entry = LogEntry(
            level: .warning,
            message: "[Logger] dropped \(count) message\(count == 1 ? "" : "s") — write buffer full",
            fileName: "FileDestination.swift"
        )
        // Rendered with this destination's formatter so the notice is parseable
        // by whatever reads the rest of the file.
        return Data((formatter.format(entry) + "\n").utf8)
    }

    /// Appends `data` to the buffer and makes sure a flush is on its way.
    ///
    /// When the buffer is at capacity the entry is dropped and counted instead,
    /// and the count is reported in the log the next time the buffer drains.
    private func enqueue(_ data: Data) {
        // The scheduling decision has to be made under the same lock that
        // mutates the buffer, or a concurrent flush could empty `pending`
        // between deciding and dispatching.
        let scheduled: (work: DispatchWorkItem, immediately: Bool)? = stateLock.withLock {
            guard pendingCount < maxBufferedEntries else {
                // Drop the newest rather than blocking the caller. Logging must
                // never stall the app because the disk is slow.
                droppedCount += 1
                return nil
            }

            pending.append(data)
            pendingCount += 1

            let shouldWriteNow = pending.count >= flushByteThreshold

            if let existing = scheduledFlush {
                // A flush is already on its way. Only upgrade a delayed one to
                // immediate; re-dispatching an already-immediate flush on every
                // write would let a tight logging loop cancel it repeatedly and
                // starve the write entirely.
                guard shouldWriteNow, !scheduledFlushIsImmediate else { return nil }
                existing.cancel()
            }

            let item = DispatchWorkItem { [weak self] in
                // Weak on purpose: a strong capture would keep the destination
                // alive for the whole flush interval, delaying the deinit drain
                // past removeDestination(label:) or reset().
                self?.performFlush()
            }
            scheduledFlush = item
            scheduledFlushIsImmediate = shouldWriteNow
            return (item, shouldWriteNow)
        }

        guard let scheduled else { return }
        if scheduled.immediately {
            queue.async(execute: scheduled.work)
        } else {
            queue.asyncAfter(deadline: .now() + flushInterval, execute: scheduled.work)
        }
    }

    /// Writes the buffered bytes. Runs only on the serial queue.
    private func performFlush() {
        let chunk = stateLock.withLock { () -> Data in
            // Clearing `scheduledFlush` before the write means a `write()` racing
            // with it schedules a fresh flush, which the serial queue runs after
            // this one. Clearing it afterwards could lose that wakeup.
            scheduledFlush = nil

            scheduledFlushIsImmediate = false
            var data = pending
            if droppedCount > 0 {
                data.append(droppedNoticeData(count: droppedCount))
                droppedCount = 0
            }
            pending = Data()
            pendingCount = 0
            return data
        }

        guard !chunk.isEmpty else { return }

        try? fileHandle.write(contentsOf: chunk)
        currentFileSize += UInt64(chunk.count)
        rotateIfNeeded()
    }

    // MARK: - Rotation (runs exclusively on serial queue)

    private func rotateIfNeeded() {
        guard let config = rotationConfig else { return }
        let tooBig = currentFileSize >= config.maxFileSize
        let tooOld = config.maxFileAge.map { Date().timeIntervalSince(currentFileStart) >= $0 } ?? false
        guard tooBig || tooOld else { return }

        try? fileHandle.synchronize()
        try? fileHandle.close()

        let baseName = fileURL.lastPathComponent
        let dir = fileURL.deletingLastPathComponent()
        let timestamp = Self.rotationTimestamp()
        let uuid = UUID().uuidString.prefix(8).lowercased()
        let archiveName = "\(baseName).\(timestamp)_\(uuid)"
        let archiveURL = dir.appendingPathComponent(archiveName)

        do {
            try FileManager.default.moveItem(at: fileURL, to: archiveURL)
        } catch {
            reopenOrFail()
            return
        }

        if config.compressArchives {
            compressArchive(at: archiveURL)
        }

        pruneArchives(in: dir, baseName: baseName, max: config.maxArchivedFilesCount)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        if let newHandle = try? FileHandle(forWritingTo: fileURL) {
            self.fileHandle = newHandle
            self.currentFileSize = 0
            self.currentFileStart = Date()
        } else {
            reopenOrFail()
        }
    }

    /// Replaces `url` with a gzipped `url.gz`, leaving the original in place if
    /// compression fails — a bigger archive beats a lost one.
    private func compressArchive(at url: URL) {
        #if canImport(Compression)
        guard let raw = try? Data(contentsOf: url) else { return }
        guard let gzipped = Gzip.compress(raw) else { return }

        let compressedURL = URL(fileURLWithPath: url.path + ".gz")
        do {
            try gzipped.write(to: compressedURL)
            try FileManager.default.removeItem(at: url)
        } catch {
            try? FileManager.default.removeItem(at: compressedURL)
        }
        #endif
    }

    private static func creationDate(of url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.creationDate] as? Date) ?? Date()
    }

    private func reopenOrFail() {
        // Recreate the log file if it vanished (e.g. deleted externally, or a
        // rotation moveItem consumed it but the fresh createFile failed). Without
        // this, FileHandle(forWritingTo:) never creates a missing file and every
        // subsequent write is silently dropped for the process lifetime.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            self.fileHandle = handle
            // Reset the tracked size and age to the reopened file so rotateIfNeeded
            // stops re-entering on every write.
            self.currentFileSize = handle.seekToEndOfFile()
            self.currentFileStart = Self.creationDate(of: fileURL)
        } else {
            fputs("[Logger] File rotation failed — could not reopen \(fileURL.path)\n", stderr)
        }
    }

    private func pruneArchives(in dir: URL, baseName: String, max: Int) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys)) else { return }

        let prefix = baseName + "."
        let archives = contents
            .filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix(prefix) else { return false }
                let suffix = String(name.dropFirst(prefix.count))
                // Match: YYYYMMDDTHHMMSSZ_uuid8, optionally gzipped
                // (e.g. 20250515T121530Z_a1b2c3d4 or ….gz)
                return suffix.range(of: #"^\d{8}T\d{6}Z_[a-f0-9]{8}(\.gz)?$"#, options: .regularExpression) != nil
            }
            // Order newest-first. The name's timestamp has only 1-second resolution, so
            // a burst of rotations within the same second all share a timestamp and the
            // trailing UUID is random — sorting by name alone would keep arbitrary (often
            // older) archives and delete newer ones. Sort by the file's modification date
            // (nanosecond resolution), which is preserved by moveItem and increases
            // monotonically with rotation order; fall back to the name only to break exact
            // date ties deterministically.
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                if da != db { return da > db }
                return a.lastPathComponent > b.lastPathComponent
            }

        if archives.count > max {
            for old in archives[max...] {
                try? fm.removeItem(at: old)
            }
        }
    }

    private static func rotationTimestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
    }
}

extension FileDestination: LogDestination {
    public var isEnabled: Bool { true }

    public var minimumLevel: LogLevel? { _minimumLevel }

    /// Buffers the entry. Formatting happens on the calling thread; the write
    /// itself is coalesced with neighbouring entries onto the serial queue.
    public func write(_ entry: LogEntry) {
        enqueue(Data((formatter.format(entry) + "\n").utf8))
    }

    /// Drains the buffer and forces it to storage before returning.
    public func flush() {
        // Cancel any scheduled flush: we are about to do its work synchronously,
        // and leaving it queued would just wake up to an empty buffer.
        stateLock.withLock {
            scheduledFlush?.cancel()
            scheduledFlush = nil
        }

        let work = { [self] in
            self.performFlush()
            try? self.fileHandle.synchronize()
        }
        // Same reasoning as `forceSave`: `queue.sync` from the queue's own thread
        // would trap, so run inline when we are already on it.
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            work()
        } else {
            queue.sync(execute: work)
        }
    }
}

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

    /// The open log file, or `nil` when the destination is *degraded* — it has
    /// no usable handle and is retrying the open on a backoff. Entries keep
    /// cycling through the buffer while degraded and are counted as dropped.
    private var fileHandle: FileHandle?
    /// The raw descriptor behind `fileHandle`, tracked separately because
    /// `FileHandle.fileDescriptor` raises an uncatchable Objective-C exception
    /// once the handle is closed. `-1` means there is nothing to check.
    private var fileDescriptor: Int32 = -1
    private var currentFileSize: UInt64
    /// When the current log file came into being, for age-based rotation. Read
    /// from the file on open so it survives a process restart.
    private var currentFileStart: Date
    /// When the last open was attempted, so a persistently failing reopen backs
    /// off instead of hammering the filesystem on every flush.
    private var lastReopenAttempt = Date.distantPast
    /// Successful writes since the handle was last checked for liveness.
    private var flushesSinceHealthCheck = 0

    // MARK: - Buffer state (guarded by `stateLock`)

    private let stateLock = UnfairLock()
    private var pending = Data()
    private var pendingCount = 0
    private var droppedCount = 0
    private var scheduledFlush: DispatchWorkItem?
    /// Whether `scheduledFlush` was dispatched to run immediately rather than
    /// after `flushInterval`.
    private var scheduledFlushIsImmediate = false

    /// Buffering and recovery knobs, fixed at construction so no test or caller
    /// can race a mutation against the write path.
    internal struct Tunables {
        /// Entries buffered before new ones are dropped. Bounds the memory a
        /// burst of logging can consume when the disk cannot keep up.
        var maxBufferedEntries = 1_000
        /// How long a partial buffer waits before being written.
        var flushInterval: TimeInterval = 0.1
        /// Buffer size that triggers an immediate write rather than waiting out
        /// the interval. `nil` uses the default, clamped to the rotation
        /// threshold: buffering more than a whole log file's worth guarantees
        /// blowing past `maxFileSize` before rotation gets a chance to look, so
        /// the overshoot stays bounded by one batch.
        var flushByteThreshold: Int? = nil
        /// Minimum delay between attempts to reopen a lost file handle.
        var reopenBackoff: TimeInterval = 1.0
        /// Successful flushes between health checks of the open file handle.
        var healthCheckStride = 8
    }

    internal let maxBufferedEntries: Int
    internal let flushInterval: TimeInterval
    internal let flushByteThreshold: Int
    internal let reopenBackoff: TimeInterval
    internal let healthCheckStride: Int

    internal static let defaultFlushByteThreshold = 4_096

    public convenience init?(
        url: URL,
        label: String = "file",
        minimumLevel: LogLevel? = nil,
        rotation: FileRotationConfig? = nil,
        formatter: any LogFormatter = DefaultLogFormatter()
    ) {
        self.init(
            url: url,
            label: label,
            minimumLevel: minimumLevel,
            rotation: rotation,
            formatter: formatter,
            tunables: Tunables()
        )
    }

    /// Designated initializer. `tunables:` has no default value, so the public
    /// convenience above is never ambiguous with it.
    internal init?(
        url: URL,
        label: String = "file",
        minimumLevel: LogLevel? = nil,
        rotation: FileRotationConfig? = nil,
        formatter: any LogFormatter = DefaultLogFormatter(),
        tunables: Tunables
    ) {
        self.label = label
        self.fileURL = url
        self._minimumLevel = minimumLevel
        self.rotationConfig = rotation
        self.formatter = formatter

        self.maxBufferedEntries = tunables.maxBufferedEntries
        self.flushInterval = tunables.flushInterval
        if let explicit = tunables.flushByteThreshold {
            self.flushByteThreshold = explicit
        } else if let maxFileSize = rotation?.maxFileSize {
            self.flushByteThreshold = max(
                1,
                Int(min(maxFileSize, UInt64(Self.defaultFlushByteThreshold)))
            )
        } else {
            self.flushByteThreshold = Self.defaultFlushByteThreshold
        }
        self.reopenBackoff = tunables.reopenBackoff
        self.healthCheckStride = tunables.healthCheckStride

        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let opened = Self.openForAppending(at: url) else {
            return nil
        }

        self.fileHandle = opened.handle
        self.fileDescriptor = opened.descriptor
        // Size tracking only — with O_APPEND the kernel decides the write
        // position at each write, not this offset.
        self.currentFileSize = opened.handle.seekToEndOfFile()
        self.currentFileStart = Self.creationDate(of: url)
        self.queue = DispatchQueue(label: "com.logger.filewriter.\(label)")
        self.queue.setSpecific(key: Self.queueKey, value: true)
    }

    /// Opens `url` for appending, creating the file if needed. Every open in
    /// this class funnels through here.
    ///
    /// `O_APPEND` makes each write land atomically at the file's current end,
    /// no matter what other handle wrote in between. Without it, a second
    /// handle on the same file (a replaced destination draining late, two
    /// destinations sharing a URL, an external writer) would write from its
    /// own stale offset and silently overwrite bytes. A bonus after rotation:
    /// a stale predecessor's descriptor follows the moved inode, so its late
    /// drain appends to the archive instead of corrupting the fresh file.
    private static func openForAppending(at url: URL) -> (handle: FileHandle, descriptor: Int32)? {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), fd)
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
        let (chunk, dropped) = stateLock.withLock { () -> (Data, Int) in
            scheduledFlush?.cancel()
            scheduledFlush = nil

            scheduledFlushIsImmediate = false
            let data = pending
            let droppedNow = droppedCount
            droppedCount = 0
            pending = Data()
            pendingCount = 0
            return (data, droppedNow)
        }

        // The drop notice is rendered outside stateLock — the formatter is
        // user code (see performFlush).
        var remaining = chunk
        if dropped > 0 {
            remaining.append(droppedNoticeData(count: dropped))
        }

        queue.async {
            guard let handle else { return }
            if !remaining.isEmpty {
                // Last chance: the destination is going away, so a write
                // failure here has no counter left to report into. try? is
                // deliberate.
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
            // Crash path: there is no later flush to defer to, so a degraded
            // destination reopens immediately rather than waiting out the
            // backoff, and a failed write retries once through a fresh handle.
            if self.fileHandle == nil {
                self.attemptReopen()
            }
            if (try? self.fileHandle?.write(contentsOf: data)) != nil {
                self.currentFileSize += UInt64(data.count)
            } else {
                self.attemptReopen()
                if (try? self.fileHandle?.write(contentsOf: data)) != nil {
                    self.currentFileSize += UInt64(data.count)
                }
            }
            try? self.fileHandle?.synchronize()
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
        let (chunk, batchCount, dropped) = stateLock.withLock { () -> (Data, Int, Int) in
            // Clearing `scheduledFlush` before the write means a `write()` racing
            // with it schedules a fresh flush, which the serial queue runs after
            // this one. Clearing it afterwards could lose that wakeup.
            scheduledFlush = nil

            scheduledFlushIsImmediate = false
            let data = pending
            let count = pendingCount
            let droppedNow = droppedCount
            droppedCount = 0
            pending = Data()
            pendingCount = 0
            return (data, count, droppedNow)
        }

        guard !chunk.isEmpty || dropped > 0 else { return }

        // The drop notice is rendered outside stateLock: the formatter is user
        // code and may log back into this destination, and re-entering the
        // non-recursive stateLock would abort the process.
        var payload = chunk
        if dropped > 0 {
            payload.append(droppedNoticeData(count: dropped))
        }

        guard let handle = liveHandle() else {
            // Still degraded. The bytes are lost but counted, and the buffer
            // keeps cycling so the cap semantics hold rather than wedging.
            recordWriteFailure(batchCount + dropped)
            return
        }

        do {
            try handle.write(contentsOf: payload)
            currentFileSize += UInt64(payload.count)
            checkHandleHealthPeriodically()
            rotateIfNeeded()
        } catch {
            // The bytes are gone — count them as dropped so the next
            // successful flush reports the loss. Deliberately not re-prepended
            // to the buffer: a persistent outage (ENOSPC lasts seconds to
            // minutes) would rewrite the buffer head on every retry for the
            // same net loss.
            recordWriteFailure(batchCount + dropped)
            // A failed write usually means the descriptor died rather than the
            // disk filling for one batch. ENOSPC leaves the handle linked, so
            // this keeps it; a revoked descriptor gets replaced.
            invalidateHandleIfUnlinked()
        }
    }

    // MARK: - Handle liveness (runs exclusively on serial queue)

    /// The handle to write through, reopening a degraded destination once the
    /// backoff has elapsed. `nil` means still degraded.
    private func liveHandle() -> FileHandle? {
        if let handle = fileHandle { return handle }
        guard Date().timeIntervalSince(lastReopenAttempt) >= reopenBackoff else { return nil }
        attemptReopen()
        return fileHandle
    }

    /// Opens a fresh handle for `fileURL`, replacing whatever is there. On
    /// failure the destination goes degraded.
    private func attemptReopen() {
        lastReopenAttempt = Date()
        closeCurrentHandle()

        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let opened = Self.openForAppending(at: fileURL) else {
            // Reset the rotation counters even though nothing was opened. This
            // is what stops a failed reopen from churning: leaving
            // currentFileSize above maxFileSize makes every subsequent write
            // re-enter rotation, which archives the file again and again until
            // pruneArchives has eaten every real archive.
            currentFileSize = 0
            currentFileStart = Date()
            flushesSinceHealthCheck = 0
            fputs("[Logger] could not open \(fileURL.path) — file logging degraded\n", stderr)
            return
        }

        fileHandle = opened.handle
        fileDescriptor = opened.descriptor
        // A file this call just created starts empty and new, so it can never
        // be immediately archived by the rotation check.
        currentFileSize = opened.handle.seekToEndOfFile()
        currentFileStart = Self.creationDate(of: fileURL)
        flushesSinceHealthCheck = 0
    }

    private func closeCurrentHandle() {
        if let stale = fileHandle {
            try? stale.close()
        }
        fileHandle = nil
        fileDescriptor = -1
    }

    /// Periodically confirms the open descriptor still refers to a file anyone
    /// can read.
    ///
    /// Writes to an unlinked inode succeed forever and land nowhere — no error
    /// surfaces, so without this check an externally deleted log file means
    /// silent loss for the rest of the process's life. `st_nlink == 0` catches
    /// both a plain delete and the delete-then-recreate that a path-existence
    /// check would miss. One `fstat` every `healthCheckStride` writes is
    /// sub-microsecond and independent of whether rotation is configured.
    private func checkHandleHealthPeriodically() {
        flushesSinceHealthCheck += 1
        guard flushesSinceHealthCheck >= healthCheckStride else { return }
        flushesSinceHealthCheck = 0
        invalidateHandleIfUnlinked()
    }

    /// Drops and reopens the handle if its descriptor no longer refers to a
    /// linked file. Leaves a healthy handle untouched.
    private func invalidateHandleIfUnlinked() {
        guard fileDescriptor >= 0 else { return }
        var info = stat()
        if fstat(fileDescriptor, &info) == 0 && info.st_nlink > 0 { return }
        attemptReopen()
    }

    /// Folds a failed write's entries into the dropped count so the next
    /// successful flush reports them.
    private func recordWriteFailure(_ lost: Int) {
        guard lost > 0 else { return }
        stateLock.withLock { droppedCount += lost }
    }

    // MARK: - Test Support

    /// Closes the underlying handle so the next write fails, simulating a dead
    /// descriptor (revoked file, ENOSPC-style outage) without needing one.
    internal func closeHandleForTesting() {
        queue.sync {
            try? fileHandle?.close()
        }
    }

    /// Whether the destination currently holds a usable file handle.
    internal var isHealthyForTesting: Bool {
        queue.sync { fileHandle != nil }
    }

    // MARK: - Rotation (runs exclusively on serial queue)

    private func rotateIfNeeded() {
        // A degraded destination has nothing to archive, and its counters were
        // reset on the way down so neither trigger can fire spuriously.
        guard let handle = fileHandle, let config = rotationConfig else { return }
        let tooBig = currentFileSize >= config.maxFileSize
        let tooOld = config.maxFileAge.map { Date().timeIntervalSince(currentFileStart) >= $0 } ?? false
        guard tooBig || tooOld else { return }

        try? handle.synchronize()
        closeCurrentHandle()

        let baseName = fileURL.lastPathComponent
        let dir = fileURL.deletingLastPathComponent()
        let timestamp = Self.rotationTimestamp()
        let uuid = UUID().uuidString.prefix(8).lowercased()
        let archiveName = "\(baseName).\(timestamp)_\(uuid)"
        let archiveURL = dir.appendingPathComponent(archiveName)

        do {
            try FileManager.default.moveItem(at: fileURL, to: archiveURL)
        } catch {
            attemptReopen()
            return
        }

        if config.compressArchives {
            compressArchive(at: archiveURL)
        }

        pruneArchives(in: dir, baseName: baseName, max: config.maxArchivedFilesCount)

        attemptReopen()
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
            try? self.fileHandle?.synchronize()
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

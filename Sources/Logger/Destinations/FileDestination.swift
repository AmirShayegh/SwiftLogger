import Foundation

/// Configuration for automatic log file rotation.
public struct FileRotationConfig: Sendable {
    /// Maximum file size in bytes before rotation triggers. Default: 10 MB.
    /// This is a soft threshold — the file may exceed this by one entry.
    public var maxFileSize: UInt64
    /// Maximum number of archived log files to keep. 0 means no archives retained. Default: 5.
    public var maxArchivedFilesCount: Int

    public init(maxFileSize: UInt64 = 10_485_760, maxArchivedFilesCount: Int = 5) {
        self.maxFileSize = maxFileSize
        self.maxArchivedFilesCount = max(0, maxArchivedFilesCount)
    }
}

public final class FileDestination: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<Bool>()
    public let label: String
    private let queue: DispatchQueue
    private let fileURL: URL
    private var fileHandle: FileHandle
    private var currentFileSize: UInt64
    private let rotationConfig: FileRotationConfig?
    private let _minimumLevel: LogLevel?
    private let _levelLock = NSLock()

    public init?(
        url: URL,
        label: String = "file",
        minimumLevel: LogLevel? = nil,
        rotationConfig: FileRotationConfig? = nil
    ) {
        self.label = label
        self.fileURL = url
        self._minimumLevel = minimumLevel
        self.rotationConfig = rotationConfig

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
        self.queue = DispatchQueue(label: "com.logger.filewriter.\(label)")
        self.queue.setSpecific(key: Self.queueKey, value: true)
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
        queue.sync {
            try? fileHandle.synchronize()
            try? fileHandle.close()
        }
    }

    public func forceSave(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        let work = { [self] in
            try? self.fileHandle.write(contentsOf: data)
            try? self.fileHandle.synchronize()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    // MARK: - Rotation (runs exclusively on serial queue)

    private func rotateIfNeeded() {
        guard let config = rotationConfig else { return }
        guard currentFileSize >= config.maxFileSize else { return }

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

        pruneArchives(in: dir, baseName: baseName, max: config.maxArchivedFilesCount)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        if let newHandle = try? FileHandle(forWritingTo: fileURL) {
            self.fileHandle = newHandle
            self.currentFileSize = 0
        } else {
            reopenOrFail()
        }
    }

    private func reopenOrFail() {
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            self.fileHandle = handle
            self.currentFileSize = handle.seekToEndOfFile()
        } else {
            fputs("[Logger] File rotation failed — could not reopen \(fileURL.path)\n", stderr)
        }
    }

    private func pruneArchives(in dir: URL, baseName: String, max: Int) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }

        let prefix = baseName + "."
        let archives = contents
            .filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix(prefix) else { return false }
                let suffix = String(name.dropFirst(prefix.count))
                // Match: YYYYMMDDTHHMMSSZuuid8 pattern (e.g. 20250515T121530Z_a1b2c3d4)
                return suffix.range(of: #"^\d{8}T\d{6}Z_[a-f0-9]{8}$"#, options: .regularExpression) != nil
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

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

    public var minimumLevel: LogLevel? {
        _levelLock.lock()
        defer { _levelLock.unlock() }
        return _minimumLevel
    }

    public func write(_ entry: LogEntry) {
        let line = entry.format()
        guard let data = (line + "\n").data(using: .utf8) else { return }
        queue.async { [self] in
            try? self.fileHandle.write(contentsOf: data)
            self.currentFileSize += UInt64(data.count)
            self.rotateIfNeeded()
        }
    }

    public func flush() {
        queue.sync { [self] in
            try? self.fileHandle.synchronize()
        }
    }
}

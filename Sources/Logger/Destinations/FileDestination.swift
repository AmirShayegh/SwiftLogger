import Foundation

final class FileDestination: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<Bool>()
    let label = "file"
    private let queue: DispatchQueue
    private let fileURL: URL
    private let fileHandle: FileHandle

    init?() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent("app.log")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil) else {
                return nil
            }
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return nil
        }

        self.fileHandle = handle
        self.fileHandle.seekToEndOfFile()
        self.queue = DispatchQueue(label: "com.logger.filewriter")
        self.queue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit {
        queue.sync {
            try? fileHandle.synchronize()
            try? fileHandle.close()
        }
    }

    func forceSave(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        let work = { [fileHandle] in
            try? fileHandle.write(contentsOf: data)
            try? fileHandle.synchronize()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            work()
        } else {
            queue.sync(execute: work)
        }
    }
}

extension FileDestination: LogDestination {
    var isEnabled: Bool { true }

    func write(_ entry: LogEntry) {
        let line = entry.format()
        guard let data = (line + "\n").data(using: .utf8) else { return }
        queue.async { [fileHandle] in
            try? fileHandle.write(contentsOf: data)
        }
    }

    func flush() {
        queue.sync { [fileHandle] in
            try? fileHandle.synchronize()
        }
    }
}

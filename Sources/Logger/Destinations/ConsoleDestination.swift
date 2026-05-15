import Foundation

final class ConsoleDestination: LogDestination, @unchecked Sendable {
    let label = "console"
    private let lock = NSLock()
    private var _printEnabled = true
    private var _outputSink: ((String) -> Void)?
    private var _highlightedFiles: Set<String> = []

    var isEnabled: Bool {
        lock.lock()
        let hasSink = _outputSink != nil
        let printOn = _printEnabled
        lock.unlock()
        return printOn || hasSink
    }

    var printEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _printEnabled }
        set { lock.lock(); _printEnabled = newValue; lock.unlock() }
    }

    func write(_ entry: LogEntry) {
        var line = entry.format()

        lock.lock()
        let highlighted = _highlightedFiles.contains(entry.fileName)
        let sink = _outputSink
        let printOn = _printEnabled
        lock.unlock()

        if highlighted {
            line = ">>> \(line)"
        }

        if let sink = sink {
            sink(line)
        }
        if printOn {
            print(line)
        }
    }

    func setOutputSink(_ sink: ((String) -> Void)?) {
        lock.lock()
        _outputSink = sink
        lock.unlock()
    }

    func highlight(_ fileName: String) {
        lock.lock()
        _highlightedFiles.insert(fileName)
        lock.unlock()
    }

    func removeHighlight(_ fileName: String) {
        lock.lock()
        _highlightedFiles.remove(fileName)
        lock.unlock()
    }

    func resetHighlights() {
        lock.lock()
        _highlightedFiles.removeAll()
        lock.unlock()
    }
}

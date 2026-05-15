import Foundation

public final class ConsoleDestination: LogDestination, @unchecked Sendable {
    public let label = "console"
    private let lock = NSLock()
    private var _printEnabled = true
    private var _outputSink: ((String) -> Void)?
    private var _highlightedFiles: Set<String> = []
    private var _minimumLevel: LogLevel?

    public init(minimumLevel: LogLevel? = nil) {
        self._minimumLevel = minimumLevel
    }

    public var isEnabled: Bool {
        lock.lock()
        let hasSink = _outputSink != nil
        let printOn = _printEnabled
        lock.unlock()
        return printOn || hasSink
    }

    public var minimumLevel: LogLevel? {
        get { lock.lock(); defer { lock.unlock() }; return _minimumLevel }
        set { lock.lock(); _minimumLevel = newValue; lock.unlock() }
    }

    public var printEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _printEnabled }
        set { lock.lock(); _printEnabled = newValue; lock.unlock() }
    }

    public func write(_ entry: LogEntry) {
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

    internal func setOutputSink(_ sink: ((String) -> Void)?) {
        lock.lock()
        _outputSink = sink
        lock.unlock()
    }

    public func highlight(_ fileName: String) {
        lock.lock()
        _highlightedFiles.insert(fileName)
        lock.unlock()
    }

    public func removeHighlight(_ fileName: String) {
        lock.lock()
        _highlightedFiles.remove(fileName)
        lock.unlock()
    }

    internal func resetHighlights() {
        lock.lock()
        _highlightedFiles.removeAll()
        lock.unlock()
    }
}

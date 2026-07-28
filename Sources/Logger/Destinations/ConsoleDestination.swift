import Foundation

public final class ConsoleDestination: LogDestination, @unchecked Sendable {
    public let label = "console"
    private let lock = NSLock()
    private var _printEnabled = true
    private var _outputSink: ((String) -> Void)?
    private var _highlightedFiles: Set<String> = []
    private var _minimumLevel: LogLevel?

    /// Renders each entry. Immutable, so it needs no lock.
    public let formatter: any LogFormatter

    public init(minimumLevel: LogLevel? = nil, formatter: any LogFormatter = DefaultLogFormatter()) {
        self._minimumLevel = minimumLevel
        self.formatter = formatter
    }

    public var isEnabled: Bool {
        lock.lock()
        let hasSink = _outputSink != nil
        let printOn = _printEnabled
        lock.unlock()
        return printOn || hasSink
    }

    /// The level below which this destination discards entries.
    ///
    /// Every other destination takes its level at construction and keeps it
    /// immutable; this one is mutable purely for historical reasons, and a
    /// mid-flight change races the entries already in the pipeline. The setter
    /// is deprecated — construct a replacement and hand it to
    /// ``Logger/addDestination(_:)`` instead, which swaps atomically.
    ///
    /// Deprecation is scoped to the setter. Marking the whole property would
    /// warn on every read and on the `LogDestination` protocol witness.
    public var minimumLevel: LogLevel? {
        get { lock.lock(); defer { lock.unlock() }; return _minimumLevel }
        @available(*, deprecated, message: "Set the level at construction: addDestination(ConsoleDestination(minimumLevel:))")
        set { lock.lock(); _minimumLevel = newValue; lock.unlock() }
    }

    public var printEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _printEnabled }
        set { lock.lock(); _printEnabled = newValue; lock.unlock() }
    }

    public func write(_ entry: LogEntry) {
        var line = formatter.format(entry)

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

}

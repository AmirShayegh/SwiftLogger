import Logging
import Foundation

/// A `swift-log` `LogHandler` that forwards all messages through this library's
/// destination pipeline.
///
/// Bootstrap once at app launch:
///
///     import Logging
///     import Logger
///
///     LoggingSystem.bootstrap { label in
///         SwiftLogHandler(label: label)
///     }
///
/// After bootstrapping, any code using `swift-log`'s `Logger` will have its
/// messages routed through our Logger's destinations with full subsystem
/// filtering support — the swift-log `label` becomes our `subsystem`.
///
/// ## Filtering
///
/// By default `logLevel` is `.trace`, so the handler performs no swift-log-side
/// pre-filtering: every message reaches this library's pipeline and is filtered
/// solely by *its* configuration (global minimum, per-subsystem levels from
/// ``Logger/subsystem(_:level:)``, and per-file overrides). Passing a higher
/// `level` to ``init(label:logger:level:)`` restores swift-log-side
/// pre-filtering, dropping messages below that level before they ever reach the
/// pipeline — a performance escape hatch for very hot code paths, at the cost of
/// bypassing this library's own subsystem/file filtering for those messages.
///
/// ## Error bridging
///
/// If a message carries an attached `error:`, it is folded into the bridged
/// metadata under the key `"error"` as `String(describing:)` — but only when the
/// caller's own metadata does not already supply an `"error"` key, in which case
/// the explicit caller value wins.
public struct SwiftLogHandler: LogHandler {
    public var logLevel: Logging.Logger.Level = .trace
    public var metadata: Logging.Logger.Metadata = [:]
    private let label: String
    private let logger: Logger

    public init(label: String, logger: Logger = .shared, level: Logging.Logger.Level = .trace) {
        self.label = label
        self.logger = logger
        self.logLevel = level
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        let ourLevel = Self.mapLevel(event.level)

        // Bridging metadata means merging dictionaries, stringifying an
        // attached error, and converting every value — all of it wasted if the
        // pipeline is going to discard the message. Check the gate first, but
        // only when there is actually context to build: with no metadata and no
        // error there is nothing to save, and logMessage's own gate is cheaper
        // than a second resolution.
        let hasContextToBuild = !metadata.isEmpty || event.metadata != nil || event.error != nil
        if hasContextToBuild,
           !logger.wouldLog(level: ourLevel, subsystem: label, file: event.file) {
            return
        }

        var merged = self.metadata
        if let extra = event.metadata {
            merged.merge(extra, uniquingKeysWith: { _, new in new })
        }
        // Fold any attached error into the bridged metadata. Explicit caller
        // metadata wins, so only add it when no "error" key is already present.
        if let error = event.error, merged["error"] == nil {
            merged["error"] = .string(String(describing: error))
        }
        let ourMetadata: LogMetadata? = merged.isEmpty ? nil : merged.reduce(into: LogMetadata()) { result, pair in
            result[pair.key] = Self.mapMetadataValue(pair.value)
        }

        logger.logMessage(
            { event.message.description },
            level: ourLevel,
            subsystem: label,
            metadata: ourMetadata,
            correlation: nil,
            file: event.file,
            function: event.function,
            line: Int(event.line)
        )
    }

    // MARK: - Level Mapping

    static func mapLevel(_ level: Logging.Logger.Level) -> LogLevel {
        switch level {
        case .trace:    return .verbose
        case .debug:    return .debug
        case .info:     return .info
        case .notice:   return .info
        case .warning:  return .warning
        case .error:    return .error
        // `.todo` outranks `.error` in this library, but it renders as " TODO" —
        // misleading for a crash-severity swift-log message. `.error` is the
        // closest honest match.
        case .critical: return .error
        }
    }

    // MARK: - Metadata Mapping

    static func mapMetadataValue(_ value: Logging.Logger.MetadataValue) -> LogValue {
        switch value {
        case .string(let s):
            return .string(s)
        case .stringConvertible(let s):
            return .string(s.description)
        case .dictionary(let dict):
            let pairs = dict.map { "\($0.key)=\(mapMetadataValue($0.value))" }.sorted().joined(separator: ", ")
            return .string("{\(pairs)}")
        case .array(let arr):
            // Arrays are ordered data — preserve element order. (Dictionaries above
            // are unordered, so sorting there is what makes output deterministic.)
            let items = arr.map { "\(mapMetadataValue($0))" }.joined(separator: ", ")
            return .string("[\(items)]")
        }
    }
}

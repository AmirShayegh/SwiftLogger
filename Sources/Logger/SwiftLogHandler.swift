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

        // Build the bridged metadata lazily so the merge/fold/map cost is paid
        // only after `logMessage` clears BOTH the level and active-destination
        // gates. swift-log has already applied its own `logLevel` gate before
        // calling us, but that is independent of this library's per-subsystem/
        // per-file/global thresholds, so an eager build here would still be
        // wasted whenever our pipeline suppresses the message.
        logger.logMessage(
            { event.message.description },
            level: ourLevel,
            subsystem: label,
            metadata: {
                var merged = self.metadata
                if let extra = event.metadata {
                    merged.merge(extra, uniquingKeysWith: { _, new in new })
                }
                // Fold any attached error into the bridged metadata. Explicit caller
                // metadata wins, so only add it when no "error" key is already present.
                if let error = event.error, merged["error"] == nil {
                    merged["error"] = .string(String(describing: error))
                }
                return merged.isEmpty ? nil : merged.reduce(into: LogMetadata()) { result, pair in
                    result[pair.key] = Self.mapMetadataValue(pair.value)
                }
            },
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
        case .critical: return .todo
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
            let items = arr.map { "\(mapMetadataValue($0))" }.sorted().joined(separator: ", ")
            return .string("[\(items)]")
        }
    }
}

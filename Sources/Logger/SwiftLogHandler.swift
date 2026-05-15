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
public struct SwiftLogHandler: LogHandler {
    public var logLevel: Logging.Logger.Level = .info
    public var metadata: Logging.Logger.Metadata = [:]
    private let label: String
    private let logger: Logger

    public init(label: String, logger: Logger = .shared) {
        self.label = label
        self.logger = logger
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        let ourLevel = Self.mapLevel(event.level)

        var merged = self.metadata
        if let extra = event.metadata {
            merged.merge(extra, uniquingKeysWith: { _, new in new })
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

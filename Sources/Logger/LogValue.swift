import Foundation

/// A type-safe, `Sendable` value for structured log metadata.
///
/// Conforms to `ExpressibleByStringLiteral`, `ExpressibleByIntegerLiteral`,
/// `ExpressibleByFloatLiteral`, and `ExpressibleByBooleanLiteral` so metadata
/// dictionaries read naturally at the call site:
///
///     Log("frame decoded", metadata: ["pts": 42, "keyframe": true])
public enum LogValue: Sendable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public var description: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return String(v)
        }
    }
}

extension LogValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension LogValue: ExpressibleByStringInterpolation {
    public init(stringInterpolation: DefaultStringInterpolation) {
        self = .string(String(stringInterpolation: stringInterpolation))
    }
}

extension LogValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension LogValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension LogValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Key-value pairs attached to a log message for structured context.
public typealias LogMetadata = [String: LogValue]

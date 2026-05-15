import Foundation

/// Severity levels for log messages, ordered from least to most severe.
///
/// The logger filters messages below the configured minimum level.
/// Levels in ascending order: `verbose` < `debug` < `info` < `warning` < `error` < `todo`.
public enum LogLevel: String, Comparable, Sendable, CaseIterable {
    case verbose = "VERBOSE"
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    /// Marks incomplete work. Highest severity so it always surfaces.
    case todo = "TODO"

    private var sortOrder: Int {
        switch self {
        case .verbose: return 0
        case .debug:   return 1
        case .info:    return 2
        case .warning: return 3
        case .error:   return 4
        case .todo:    return 5
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    /// Fixed-width 5-character tag for aligned console output.
    var tag: String {
        switch self {
        case .verbose: return "TRACE"
        case .debug:   return "DEBUG"
        case .info:    return " INFO"
        case .warning: return " WARN"
        case .error:   return "ERROR"
        case .todo:    return " TODO"
        }
    }
}

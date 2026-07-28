import Foundation

/// An immutable snapshot of everything the logging hot path needs to read.
///
/// Configuration changes are rare; log calls are not. Rather than lock each
/// field on every message, ``Logger`` keeps one of these and swaps in a wholly
/// new instance when configuration changes. Readers take a single reference
/// load and then work against a value that cannot change underneath them.
internal final class LoggerConfiguration: Sendable {
    let minimumLogLevel: LogLevel
    let fileLogLevels: [String: LogLevel]
    let subsystemLevels: [String: LogLevel]
    let destinations: [any LogDestination]

    /// `true` when no per-file override exists, letting the hot path skip
    /// deriving a file name from `#fileID` entirely.
    let hasFileLevelOverrides: Bool

    init(
        minimumLogLevel: LogLevel,
        fileLogLevels: [String: LogLevel],
        subsystemLevels: [String: LogLevel],
        destinations: [any LogDestination]
    ) {
        self.minimumLogLevel = minimumLogLevel
        self.fileLogLevels = fileLogLevels
        self.subsystemLevels = subsystemLevels
        self.destinations = destinations
        self.hasFileLevelOverrides = !fileLogLevels.isEmpty
    }

    /// The starting configuration: default level, no overrides, console only.
    static func makeDefault() -> LoggerConfiguration {
        LoggerConfiguration(
            minimumLogLevel: .debug,
            fileLogLevels: [:],
            subsystemLevels: [:],
            destinations: [ConsoleDestination()]
        )
    }

    /// Returns a copy with the given fields replaced.
    func with(
        minimumLogLevel: LogLevel? = nil,
        fileLogLevels: [String: LogLevel]? = nil,
        subsystemLevels: [String: LogLevel]? = nil,
        destinations: [any LogDestination]? = nil
    ) -> LoggerConfiguration {
        LoggerConfiguration(
            minimumLogLevel: minimumLogLevel ?? self.minimumLogLevel,
            fileLogLevels: fileLogLevels ?? self.fileLogLevels,
            subsystemLevels: subsystemLevels ?? self.subsystemLevels,
            destinations: destinations ?? self.destinations
        )
    }

    // MARK: - Level Resolution

    /// Resolves a subsystem's level, walking up the dot-separated hierarchy
    /// (`"a.b.c"` -> `"a.b"` -> `"a"`) until a configured level is found.
    func resolveSubsystemLevel(_ name: String) -> LogLevel? {
        // Fast path: with no subsystem levels configured there is nothing to walk.
        if subsystemLevels.isEmpty { return nil }

        var current = name
        while true {
            if let level = subsystemLevels[current] {
                return level
            }
            guard let dotIndex = current.lastIndex(of: ".") else {
                return nil
            }
            current = String(current[current.startIndex..<dotIndex])
        }
    }

    // MARK: - Destination Lookup

    func destination(labelled label: String) -> (any LogDestination)? {
        destinations.first(where: { $0.label == label })
    }
}

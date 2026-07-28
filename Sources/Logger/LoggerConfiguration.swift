import Foundation

/// An immutable snapshot of everything the logging hot path needs to read.
///
/// Configuration changes are rare; log calls are not. Rather than lock each
/// field on every message, ``Logger`` keeps one of these and swaps in a wholly
/// new instance when configuration changes. Readers take a single reference
/// load and then work against a value that cannot change underneath them.
/// `@unchecked Sendable` rather than `Sendable`: every stored property is a
/// `let` except ``subsystemLevelMemo``, which is mutable but touched only under
/// ``memoLock``.
internal final class LoggerConfiguration: @unchecked Sendable {
    let minimumLogLevel: LogLevel
    let fileLogLevels: [String: LogLevel]
    let subsystemLevels: [String: LogLevel]
    let destinations: [any LogDestination]

    /// `true` when no per-file override exists, letting the hot path skip
    /// deriving a file name from `#fileID` entirely.
    let hasFileLevelOverrides: Bool

    /// Memoised results of ``resolveSubsystemLevel(_:)``.
    ///
    /// The outer optional is dictionary lookup ("have we resolved this name?");
    /// the inner one is the answer, where `nil` means "walked the hierarchy and
    /// found nothing" — a result worth caching, since an unconfigured subsystem
    /// pays the full walk every time otherwise.
    ///
    /// It can never go stale: configuration changes build a whole new
    /// `LoggerConfiguration`, discarding this along with it.
    private var subsystemLevelMemo: [String: LogLevel?] = [:]
    private let memoLock = UnfairLock()

    /// Ceiling on memo entries. Subsystem names come from call sites, so the
    /// set is normally tiny and fixed; the cap is a backstop against a caller
    /// that interpolates unbounded values (a request ID, say) into one.
    private static let memoCapacity = 1_024

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
    ///
    /// The walk allocates a substring per level and hashes it, so a deep name
    /// costs several dictionary lookups on every single message. Results are
    /// memoised per configuration snapshot; the same handful of subsystem
    /// strings recur for the life of a process.
    func resolveSubsystemLevel(_ name: String) -> LogLevel? {
        // Fast path: with no subsystem levels configured there is nothing to
        // walk, and nothing worth taking a lock for.
        if subsystemLevels.isEmpty { return nil }

        if let memoised = memoLock.withLock({ subsystemLevelMemo[name] }) {
            return memoised
        }

        let resolved = walkSubsystemHierarchy(name)

        memoLock.withLock {
            // Stop inserting at the cap rather than evicting: an eviction
            // policy would need its own bookkeeping on the hot path, and past
            // this point the memo is already holding every name that recurs.
            if subsystemLevelMemo.count < Self.memoCapacity {
                subsystemLevelMemo[name] = resolved
            }
        }
        return resolved
    }

    private func walkSubsystemHierarchy(_ name: String) -> LogLevel? {
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

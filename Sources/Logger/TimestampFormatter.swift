import Foundation

/// Renders `"HH:mm:ss.SSS"` timestamps for log output.
///
/// `DateFormatter` costs on the order of a microsecond per call — the single
/// most expensive step in emitting a log line — and keeping one per thread (the
/// usual way to dodge its thread-unsafety) leaks an instance for every thread
/// that ever logs. Since the format is fixed, the whole job is integer division
/// on a seconds-since-epoch value plus a UTC offset lookup.
internal enum TimestampFormatter {

    /// A time zone's UTC offset, valid for a bounded window around the instant
    /// it was computed.
    private struct OffsetCache {
        let identifier: String
        let offset: Int
        let validFrom: TimeInterval
        let validUntil: TimeInterval
    }

    private static let cacheLock = UnfairLock()
    private static var cache: OffsetCache?

    /// Milliseconds in a day, the modulus for reducing an epoch instant to a
    /// time of day.
    private static let millisecondsPerDay: Int = 86_400_000

    /// Formats `date` as `"HH:mm:ss.SSS"` in `timeZone`.
    ///
    /// Sub-millisecond values round half to even, which is what the
    /// `DateFormatter` this replaced does — `.9995` renders as the next whole
    /// second, `.0005` as `.000`. Rounding happens before the reduction to a time
    /// of day, so a value that rounds up across a second, minute, or day
    /// boundary carries correctly.
    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let epochSeconds = date.timeIntervalSince1970
        let offset = utcOffset(for: date, epochSeconds: epochSeconds, in: timeZone)

        let localMilliseconds = Int64(((epochSeconds + Double(offset)) * 1000).rounded(.toNearestOrEven))
        var millisecondOfDay = Int(localMilliseconds % Int64(millisecondsPerDay))
        if millisecondOfDay < 0 { millisecondOfDay += millisecondsPerDay }

        let milliseconds = millisecondOfDay % 1000
        let secondOfDay = millisecondOfDay / 1000
        let hours = secondOfDay / 3600
        let minutes = (secondOfDay % 3600) / 60
        let seconds = secondOfDay % 60

        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 12) { buffer in
            let zero = UInt8(ascii: "0")
            buffer[0] = zero + UInt8(hours / 10)
            buffer[1] = zero + UInt8(hours % 10)
            buffer[2] = UInt8(ascii: ":")
            buffer[3] = zero + UInt8(minutes / 10)
            buffer[4] = zero + UInt8(minutes % 10)
            buffer[5] = UInt8(ascii: ":")
            buffer[6] = zero + UInt8(seconds / 10)
            buffer[7] = zero + UInt8(seconds % 10)
            buffer[8] = UInt8(ascii: ".")
            buffer[9] = zero + UInt8(milliseconds / 100)
            buffer[10] = zero + UInt8((milliseconds / 10) % 10)
            buffer[11] = zero + UInt8(milliseconds % 10)
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    /// Returns `timeZone`'s offset from UTC at `date`, caching it for a bounded
    /// window.
    ///
    /// `secondsFromGMT(for:)` is itself not cheap, and consecutive log lines are
    /// almost always within the same offset window. The cached value expires at
    /// the zone's next DST transition — so a fall-back or spring-forward is
    /// picked up exactly — or after 15 minutes, whichever comes first. The
    /// 15-minute ceiling bounds how long a *system* time zone change (the user
    /// travelling, say) can go unnoticed, which is a tolerable skew for log
    /// timestamps in exchange for keeping the common path to one integer
    /// comparison.
    private static func utcOffset(
        for date: Date,
        epochSeconds: TimeInterval,
        in timeZone: TimeZone
    ) -> Int {
        cacheLock.withLock {
            if let cache,
               cache.identifier == timeZone.identifier,
               epochSeconds >= cache.validFrom,
               epochSeconds < cache.validUntil {
                return cache.offset
            }

            let offset = timeZone.secondsFromGMT(for: date)
            let nextTransition = timeZone.nextDaylightSavingTimeTransition(after: date)?
                .timeIntervalSince1970 ?? .greatestFiniteMagnitude
            cache = OffsetCache(
                identifier: timeZone.identifier,
                offset: offset,
                // Backdated timestamps (a caller supplying an older Date) must
                // miss the cache rather than reuse a later window's offset.
                validFrom: epochSeconds,
                validUntil: min(nextTransition, epochSeconds + 900)
            )
            return offset
        }
    }

    /// Test hook: drops the cached offset so a test can format instants in an
    /// arbitrary order without a stale window bleeding across cases.
    internal static func resetCacheForTesting() {
        cacheLock.withLock { cache = nil }
    }
}

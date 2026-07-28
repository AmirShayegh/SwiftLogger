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
            ASCIIDigits.write2(hours, to: buffer, at: 0)
            buffer[2] = UInt8(ascii: ":")
            ASCIIDigits.write2(minutes, to: buffer, at: 3)
            buffer[5] = UInt8(ascii: ":")
            ASCIIDigits.write2(seconds, to: buffer, at: 6)
            buffer[8] = UInt8(ascii: ".")
            ASCIIDigits.write3(milliseconds, to: buffer, at: 9)
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    // MARK: - ISO 8601

    /// Lowest instant the integer fast path handles: 1582-10-15T00:00:00Z, the
    /// first day of the Gregorian calendar. `ISO8601DateFormatter` switches to
    /// the Julian calendar before this, and reproducing that is not worth it
    /// for a log timestamp.
    private static let iso8601LowerBoundMilliseconds: Int64 = -12_219_292_800_000
    /// One past the highest instant the fast path handles: 10000-01-01T00:00:00Z,
    /// where the year stops fitting in four digits.
    private static let iso8601UpperBoundMilliseconds: Int64 = 253_402_300_800_000

    /// Formats `date` as `"yyyy-MM-ddTHH:mm:ss.SSSZ"` in UTC.
    ///
    /// `ISO8601DateFormatter` costs roughly a microsecond per call and, because
    /// it is not thread-safe, has to sit behind a lock — which turns every
    /// JSON-formatted log line on every thread into a queue at one mutex. The
    /// arithmetic here is exact and needs no shared state.
    ///
    /// Milliseconds round half to even, matching `ISO8601DateFormatter`
    /// (verified empirically). Rounding happens before the split into date and
    /// time, so a value rounding up across a second, day, month, or year
    /// boundary carries correctly. Instants outside the fast path's range fall
    /// back to the formatter so behaviour stays identical there too.
    static func iso8601String(from date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.toNearestOrEven))
        guard milliseconds >= iso8601LowerBoundMilliseconds,
              milliseconds < iso8601UpperBoundMilliseconds else {
            return iso8601Lock.withLock { iso8601Formatter.string(from: date) }
        }

        // Floor division, so pre-1970 instants land on the right day rather
        // than truncating toward zero into the next one.
        let millisecondsPerDayValue = Int64(millisecondsPerDay)
        var days = milliseconds / millisecondsPerDayValue
        var millisecondOfDay = milliseconds % millisecondsPerDayValue
        if millisecondOfDay < 0 {
            millisecondOfDay += millisecondsPerDayValue
            days -= 1
        }

        let (year, month, day) = civilFromDays(days)

        let millis = Int(millisecondOfDay % 1000)
        let secondOfDay = Int(millisecondOfDay / 1000)
        let hours = secondOfDay / 3600
        let minutes = (secondOfDay % 3600) / 60
        let seconds = secondOfDay % 60

        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 24) { buffer in
            ASCIIDigits.write4(year, to: buffer, at: 0)
            buffer[4] = UInt8(ascii: "-")
            ASCIIDigits.write2(month, to: buffer, at: 5)
            buffer[7] = UInt8(ascii: "-")
            ASCIIDigits.write2(day, to: buffer, at: 8)
            buffer[10] = UInt8(ascii: "T")
            ASCIIDigits.write2(hours, to: buffer, at: 11)
            buffer[13] = UInt8(ascii: ":")
            ASCIIDigits.write2(minutes, to: buffer, at: 14)
            buffer[16] = UInt8(ascii: ":")
            ASCIIDigits.write2(seconds, to: buffer, at: 17)
            buffer[19] = UInt8(ascii: ".")
            ASCIIDigits.write3(millis, to: buffer, at: 20)
            buffer[23] = UInt8(ascii: "Z")
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    /// Converts a count of days since 1970-01-01 into a proleptic Gregorian
    /// year/month/day.
    ///
    /// Howard Hinnant's `civil_from_days`: shift the epoch to 0000-03-01 so
    /// February — the only month whose length varies — falls at the end of the
    /// year, which removes every leap-year special case from the arithmetic.
    private static func civilFromDays(_ days: Int64) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097                                   // 0...146096
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)  // 0...365, from Mar 1
        let monthPrime = (5 * dayOfYear + 2) / 153                               // 0...11, 0 == March
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1                     // 1...31
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return (Int(month <= 2 ? year + 1 : year), Int(month), Int(day))
    }

    // One shared formatter behind a lock, kept only as the cold fallback for
    // instants outside the fast path's range. Allocating an
    // ISO8601DateFormatter per call would cost more than everything else
    // combined, and the class is not documented as thread-safe.
    private static let iso8601Lock = UnfairLock()
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

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

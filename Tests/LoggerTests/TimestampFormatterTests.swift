import Testing
import Foundation
@testable import Logger

extension AllLoggerTests {

    /// `TimestampFormatter` replaces `DateFormatter` with integer arithmetic, so
    /// every case here pins it against a reference `DateFormatter` configured
    /// with the same fixed zone.
    struct TimestampFormatterTests {

        init() { TimestampFormatter.resetCacheForTesting() }

        private static let zone = TimeZone(identifier: "America/Vancouver")!

        private func reference(_ zone: TimeZone) -> DateFormatter {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            f.timeZone = zone
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }

        /// Compares against the reference formatter, resetting the offset cache
        /// first so instants can be checked in any order.
        private func expectMatchesReference(
            _ date: Date,
            in zone: TimeZone = zone,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            TimestampFormatter.resetCacheForTesting()
            let expected = reference(zone).string(from: date)
            let actual = TimestampFormatter.string(from: date, timeZone: zone)
            #expect(actual == expected, "\(date)", sourceLocation: sourceLocation)
        }

        @Test func matchesDateFormatterAcrossASweepOfInstants() {
            // A day's worth of instants at an interval that is coprime with the
            // second, so it lands on a wide spread of sub-second values.
            let start = Date(timeIntervalSince1970: 1_752_000_000)
            for step in 0..<500 {
                expectMatchesReference(start.addingTimeInterval(Double(step) * 173.077))
            }
        }

        /// Finds every UTC-offset change in `range` by stepping hourly and
        /// bisecting to the second. `nextDaylightSavingTimeTransition(after:)`
        /// is not used — on some tzdata versions it stops yielding transitions
        /// after the first one, which would silently skip the fall-back case.
        private func offsetTransitions(
            in zone: TimeZone,
            from start: TimeInterval,
            to end: TimeInterval
        ) -> [Date] {
            var transitions: [Date] = []
            let step: TimeInterval = 3600
            var previous = start
            var previousOffset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: previous))

            var cursor = start + step
            while cursor <= end {
                let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: cursor))
                if offset != previousOffset {
                    // Bisect (lo, hi] down to a one-second window.
                    var lo = previous, hi = cursor
                    while hi - lo > 1 {
                        let mid = (lo + hi) / 2
                        if zone.secondsFromGMT(for: Date(timeIntervalSince1970: mid)) == previousOffset {
                            lo = mid
                        } else {
                            hi = mid
                        }
                    }
                    transitions.append(Date(timeIntervalSince1970: hi.rounded()))
                    previousOffset = offset
                }
                previous = cursor
                cursor += step
            }
            return transitions
        }

        @Test func matchesAroundEveryDSTTransitionInAYear() throws {
            // Several zones, because which ones still observe DST shifts with
            // tzdata releases — 2026b puts North America on permanent DST, so
            // Vancouver springs forward and never falls back. Europe and the
            // southern hemisphere still supply both directions.
            let zones = ["America/Vancouver", "Europe/London", "Australia/Sydney"]
                .compactMap(TimeZone.init(identifier:))

            var gained = false   // saw an offset increase (spring forward)
            var lost = false     // saw an offset decrease (fall back)

            for zone in zones {
                // 2026-01-01 .. 2027-01-01 UTC.
                let transitions = offsetTransitions(in: zone, from: 1_767_225_600, to: 1_798_761_600)

                for transition in transitions {
                    let before = zone.secondsFromGMT(for: transition.addingTimeInterval(-1))
                    let after = zone.secondsFromGMT(for: transition)
                    if after > before { gained = true } else if after < before { lost = true }

                    for delta in [-3600.0, -60.0, -1.0, -0.001, 0.0, 0.001, 1.0, 60.0, 3600.0] {
                        expectMatchesReference(transition.addingTimeInterval(delta), in: zone)
                    }
                }
            }

            // Guards against a vacuous pass if a future tzdata drops DST entirely
            // from the zones above.
            #expect(gained, "no spring-forward transition found to test against")
            #expect(lost, "no fall-back transition found to test against")
        }

        @Test func matchesAtMidnightBoundaries() {
            var components = DateComponents()
            components.year = 2026
            components.month = 6
            components.day = 15
            components.hour = 0
            components.minute = 0
            components.second = 0

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = Self.zone
            let midnight = calendar.date(from: components)!

            for delta in [-0.001, 0.0, 0.001, -1.0, 1.0] {
                expectMatchesReference(midnight.addingTimeInterval(delta))
            }
        }

        @Test func roundsSubMillisecondsHalfToEvenLikeDateFormatter() {
            let utc = TimeZone(identifier: "UTC")!

            // Half-way values round to even: .9995 -> next whole second (…1.000),
            // .0005 -> .000. Anything else rounds to nearest.
            #expect(TimestampFormatter.string(from: Date(timeIntervalSince1970: 0.9995), timeZone: utc)
                == "00:00:01.000")
            #expect(TimestampFormatter.string(from: Date(timeIntervalSince1970: 0.0005), timeZone: utc)
                == "00:00:00.000")
            #expect(TimestampFormatter.string(from: Date(timeIntervalSince1970: 0.9994), timeZone: utc)
                == "00:00:00.999")

            for t in [0.9995, 0.0005, 0.9994, 0.5, 0.999] {
                expectMatchesReference(Date(timeIntervalSince1970: t), in: utc)
            }
        }

        @Test func roundingUpCarriesAcrossADayBoundary() {
            // 23:59:59.9995 rounds up to the next day's 00:00:00.000 rather than
            // producing an out-of-range hour.
            let utc = TimeZone(identifier: "UTC")!
            let justBeforeMidnight = Date(timeIntervalSince1970: 86_400 - 0.0005)
            #expect(TimestampFormatter.string(from: justBeforeMidnight, timeZone: utc) == "00:00:00.000")
            expectMatchesReference(justBeforeMidnight, in: utc)
        }

        @Test func handlesPre1970Instants() {
            // Negative epoch intervals must not produce a negative time of day.
            let beforeEpoch = Date(timeIntervalSince1970: -86_400 * 400 - 12_345.678)
            expectMatchesReference(beforeEpoch, in: TimeZone(identifier: "UTC")!)
        }

        @Test func handlesZonesWithFractionalHourOffsets() {
            // Kathmandu is UTC+05:45 — catches an implementation that assumes
            // whole-hour offsets.
            expectMatchesReference(
                Date(timeIntervalSince1970: 1_752_003_661.234),
                in: TimeZone(identifier: "Asia/Kathmandu")!
            )
        }

        @Test func outputIsAlwaysTwelveCharactersWide() {
            let base = Date(timeIntervalSince1970: 1_752_000_000)
            for step in 0..<200 {
                let s = TimestampFormatter.string(
                    from: base.addingTimeInterval(Double(step) * 61.001),
                    timeZone: Self.zone
                )
                #expect(s.count == 12)
            }
        }

        @Test func cachedOffsetDoesNotLeakAcrossTimeZones() {
            let instant = Date(timeIntervalSince1970: 1_752_003_661.234)
            // Format in one zone, then immediately in another without resetting:
            // the cache is keyed by identifier, so the second must not reuse the
            // first zone's offset.
            _ = TimestampFormatter.string(from: instant, timeZone: TimeZone(identifier: "UTC")!)
            let tokyo = TimestampFormatter.string(from: instant, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
            #expect(tokyo == reference(TimeZone(identifier: "Asia/Tokyo")!).string(from: instant))
        }

        @Test func cachedOffsetStillCorrectWhenTimeMovesForwardWithinWindow() {
            // Consecutive instants inside the 15-minute cache window take the
            // cached branch; they must still render correctly.
            let base = Date(timeIntervalSince1970: 1_752_000_000)
            TimestampFormatter.resetCacheForTesting()
            let ref = reference(Self.zone)
            for step in 0..<60 {
                let d = base.addingTimeInterval(Double(step) * 10)
                #expect(TimestampFormatter.string(from: d, timeZone: Self.zone) == ref.string(from: d))
            }
        }
    }
}

import Testing
import Foundation
@testable import Logger

extension AllLoggerTests {

    /// `TimestampFormatter.iso8601String(from:)` replaces `ISO8601DateFormatter`
    /// with integer arithmetic. `ISO8601DateFormatter` itself is the oracle:
    /// every one of these compares the two directly rather than trusting a
    /// hand-computed expectation.
    struct ISO8601TimestampTests {

        /// The formatter being replaced, configured exactly as it was.
        private static let reference: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter
        }()

        private func expectMatchesReference(_ date: Date, _ label: String = "") {
            let mine = TimestampFormatter.iso8601String(from: date)
            let theirs = Self.reference.string(from: date)
            #expect(mine == theirs, "\(label) at \(date.timeIntervalSince1970)")
        }

        // MARK: - Broad sweeps

        @Test func matchesReferenceAcrossSixCenturies() {
            // Every ~37 days from 1970 to ~2590, so the sweep crosses every
            // month length, every leap rule, and hundreds of year boundaries.
            var t: TimeInterval = 0
            while t < 19_600_000_000 {
                expectMatchesReference(Date(timeIntervalSince1970: t), "sweep")
                t += 3_200_000
            }
        }

        @Test func matchesReferenceAcrossADayAtSecondResolution() {
            // 2024-02-29 (a leap day) minute by minute, plus odd sub-second
            // offsets so the millisecond field is exercised too.
            let dayStart: TimeInterval = 1_709_164_800  // 2024-02-29T00:00:00Z
            for minute in 0..<1_440 {
                let t = dayStart + Double(minute) * 60 + Double(minute % 1_000) / 1_000
                expectMatchesReference(Date(timeIntervalSince1970: t), "minute \(minute)")
            }
        }

        @Test func matchesReferenceForPseudoRandomInstants() {
            // A fixed LCG, so a failure is reproducible rather than a
            // once-in-a-blue-moon CI mystery.
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            for _ in 0..<5_000 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                // Roughly 1700-01-01 through 2300-01-01.
                let seconds = Double(state % 18_900_000_000) - 8_500_000_000
                let millis = Double(state % 1_000) / 1_000
                expectMatchesReference(Date(timeIntervalSince1970: seconds + millis), "random")
            }
        }

        // MARK: - Rounding

        @Test func millisecondsRoundHalfToEven() {
            // The reference rounds half to even rather than truncating, so
            // these pin the exact behaviour rather than an approximation.
            expectMatchesReference(Date(timeIntervalSince1970: 0.9995), "0.9995")
            expectMatchesReference(Date(timeIntervalSince1970: 0.0005), "0.0005")
            expectMatchesReference(Date(timeIntervalSince1970: 0.9996), "0.9996")
            expectMatchesReference(Date(timeIntervalSince1970: 0.0015), "0.0015")
            expectMatchesReference(Date(timeIntervalSince1970: 0.0025), "0.0025")
        }

        @Test func roundingUpCarriesAcrossEveryBoundary() {
            let boundaries: [(TimeInterval, String)] = [
                (0.9999, "second"),
                (59.9999, "minute"),
                (3_599.9999, "hour"),
                (86_399.9999, "day"),
                // 2100-02-28T23:59:59.9995 — a century year that is NOT a leap
                // year, so this must carry to March 1st, not February 29th.
                (4_107_542_399.9995, "century non-leap month"),
                // 2024-02-28T23:59:59.9999 — a leap year, so this must carry to
                // February 29th.
                (1_709_164_799.9999, "leap day"),
                // 2023-12-31T23:59:59.9999 — carries to the next year.
                (1_704_067_199.9999, "year"),
            ]
            for (t, label) in boundaries {
                expectMatchesReference(Date(timeIntervalSince1970: t), label)
            }
        }

        // MARK: - Calendar edge cases

        @Test func matchesReferenceOnLeapDays() {
            let leapDays: [TimeInterval] = [
                1_709_208_000,   // 2024-02-29T12:00:00Z — divisible by 4
                951_825_600,     // 2000-02-29T12:00:00Z — divisible by 400, IS a leap year
                -60_264_000,     // 1968-02-29T12:00:00Z — pre-epoch leap day
            ]
            for t in leapDays {
                expectMatchesReference(Date(timeIntervalSince1970: t), "leap day")
            }
        }

        @Test func matchesReferenceForPreEpochInstants() {
            let instants: [TimeInterval] = [
                -1,                 // 1969-12-31T23:59:59Z
                -0.001,             // one millisecond before the epoch
                -86_400,            // 1969-12-31T00:00:00Z
                -2_208_988_800,     // 1900-01-01T00:00:00Z — a century non-leap year
                -3_786_825_600,     // 1850-01-01
            ]
            for t in instants {
                expectMatchesReference(Date(timeIntervalSince1970: t), "pre-epoch")
            }
        }

        @Test func matchesReferenceAtYearBoundariesPlusOrMinusOneMillisecond() {
            // 2020-01-01T00:00:00Z through 2030, both sides of each boundary.
            for year in 2020...2030 {
                var components = DateComponents()
                components.year = year
                components.month = 1
                components.day = 1
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC")!
                guard let boundary = calendar.date(from: components) else { continue }
                expectMatchesReference(boundary.addingTimeInterval(-0.001), "year \(year) -1ms")
                expectMatchesReference(boundary, "year \(year)")
                expectMatchesReference(boundary.addingTimeInterval(0.001), "year \(year) +1ms")
            }
        }

        // MARK: - Shape

        @Test func outputIsAlwaysTwentyFourCharacters() {
            let instants: [TimeInterval] = [0, 1, 1_752_003_661.234, -2_208_988_800, 4_107_542_399]
            for t in instants {
                let rendered = TimestampFormatter.iso8601String(from: Date(timeIntervalSince1970: t))
                #expect(rendered.count == 24, "\(rendered)")
                #expect(rendered.hasSuffix("Z"))
                #expect(rendered.dropFirst(10).first == "T")
            }
        }

        @Test func knownInstantRendersExactly() {
            // A literal pin, so a bug that shifted both this and the reference
            // in the same direction would still be caught.
            #expect(
                TimestampFormatter.iso8601String(from: Date(timeIntervalSince1970: 1_752_003_661.234))
                    == "2025-07-08T19:41:01.234Z"
            )
            #expect(
                TimestampFormatter.iso8601String(from: Date(timeIntervalSince1970: 0))
                    == "1970-01-01T00:00:00.000Z"
            )
        }

        // MARK: - Out-of-range fallback

        @Test func instantsOutsideTheFastPathFallBackToTheReferenceFormatter() {
            // Year 10000 and later print five year digits, and dates before the
            // Gregorian changeover follow the Julian calendar. The fast path
            // handles neither, so it must defer rather than print nonsense —
            // and deferring means the output still matches the reference.
            let outOfRange: [TimeInterval] = [
                253_402_300_800,     // 10000-01-01T00:00:00Z
                253_402_300_800.5,
                300_000_000_000,
                -12_219_292_800.001, // one millisecond before the Gregorian changeover
                -12_600_000_000,     // well inside the Julian period
                -62_135_596_800,     // 0001-01-01 proleptic
            ]
            for t in outOfRange {
                expectMatchesReference(Date(timeIntervalSince1970: t), "out of range")
            }
        }

        @Test func theFastPathBoundariesThemselvesUseTheFastPath() {
            // Inclusive lower bound, exclusive upper bound.
            expectMatchesReference(Date(timeIntervalSince1970: -12_219_292_800), "lower bound")
            expectMatchesReference(Date(timeIntervalSince1970: 253_402_300_799.999), "upper bound -1ms")
        }
    }
}

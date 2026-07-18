import XCTest
@testable import LiftMark

/// Unit tests for `DurationFormat` — the canonical M:SS formatter used by
/// every user-facing duration display. See spec/screens/active-workout.md
/// → "Duration Display Consistency".
final class DurationFormatTests: XCTestCase {

    // MARK: - Formatting

    func testFormatsSubMinuteWithLeadingZeroMinute() {
        XCTAssertEqual(DurationFormat.mmss(0), "0:00")
        XCTAssertEqual(DurationFormat.mmss(5), "0:05")
        XCTAssertEqual(DurationFormat.mmss(45), "0:45")
        XCTAssertEqual(DurationFormat.mmss(59), "0:59")
    }

    func testFormatsMinuteBoundaryAndAbove() {
        XCTAssertEqual(DurationFormat.mmss(60), "1:00")
        XCTAssertEqual(DurationFormat.mmss(75), "1:15")
        XCTAssertEqual(DurationFormat.mmss(90), "1:30")
        XCTAssertEqual(DurationFormat.mmss(600), "10:00")
        XCTAssertEqual(DurationFormat.mmss(3725), "62:05")
    }

    func testFormatClampsNegativeToZero() {
        XCTAssertEqual(DurationFormat.mmss(-1), "0:00")
        XCTAssertEqual(DurationFormat.mmss(-75), "0:00")
    }

    // MARK: - Parsing

    func testParsesRawSeconds() {
        XCTAssertEqual(DurationFormat.parse("75"), 75)
        XCTAssertEqual(DurationFormat.parse("0"), 0)
        XCTAssertEqual(DurationFormat.parse(" 180 "), 180)
    }

    func testParsesMMSS() {
        XCTAssertEqual(DurationFormat.parse("1:15"), 75)
        XCTAssertEqual(DurationFormat.parse("0:45"), 45)
        XCTAssertEqual(DurationFormat.parse("10:00"), 600)
        XCTAssertEqual(DurationFormat.parse(" 1:05 "), 65)
        // Single-digit seconds are tolerated ("1:5" → 1:05)
        XCTAssertEqual(DurationFormat.parse("1:5"), 65)
    }

    func testRejectsMalformedInput() {
        XCTAssertNil(DurationFormat.parse(""))
        XCTAssertNil(DurationFormat.parse("abc"))
        XCTAssertNil(DurationFormat.parse("1:60"))
        XCTAssertNil(DurationFormat.parse("1:2:3"))
        XCTAssertNil(DurationFormat.parse(":30"))
        XCTAssertNil(DurationFormat.parse("1:"))
        XCTAssertNil(DurationFormat.parse("-5"))
        XCTAssertNil(DurationFormat.parse("-1:30"))
    }

    func testFormatParseRoundTrip() {
        for seconds in [0, 5, 45, 60, 75, 90, 125, 600] {
            XCTAssertEqual(DurationFormat.parse(DurationFormat.mmss(seconds)), seconds)
        }
    }
}

import XCTest
@testable import LiftMark

/// Regression coverage for the sync round-trip timestamp bug: a `startTime` that comes
/// back from CloudKit with fractional seconds must still parse and format, and a missing
/// or unparseable `startTime` must fall back to a formatted calendar date — never the raw
/// ISO string.
final class SessionDateDisplayTests: XCTestCase {

    // MARK: - ISO8601 tolerant parsing

    func testParsesWholeSecondTimestamp() {
        let date = ISO8601.parse("2026-06-02T16:32:00Z")
        XCTAssertNotNil(date, "Whole-second ISO8601 (locally written form) must parse")
    }

    func testParsesFractionalSecondTimestamp() {
        // This is the form produced when a timestamp round-trips through CloudKit.
        let date = ISO8601.parse("2026-06-02T16:32:00.000Z")
        XCTAssertNotNil(date, "Fractional-second ISO8601 (synced form) must parse")
    }

    func testWholeAndFractionalParseToSameInstant() {
        let whole = ISO8601.parse("2026-06-02T16:32:00Z")
        let fractional = ISO8601.parse("2026-06-02T16:32:00.000Z")
        XCTAssertEqual(whole, fractional, "Both forms must represent the same instant")
    }

    func testNilAndGarbageReturnNil() {
        XCTAssertNil(ISO8601.parse(nil))
        XCTAssertNil(ISO8601.parse(""))
        XCTAssertNil(ISO8601.parse("not a date"))
    }

    // MARK: - shortTime

    func testShortTimeFromFractionalStartTime() {
        // The regression: synced records have fractional seconds and previously yielded nil.
        XCTAssertNotNil(SessionDateDisplay.shortTime(startTime: "2026-06-02T16:32:00.000Z"))
    }

    func testShortTimeNilWhenStartTimeMissing() {
        XCTAssertNil(SessionDateDisplay.shortTime(startTime: nil))
        XCTAssertNil(SessionDateDisplay.shortTime(startTime: "garbage"))
    }

    // MARK: - fullDateLine

    func testFullDateLineFromStartTime() {
        let line = SessionDateDisplay.fullDateLine(startTime: "2026-06-02T16:32:00.000Z",
                                                   date: "2026-06-02")
        XCTAssertTrue(line.contains("2026"))
        XCTAssertNotEqual(line, "2026-06-02", "Must be formatted, not the raw ISO date")
    }

    func testFullDateLineFallsBackToCalendarDateWhenStartTimeMissing() {
        let line = SessionDateDisplay.fullDateLine(startTime: nil, date: "2026-06-02")
        XCTAssertTrue(line.contains("June"), "Expected a formatted month, got: \(line)")
        XCTAssertNotEqual(line, "2026-06-02", "Must never show the raw ISO date string")
    }

    func testFullDateLineHandlesDateWithTimeSuffix() {
        // `date` is documented as yyyy-MM-dd, but be defensive about a longer string.
        let line = SessionDateDisplay.fullDateLine(startTime: nil, date: "2026-06-02T00:00:00Z")
        XCTAssertTrue(line.contains("June"))
    }

    // MARK: - duration

    func testDurationFormatting() {
        XCTAssertEqual(SessionDateDisplay.duration(seconds: 51 * 60), "51 min")
        XCTAssertEqual(SessionDateDisplay.duration(seconds: 80 * 60), "1h 20m")
        XCTAssertNil(SessionDateDisplay.duration(seconds: nil))
    }
}

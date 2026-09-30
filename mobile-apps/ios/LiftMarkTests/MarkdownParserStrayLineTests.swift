import XCTest
@testable import LiftMark

/// STANDALONE_MODIFIER and IGNORED_LINE warnings (GH #425). Mirrors the validator's
/// `STANDALONE_MODIFIER warning` / `IGNORED_LINE warning` suites in
/// validator/tests/parser.test.ts so both parsers agree.
final class MarkdownParserStrayLineTests: XCTestCase {

    private func standalone(_ result: LMWFParseResult) -> [String] {
        result.warnings.filter { $0.contains("on its own line and has no effect") }
    }

    private func ignored(_ result: LMWFParseResult) -> [String] {
        result.warnings.filter { $0.contains("Line ignored") }
    }

    // MARK: - STANDALONE_MODIFIER

    func testBareRestBeforeSetListWarnsAndIsNotApplied() throws {
        let result = MarkdownParser.parseWorkout("# Upper\n\n## Bench Press\n@rest: 180s\n- 185 lbs x 8\n- 185 lbs x 8")
        XCTAssertTrue(result.success)
        let warnings = standalone(result)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].hasPrefix("Line 4:"), warnings[0])
        XCTAssertTrue(warnings[0].contains("\"@rest: 180s\""))
        XCTAssertTrue(warnings[0].contains("\"- 135 lbs x 5 @rest: 180s\""))
        let sets = try XCTUnwrap(result.data?.exercises.first?.sets)
        XCTAssertTrue(sets.allSatisfy { $0.restSeconds == nil })
    }

    func testBareModifierUnderWorkoutHeaderWarns() {
        let warnings = standalone(MarkdownParser.parseWorkout("# Upper\n@rest: 90s\n\n## Bench Press\n- 185 lbs x 8"))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.hasPrefix("Line 2:") ?? false)
    }

    func testBareModifierUnderSupersetHeaderWarns() {
        let markdown = "# W\n## Superset: Arms\n@rest: 60s\n### Curl\n- 30 x 12\n### Pushdown\n- 40 x 12"
        let warnings = standalone(MarkdownParser.parseWorkout(markdown))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.hasPrefix("Line 3:") ?? false)
    }

    func testBareModifierBetweenAndAfterSetsWarnsOnceEach() {
        let result = MarkdownParser.parseWorkout("# W\n## Leg Extension\n- 100 x 12\n@dropset\n- 70 x 10\n@rest: 60s")
        let warnings = standalone(result)
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings[0].hasPrefix("Line 4:"))
        XCTAssertTrue(warnings[1].hasPrefix("Line 6:"))
        XCTAssertTrue(ignored(result).isEmpty)
        XCTAssertEqual(result.data?.exercises.first?.sets[1].isDropset, false)
    }

    func testEveryModifierKeywordCaseInsensitive() {
        let markdown = "# W\n## Plank\n@REST: 2m\n@dropset\n@perside\n@rpe: 8\n@tempo: 3-0-1-0\n@amrap\n- 60s"
        XCTAssertEqual(standalone(MarkdownParser.parseWorkout(markdown)).count, 6)
    }

    func testModifiersOnSetLinesDoNotWarn() {
        let markdown = "# W\n## Bench\n- 185 x 8 @rest: 180s\n- 135 x 10 @dropset"
        XCTAssertTrue(standalone(MarkdownParser.parseWorkout(markdown)).isEmpty)
    }

    func testUnknownMetadataAndTypeDoNotWarn() {
        let markdown = "# W\n@program: 5/3/1\n@restday: no\n## Bench Press\n@type: barbell\n@video: x\n- 185 x 8"
        XCTAssertEqual(MarkdownParser.parseWorkout(markdown).warnings, [])
    }

    func testLinesOutsideWorkoutBlockDoNotWarn() {
        let result = MarkdownParser.parseWorkout("# Log\n@rest: 60s\n# Push Day\n## Bench Press\n- 185 x 8")
        XCTAssertEqual(result.data?.name, "Push Day")
        XCTAssertTrue(standalone(result).isEmpty)
    }

    // MARK: - IGNORED_LINE

    func testProseBetweenAndAfterSetsWarns() {
        let markdown = "# W\n## Row\n- 135 x 10\nKeep your back flat.\n- 155 x 8\n\nFinisher next."
        let result = MarkdownParser.parseWorkout(markdown)
        XCTAssertTrue(result.success)
        let warnings = ignored(result)
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings[0].hasPrefix("Line 4:"))
        XCTAssertTrue(warnings[0].contains("\"Keep your back flat.\""))
        XCTAssertTrue(warnings[1].hasPrefix("Line 7:"))
        XCTAssertEqual(result.data?.exercises.first?.sets.count, 2)
    }

    func testProseUnderSectionHeaderDoesNotWarn() {
        XCTAssertTrue(ignored(MarkdownParser.parseWorkout("# W\n## Warmup\nEasy pace.\n### Jog\n- 5m")).isEmpty)
    }

    func testNotesBeforeFirstSetAndBlankLinesDoNotWarn() {
        let markdown = "# W\nWorkout notes.\n\n## Row\nNotes here.\n\n- 135 x 10\n\n- 155 x 8\n"
        XCTAssertTrue(ignored(MarkdownParser.parseWorkout(markdown)).isEmpty)
    }

    func testLongIgnoredLineIsTruncated() {
        let long = String(repeating: "x", count: 200)
        let warnings = ignored(MarkdownParser.parseWorkout("# W\n## Row\n- 135 x 10\n\(long)"))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertFalse(warnings[0].contains(long))
        XCTAssertTrue(warnings[0].contains("..."))
    }
}

import XCTest
@testable import LiftMark

/// GH #472: `#push day` (no space after `#`) used to yield only "No workout header
/// found" with nothing pointing at the line. The parser now reports MALFORMED_HEADER
/// at the exact line with the corrected text and a quick fix the editor can apply.
final class MarkdownParserMalformedHeaderTests: XCTestCase {

    private let noHeader = "No workout header found. Must have a header (# Workout Name) with exercises below it."

    private func malformed(_ items: [String]) -> [String] {
        items.filter { $0.contains("is missing a space after") }
    }

    // MARK: - Error form (no workout header found)

    /// Spec TC-E35 — the TestFlight report verbatim.
    func testHeaderMissingSpaceIsReportedBeforeGenericNoHeaderError() {
        let result = MarkdownParser.parseWorkout("#push day\n\n## bench press\n- 3 x 100")
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errors, [
            "Line 1: Header \"#push day\" is missing a space after \"#\". Write \"# push day\".",
            noHeader,
        ])
        XCTAssertEqual(result.fixes, [LMWFQuickFix(line: 1, original: "#push day", replacement: "# push day")])
    }

    func testEveryMalformedHeaderLineIsReportedWithItsOwnFix() {
        let result = MarkdownParser.parseWorkout("#Push Day\n\n##Bench Press\n- 135 x 5")
        XCTAssertEqual(malformed(result.errors), [
            "Line 1: Header \"#Push Day\" is missing a space after \"#\". Write \"# Push Day\".",
            "Line 3: Header \"##Bench Press\" is missing a space after \"##\". Write \"## Bench Press\".",
        ])
        XCTAssertEqual(result.fixes, [
            LMWFQuickFix(line: 1, original: "#Push Day", replacement: "# Push Day"),
            LMWFQuickFix(line: 3, original: "##Bench Press", replacement: "## Bench Press"),
        ])
    }

    func testApplyingTheFixYieldsAValidWorkout() {
        let markdown = "#push day\n\n## bench press\n- 3 x 100"
        let broken = MarkdownParser.parseWorkout(markdown)
        let fixed = MarkdownParser.parseWorkout(LMWFQuickFix.applying(broken.fixes, to: markdown))
        XCTAssertTrue(fixed.success, fixed.errors.joined(separator: "; "))
        XCTAssertEqual(fixed.data?.name, "push day")
        XCTAssertEqual(fixed.data?.exercises.first?.exerciseName, "bench press")
        XCTAssertEqual(fixed.fixes, [])
    }

    func testPlainNoHeaderErrorWhenNothingIsHeaderShaped() {
        let result = MarkdownParser.parseWorkout("Just text\n- 225 x 5")
        XCTAssertEqual(result.errors, [noHeader])
        XCTAssertEqual(result.fixes, [])
    }

    func testSevenHashesAndBareHashAreNotMalformedHeaders() {
        let result = MarkdownParser.parseWorkout("#######nope\n#\n- 225 x 5")
        XCTAssertEqual(malformed(result.errors), [])
        XCTAssertEqual(result.fixes, [])
    }

    func testReplacementKeepsHeaderMarksAndTrimsText() {
        let result = MarkdownParser.parseWorkout("###Leg   Day  \n- 5 x 5")
        XCTAssertEqual(result.fixes, [LMWFQuickFix(line: 1, original: "###Leg   Day", replacement: "### Leg   Day")])
    }

    func testLineNumbersCountLeadingBlankLines() {
        // Editors parse the untrimmed text so these match what the user sees.
        let result = MarkdownParser.parseWorkout("\n\n#push day\n## bench press\n- 3 x 100")
        XCTAssertEqual(result.fixes.map(\.line), [3])
        XCTAssertTrue(result.errors.first?.hasPrefix("Line 3:") ?? false)
    }

    // MARK: - Warning form (after an exercise's first set)

    /// Spec TC-W04.
    func testAfterFirstSetItIsAWarningInsteadOfIgnoredLine() {
        let markdown = "# Push Day\n\n## Bench Press\n- 135 lbs x 5\n- 185 lbs x 5\n##Squat\n- 225 lbs x 5"
        let result = MarkdownParser.parseWorkout(markdown)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.warnings, [
            "Line 6: Header \"##Squat\" is missing a space after \"##\". Write \"## Squat\". "
                + "Until it is fixed, the set lines below it count toward the exercise above.",
        ])
        XCTAssertEqual(result.fixes, [LMWFQuickFix(line: 6, original: "##Squat", replacement: "## Squat")])
        XCTAssertEqual(result.data?.exercises.count, 1)
        XCTAssertEqual(result.data?.exercises.first?.sets.count, 3)

        let fixed = MarkdownParser.parseWorkout(LMWFQuickFix.applying(result.fixes, to: markdown))
        XCTAssertEqual(fixed.warnings, [])
        XCTAssertEqual(fixed.data?.exercises.map(\.exerciseName), ["Bench Press", "Squat"])
    }

    func testProseAfterSetsStillGetsIgnoredLine() {
        let result = MarkdownParser.parseWorkout("# W\n## Row\n- 135 x 10\nKeep your back flat.")
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("Line ignored"))
        XCTAssertEqual(result.fixes, [])
    }

    func testValidWorkoutHasNoFixes() {
        XCTAssertEqual(MarkdownParser.parseWorkout("# W\n## Row\n- 135 x 10").fixes, [])
    }

    // MARK: - LMWFQuickFix.applying

    func testApplyingPreservesIndentationAndOtherLines() {
        let fix = LMWFQuickFix(line: 2, original: "##bench", replacement: "## bench")
        XCTAssertEqual(LMWFQuickFix.applying([fix], to: "# W\n  ##bench\n- 1 x 1"), "# W\n  ## bench\n- 1 x 1")
    }

    func testApplyingSkipsStaleFixes() {
        let fix = LMWFQuickFix(line: 2, original: "##bench", replacement: "## bench")
        // The user already edited line 2; the fix no longer matches and must not clobber it.
        let edited = "# W\n## Bench Press\n- 1 x 1"
        XCTAssertEqual(LMWFQuickFix.applying([fix], to: edited), edited)
        // Out-of-range line.
        let outOfRange = LMWFQuickFix(line: 9, original: "x", replacement: "y")
        XCTAssertEqual(LMWFQuickFix.applying([outOfRange], to: "a\nb"), "a\nb")
    }

    func testApplyingNormalizesLineEndingsLikeTheParser() {
        let markdown = "#push day\r\n## bench\r\n- 1 x 1"
        let result = MarkdownParser.parseWorkout(markdown)
        XCTAssertEqual(result.fixes.map(\.line), [1])
        XCTAssertEqual(LMWFQuickFix.applying(result.fixes, to: markdown), "# push day\n## bench\n- 1 x 1")
    }

    func testApplyingNoFixesReturnsInputUnchanged() {
        XCTAssertEqual(LMWFQuickFix.applying([], to: "a\r\nb"), "a\r\nb")
    }
}

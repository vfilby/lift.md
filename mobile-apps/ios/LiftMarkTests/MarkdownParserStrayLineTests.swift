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

    func testBareRestUnderWorkoutHeaderWarnsAndIsNotApplied() {
        let result = MarkdownParser.parseWorkout("# Upper\n@rest: 90s\n\n## Bench Press\n- 185 lbs x 8")
        XCTAssertTrue(result.success)
        let warnings = standalone(result)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].hasPrefix("Line 2:"), warnings[0])
        XCTAssertTrue(warnings[0].contains("\"@rest: 90s\""))
        XCTAssertTrue(warnings[0].contains("\"- 135 lbs x 5 @rest: 90s\""))
        XCTAssertTrue(warnings[0].contains("directly under that exercise's header"))
        XCTAssertNil(result.data?.exercises.first?.sets.first?.restSeconds)
    }

    func testNonRestModifierHasNoExerciseDefaultHint() {
        let warnings = standalone(MarkdownParser.parseWorkout("# W\n@dropset\n## Bench Press\n- 185 x 8"))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertFalse(warnings[0].contains("exercise's header"))
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
        let markdown = "# W\n## Plank\n- 60s\n@REST: 2m\n@dropset\n@perside\n@rpe: 8\n@tempo: 3-0-1-0\n@amrap"
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

/// Exercise-level default `@rest:` (GH #425). Mirrors the validator's
/// `Exercise-level default @rest` suite in validator/tests/parser.test.ts.
final class MarkdownParserDefaultRestTests: XCTestCase {

    private func rests(_ markdown: String, exercise index: Int = 0) -> [Int?] {
        let exercises = MarkdownParser.parseWorkout(markdown).data?.exercises ?? []
        return index < exercises.count ? exercises[index].sets.map(\.restSeconds) : []
    }

    private func standalone(_ result: LMWFParseResult) -> [String] {
        result.warnings.filter { $0.contains("on its own line and has no effect") }
    }

    func testAppliesToSetsWithoutRestAndSetLevelOverrides() {
        let markdown = "# W\n## Bench Press\n@rest: 180s\n- 135 x 5 @rest: 90s\n- 185 x 5\n- 225 x 5"
        XCTAssertEqual(rests(markdown), [90, 180, 180])
        XCTAssertTrue(standalone(MarkdownParser.parseWorkout(markdown)).isEmpty)
    }

    func testMinutesCaseInsensitiveAndCoexistsWithTypeAndNotes() {
        let markdown = "# W\n## Bench Press\nControl the bar.\n@REST: 3m\n@type: barbell\n- 185 x 5"
        let exercise = MarkdownParser.parseWorkout(markdown).data?.exercises.first
        XCTAssertEqual(exercise?.sets.first?.restSeconds, 180)
        XCTAssertEqual(exercise?.equipmentType, "barbell")
        XCTAssertEqual(exercise?.notes, "Control the bar.")
    }

    func testNotAppliedToDropSetsUnlessTheyCarryTheirOwnRest() {
        let markdown = "# W\n## Curl\n@rest: 60s\n- 40 x 10\n- 30 x 12 @dropset\n- 20 x 15 @dropset @rest: 120s"
        XCTAssertEqual(rests(markdown), [60, nil, 120])
    }

    func testOnlyAppliesToItsOwnExercise() {
        XCTAssertEqual(rests("# W\n## Bench Press\n@rest: 90s\n- 185 x 5\n## Squat\n- 225 x 5", exercise: 1), [nil])
    }

    func testWorksInsideSupersetWhileSupersetLevelRestWarns() {
        let markdown = "# W\n## Superset: Arms\n@rest: 90s\n### Curl\n@rest: 30s\n- 30 x 12\n### Pushdown\n- 40 x 12"
        let result = MarkdownParser.parseWorkout(markdown)
        let firstRests = (result.data?.exercises ?? []).filter { !$0.sets.isEmpty }.map { $0.sets[0].restSeconds }
        XCTAssertEqual(firstRests, [30, nil])
        let warnings = standalone(result)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.hasPrefix("Line 3:") ?? false)
    }

    func testAfterFirstSetItIsStandaloneNotDefault() {
        let markdown = "# W\n## Row\n- 135 x 8\n@rest: 120s\n- 135 x 8"
        XCTAssertEqual(rests(markdown), [nil, nil])
        XCTAssertEqual(standalone(MarkdownParser.parseWorkout(markdown)).count, 1)
    }

    func testLastRestLineWins() {
        XCTAssertEqual(rests("# W\n## Bench Press\n@rest: 60s\n@rest: 90s\n- 185 x 5"), [90])
    }

    func testInvalidValueIsInvalidRestError() {
        for value in ["abc", "-30s", "90s between sets"] {
            let result = MarkdownParser.parseWorkout("# W\n## Bench Press\n@rest: \(value)\n- 185 x 5")
            XCTAssertFalse(result.success, value)
            XCTAssertTrue(result.errors.first?.hasPrefix("Line 3: Invalid rest time format") ?? false, value)
            XCTAssertTrue(standalone(result).isEmpty, value)
        }
    }

    func testShortAndLongRestWarnOnceOnTheRestLine() {
        let short = MarkdownParser.parseWorkout("# W\n## Bench Press\n@rest: 5s\n- 185 x 5\n- 185 x 5").warnings
        XCTAssertEqual(
            short.filter { $0.contains("Very short rest") },
            ["Line 3: Very short rest period (5s). Double-check for typos."]
        )
        let long = MarkdownParser.parseWorkout("# W\n## Bench Press\n@rest: 11m\n- 185 x 5\n- 185 x 5").warnings
        XCTAssertEqual(long.filter { $0.contains("Very long rest") }.count, 1)
    }
}

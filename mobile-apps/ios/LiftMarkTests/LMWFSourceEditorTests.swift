import XCTest
@testable import LiftMark

/// Tests for `LMWFSourceEditor` and the parser source-span support it relies on.
///
/// Regression coverage for GH #264: editing a single exercise used to regenerate
/// the whole plan and flatten every header to `##`, so `## Warmup` / `### Band
/// Side Step` collapsed to two `##` headers and broke the section nesting. These
/// tests assert that a splice preserves the original header levels and every
/// block the user didn't edit.
final class LMWFSourceEditorTests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ markdown: String) -> WorkoutPlan {
        let result = MarkdownParser.parseWorkout(markdown)
        guard let plan = result.data else {
            fatalError("fixture failed to parse: \(result.errors)")
        }
        return plan
    }

    private func exercise(_ plan: WorkoutPlan, named name: String) -> PlannedExercise {
        guard let ex = plan.exercises.first(where: { $0.exerciseName == name }) else {
            fatalError("no exercise named \(name)")
        }
        return ex
    }

    /// Whole-line membership. Needed because `"### Foo".contains("## Foo")` is
    /// true as a substring — only a line-level check distinguishes header levels.
    private func hasLine(_ text: String, _ line: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { $0 == Substring(line) }
    }

    // MARK: - The reported scenario: section child stays H3

    func testEditingSectionChildPreservesHeaderLevels() throws {
        let source = """
        # Full Body

        ## Warmup

        ### Band Side Step
        - 10

        ### Leg Swings
        - 10

        ## Bench Press
        - 135 lbs x 5
        """

        let plan = parse(source)
        var edited = exercise(plan, named: "Band Side Step")
        edited.sets[0].targetReps = 15

        let out = LMWFSourceEditor.replacingExercise(orderIndex: edited.orderIndex, in: source, with: [edited])
        let spliced = try XCTUnwrap(out)

        // The bug signature: the child must NOT be flattened to `##`.
        XCTAssertTrue(hasLine(spliced, "### Band Side Step"), "child header level H3 must be preserved")
        XCTAssertFalse(hasLine(spliced, "## Band Side Step"), "child must not collapse to H2")
        XCTAssertTrue(spliced.contains("- 15"), "the edit must be applied")

        // Everything the user didn't touch is untouched.
        XCTAssertTrue(hasLine(spliced, "## Warmup"))
        XCTAssertTrue(hasLine(spliced, "### Leg Swings"))
        XCTAssertTrue(hasLine(spliced, "## Bench Press"))
        XCTAssertTrue(spliced.contains("- 135 lbs x 5"))

        // And it still parses back into the same structure.
        let reparsed = parse(spliced)
        let warmup = exercise(reparsed, named: "Warmup")
        XCTAssertEqual(warmup.groupType, .section)
        let bss = exercise(reparsed, named: "Band Side Step")
        XCTAssertEqual(bss.parentExerciseId, warmup.id)
        XCTAssertEqual(bss.sets.first?.targetReps, 15)
    }

    // MARK: - Non-standard workout header level

    func testEditingExercisePreservesNonStandardWorkoutLevel() throws {
        // Workout at H2 → exercises at H3. An edit must keep the H3 exercises.
        let source = """
        ## Push Day

        ### Bench Press
        - 135 lbs x 5

        ### Squat
        - 225 lbs x 5
        """

        let plan = parse(source)
        var edited = exercise(plan, named: "Bench Press")
        edited.sets[0].targetReps = 8

        let spliced = try XCTUnwrap(
            LMWFSourceEditor.replacingExercise(orderIndex: edited.orderIndex, in: source, with: [edited])
        )

        XCTAssertTrue(hasLine(spliced, "### Bench Press"))
        XCTAssertFalse(hasLine(spliced, "## Bench Press"))
        XCTAssertTrue(hasLine(spliced, "### Squat"))
        XCTAssertTrue(spliced.contains("- 135 lbs x 8"))
    }

    // MARK: - Superset block with non-adjacent child levels

    func testEditingSupersetPreservesNestedLevels() throws {
        // Superset children at H4 while the parent is H2 (a legal level skip).
        let source = """
        # Day

        ## Superset: Arms
        #### Curl
        - 30 lbs x 12

        #### Pushdown
        - 40 lbs x 12

        ## Squat
        - 225 lbs x 5
        """

        let plan = parse(source)
        let parent = exercise(plan, named: "Superset: Arms")
        let children = plan.exercises.filter { $0.parentExerciseId == parent.id }
        XCTAssertEqual(children.count, 2)

        var curl = children[0]
        curl.sets[0].targetReps = 10

        let block = [parent, curl, children[1]]
        let spliced = try XCTUnwrap(
            LMWFSourceEditor.replacingExercise(orderIndex: parent.orderIndex, in: source, with: block)
        )

        XCTAssertTrue(hasLine(spliced, "## Superset: Arms"))
        XCTAssertTrue(hasLine(spliced, "#### Curl"), "superset child level H4 must survive")
        XCTAssertTrue(hasLine(spliced, "#### Pushdown"))
        XCTAssertFalse(hasLine(spliced, "### Curl"), "child must not be normalized to parent+1")
        XCTAssertTrue(spliced.contains("- 30 lbs x 10"))
        XCTAssertTrue(hasLine(spliced, "## Squat"))

        // Re-parse: still a two-member superset.
        let reparsed = parse(spliced)
        let rp = exercise(reparsed, named: "Superset: Arms")
        XCTAssertEqual(rp.groupType, .superset)
        XCTAssertEqual(reparsed.exercises.filter { $0.parentExerciseId == rp.id }.count, 2)
    }

    // MARK: - Splicing leaves other blocks byte-for-byte

    func testSpliceOnlyTouchesTargetBlock() throws {
        let source = """
        # Full Body

        ## Warmup

        ### Band Side Step
        - 10

        ### Leg Swings
        - 10

        ## Bench Press
        - 135 lbs x 5
        """

        let plan = parse(source)
        var edited = exercise(plan, named: "Band Side Step")
        edited.sets[0].targetReps = 15

        let spliced = try XCTUnwrap(
            LMWFSourceEditor.replacingExercise(orderIndex: edited.orderIndex, in: source, with: [edited])
        )

        // Leg Swings and Bench Press blocks are unchanged, including their spacing.
        XCTAssertTrue(spliced.contains("### Leg Swings\n- 10"))
        XCTAssertTrue(spliced.contains("## Bench Press\n- 135 lbs x 5"))
    }

    // MARK: - Renames follow the header text, not stale groupName

    func testRenamingSupersetEmitsNewHeaderText() throws {
        let source = """
        # Day

        ## Superset: Arms
        ### Curl
        - 30 lbs x 12

        ### Pushdown
        - 40 lbs x 12
        """

        let plan = parse(source)
        var parent = exercise(plan, named: "Superset: Arms")
        let children = plan.exercises.filter { $0.parentExerciseId == parent.id }
        // Simulate a rename: the sheet updates exerciseName but groupName lags.
        parent.exerciseName = "Superset: Biceps"

        let spliced = try XCTUnwrap(
            LMWFSourceEditor.replacingExercise(orderIndex: parent.orderIndex, in: source, with: [parent] + children)
        )

        XCTAssertTrue(hasLine(spliced, "## Superset: Biceps"))
        XCTAssertFalse(hasLine(spliced, "## Superset: Arms"))
        XCTAssertEqual(parse(spliced).exercises.first(where: { $0.groupType == .superset && $0.sets.isEmpty })?.exerciseName, "Superset: Biceps")
    }

    // MARK: - Parser span accuracy

    func testParserRecordsSourceSpans() {
        let source = """
        # Full Body

        ## Warmup

        ### Band Side Step
        - 10

        ### Leg Swings
        - 10

        ## Bench Press
        - 135 lbs x 5
        """

        let result = MarkdownParser.parseWorkout(source)
        XCTAssertTrue(result.success)

        // orderIndex layout: 0 = Warmup group, 1 = Band Side Step, 2 = Leg Swings, 3 = Bench Press
        XCTAssertEqual(result.exerciseSpans[1], LMWFSourceSpan(startLine: 5, endLine: 6, headerLevel: 3, childHeaderLevel: nil))
        XCTAssertEqual(result.exerciseSpans[2], LMWFSourceSpan(startLine: 8, endLine: 9, headerLevel: 3, childHeaderLevel: nil))
        XCTAssertEqual(result.exerciseSpans[0], LMWFSourceSpan(startLine: 3, endLine: 9, headerLevel: 2, childHeaderLevel: 3))
        XCTAssertEqual(result.exerciseSpans[3], LMWFSourceSpan(startLine: 11, endLine: 12, headerLevel: 2, childHeaderLevel: nil))
    }

    // MARK: - Legacy fallback

    func testUnlocatableOrderIndexReturnsNil() {
        let source = """
        # Day

        ## Squat
        - 225 lbs x 5
        """
        let plan = parse(source)
        let squat = exercise(plan, named: "Squat")
        // orderIndex far outside the document → no span → nil (caller keeps source).
        XCTAssertNil(LMWFSourceEditor.replacingExercise(orderIndex: 99, in: source, with: [squat]))
    }
}

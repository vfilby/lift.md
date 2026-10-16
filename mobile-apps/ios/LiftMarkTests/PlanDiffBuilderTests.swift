import XCTest
@testable import LiftMark

/// Exercise-level diff used by the Edit with AI sheet. See
/// spec/services/ai-plan-editing.md ("Diff").
final class PlanDiffBuilderTests: XCTestCase {

    private func diff(_ before: String, _ after: String) -> PlanDiff {
        PlanDiffBuilder.diff(before: PlanEditFixtures.parse(before), after: PlanEditFixtures.parse(after))
    }

    // MARK: - Entry kinds

    func testIdenticalPlansAreUnchangedAndEmpty() {
        let result = diff(PlanEditFixtures.pushDay, PlanEditFixtures.pushDay)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.unchangedCount, 2)
        XCTAssertTrue(result.changedEntries.isEmpty)
        XCTAssertTrue(result.headerChanges.isEmpty)
    }

    func testAddedExercise() {
        let after = PlanEditFixtures.pushDay + "\n\n## Face Pull\n- x 15\n- x 15\n"
        let result = diff(PlanEditFixtures.pushDay, after)

        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.changedEntries.count, 1)
        guard case .added(let exercise)? = result.changedEntries.first else {
            return XCTFail("expected .added, got \(result.changedEntries)")
        }
        XCTAssertEqual(exercise.name, "Face Pull")
        XCTAssertEqual(exercise.setLines, ["- 15", "- 15"])
        XCTAssertEqual(result.entries.last, .added(exercise), "added exercise keeps its position (end)")
    }

    func testRemovedExerciseKeepsItsPosition() {
        let after = """
        # Push Day
        @tags: strength, push
        @units: lbs

        ## Overhead Press
        - 95 x 8
        - 95 x 8
        """
        let result = diff(PlanEditFixtures.pushDay, after)

        XCTAssertEqual(result.entries.count, 2)
        guard case .removed(let removed) = result.entries[0] else {
            return XCTFail("expected removed first, got \(result.entries)")
        }
        XCTAssertEqual(removed.name, "Bench Press")
        XCTAssertTrue(result.entries[1].isUnchanged)
    }

    func testChangedSetsReportBeforeAndAfter() {
        let after = PlanEditFixtures.pushDay.replacingOccurrences(of: "- 225 x 5", with: "- 235 x 5")
        let result = diff(PlanEditFixtures.pushDay, after)

        XCTAssertEqual(result.changedEntries.count, 1)
        guard case .changed(let before, let afterExercise)? = result.changedEntries.first else {
            return XCTFail("expected .changed, got \(result.changedEntries)")
        }
        XCTAssertEqual(before.name, "Bench Press")
        XCTAssertEqual(before.setLines.last, "- 225 lbs x 5 @rest: 180s")
        XCTAssertEqual(afterExercise.setLines.last, "- 235 lbs x 5 @rest: 180s")
    }

    func testChangedNotesEquipmentAndRestAreDetected() {
        let notes = diff(PlanEditFixtures.pushDay, PlanEditFixtures.pushDay.replacingOccurrences(
            of: "## Overhead Press\n", with: "## Overhead Press\nStrict, no leg drive.\n"))
        XCTAssertEqual(notes.changedEntries.count, 1)

        let equipment = diff(PlanEditFixtures.pushDay, PlanEditFixtures.pushDay.replacingOccurrences(
            of: "## Overhead Press\n", with: "## Overhead Press\n@type: barbell\n"))
        XCTAssertEqual(equipment.changedEntries.count, 1)

        let rest = diff(PlanEditFixtures.pushDay, PlanEditFixtures.pushDay.replacingOccurrences(
            of: "@rest: 180s", with: "@rest: 120s"))
        XCTAssertEqual(rest.changedEntries.count, 1)
        guard case .changed(_, let afterExercise)? = rest.changedEntries.first else {
            return XCTFail("expected .changed")
        }
        XCTAssertTrue(afterExercise.setLines.allSatisfy { $0.hasSuffix("@rest: 120s") })
    }

    // MARK: - Matching rules

    func testMatchingIsCaseAndWhitespaceInsensitive() {
        let after = PlanEditFixtures.pushDay.replacingOccurrences(of: "## Bench Press", with: "##   bench press  ")
        let result = diff(PlanEditFixtures.pushDay, after)
        XCTAssertTrue(result.isEmpty, "same exercise with different casing must match: \(result.entries)")
    }

    func testSupersetScopedMatching() {
        let before = """
        # Arms
        @units: lbs

        ## Superset: A
        ### Curl
        - 30 x 10
        ### Pushdown
        - 40 x 12

        ## Superset: B
        ### Hammer Curl
        - 25 x 12
        """
        let after = """
        # Arms
        @units: lbs

        ## Superset: A
        ### Pushdown
        - 40 x 12

        ## Superset: B
        ### Hammer Curl
        - 25 x 12
        ### Curl
        - 30 x 10
        """
        let result = diff(before, after)

        // Curl moved between supersets: it is removed from A and added to B,
        // because matching is scoped to the parent.
        let removed = result.entries.compactMap { entry -> PlanDiffExercise? in
            if case .removed(let exercise) = entry { return exercise }
            return nil
        }
        let added = result.entries.compactMap { entry -> PlanDiffExercise? in
            if case .added(let exercise) = entry { return exercise }
            return nil
        }
        XCTAssertEqual(removed.map(\.name), ["Curl"])
        XCTAssertEqual(removed.first?.parent, "Superset: A")
        XCTAssertEqual(added.map(\.name), ["Curl"])
        XCTAssertEqual(added.first?.parent, "Superset: B")
        XCTAssertEqual(result.unchangedCount, 2)
    }

    func testSetEqualityIsUnitNormalised() {
        let after = PlanEditFixtures.pushDay
            .replacingOccurrences(of: "- 135 x 5", with: "- 135 lbs x 5")
            .replacingOccurrences(of: "- 95 x 8\n- 95 x 8", with: "- 95 lbs x 8\n- 95 lbs x 8")
        let result = diff(PlanEditFixtures.pushDay, after)
        XCTAssertTrue(result.isEmpty, "`135 x 5` and `135 lbs x 5` under @units: lbs compare equal: \(result.entries)")
    }

    func testUnitChangeIsAChange() {
        let after = PlanEditFixtures.pushDay.replacingOccurrences(of: "- 135 x 5", with: "- 135 kg x 5")
        let result = diff(PlanEditFixtures.pushDay, after)
        XCTAssertEqual(result.changedEntries.count, 1)
    }

    // MARK: - Header changes

    func testHeaderChanges() {
        let after = PlanEditFixtures.pushDay
            .replacingOccurrences(of: "# Push Day", with: "# Push Day (short)")
            .replacingOccurrences(of: "@tags: strength, push", with: "@tags: strength")
        let result = diff(PlanEditFixtures.pushDay, after)

        XCTAssertEqual(result.headerChanges.count, 2)
        XCTAssertTrue(result.headerChanges.contains { $0.contains("Push Day (short)") })
        XCTAssertTrue(result.headerChanges.contains { $0.hasPrefix("Tags") })
        XCTAssertFalse(result.isEmpty, "header-only changes still make the diff non-empty")
        XCTAssertTrue(result.changedEntries.isEmpty)
    }

    func testUnitsAndNotesHeaderChanges() {
        let after = PlanEditFixtures.pushDay
            .replacingOccurrences(of: "@units: lbs", with: "@units: kg\n\nKeep rests tight.")
        let result = diff(PlanEditFixtures.pushDay, after)

        XCTAssertTrue(result.headerChanges.contains("Units: kg"))
        XCTAssertTrue(result.headerChanges.contains("Workout notes changed"))
    }
}

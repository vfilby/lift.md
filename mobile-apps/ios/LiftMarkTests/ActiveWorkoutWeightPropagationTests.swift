import XCTest
@testable import LiftMark

/// Weight propagation to remaining equal-target sets (GH #5, regression GH #489).
final class ActiveWorkoutWeightPropagationTests: XCTestCase {

    private func suggested(
        _ index: Int, in sets: [SessionSet], current: Int? = nil, weight: Double? = nil
    ) -> Double? {
        ActiveWorkoutViewModel.suggestedWeight(
            forSetAt: index, in: sets, currentSetIndex: current, currentWeight: weight)
    }

    // MARK: - Live edit of the current set

    func testLiveEditPropagatesToLaterPendingSetsWithSameTarget() {
        let sets = [pending(92.5), pending(92.5), pending(92.5), pending(100)]
        XCTAssertEqual(suggested(1, in: sets, current: 0, weight: 95), 95)
        XCTAssertEqual(suggested(2, in: sets, current: 0, weight: 95), 95)
        XCTAssertNil(suggested(3, in: sets, current: 0, weight: 95), "different target keeps its own weight")
        XCTAssertNil(suggested(0, in: sets, current: 0, weight: 95), "the current set is not overridden")
    }

    func testLiveEditIgnoredWhenCurrentSetIsAfterQueriedSet() {
        let sets = [pending(92.5), pending(92.5)]
        XCTAssertNil(suggested(0, in: sets, current: 1, weight: 95))
    }

    func testLiveEditIgnoredWhenCurrentTargetDiffers() {
        let sets = [pending(100), pending(92.5)]
        XCTAssertNil(suggested(1, in: sets, current: 0, weight: 95))
    }

    func testLiveEditIgnoredWhenLiveWeightIsNil() {
        let sets = [pending(92.5), pending(92.5)]
        XCTAssertNil(suggested(1, in: sets, current: 0, weight: nil))
    }

    // MARK: - Carried by completed sets

    func testCompletedChangedWeightCarriesToRemainingSameTargetSets() {
        let sets = [completed(92.5, actual: 95), pending(92.5), pending(92.5)]
        XCTAssertEqual(suggested(1, in: sets, current: 1), 95)
        XCTAssertEqual(suggested(2, in: sets, current: 1), 95)
    }

    func testCompletedAtTargetSuggestsTarget() {
        let sets = [completed(92.5, actual: 95), completed(92.5, actual: 92.5), pending(92.5)]
        XCTAssertEqual(suggested(2, in: sets, current: 2), 92.5)
    }

    func testMostRecentCompletedSameTargetSetWins() {
        let sets = [completed(92.5, actual: 95), completed(92.5, actual: 97.5), pending(92.5)]
        XCTAssertEqual(suggested(2, in: sets, current: 2), 97.5)
    }

    func testSkippedSetsDoNotContribute() {
        var skipped = pending(92.5)
        skipped.status = .skipped
        let sets = [completed(92.5, actual: 95), skipped, pending(92.5)]
        XCTAssertEqual(suggested(2, in: sets, current: 2), 95)
    }

    func testCompletedSetWithDifferentTargetDoesNotContribute() {
        let sets = [completed(100, actual: 105), pending(92.5)]
        XCTAssertNil(suggested(1, in: sets, current: 1))
    }

    // MARK: - Non-matching sets

    func testDifferentUnitsDoNotMatch() {
        let sets = [completed(92.5, actual: 95), pending(92.5, unit: .kg)]
        XCTAssertNil(suggested(1, in: sets, current: 1))
        let live = [pending(92.5), pending(92.5, unit: .kg)]
        XCTAssertNil(suggested(1, in: live, current: 0, weight: 95))
    }

    func testNonPendingQueriedSetsSuggestNothing() {
        var skipped = pending(92.5)
        skipped.status = .skipped
        let sets = [pending(92.5), completed(92.5, actual: 92.5), skipped]
        XCTAssertNil(suggested(1, in: sets, current: 0, weight: 95))
        XCTAssertNil(suggested(2, in: sets, current: 0, weight: 95))
    }

    func testSetsWithoutTargetWeightSuggestNothing() {
        let repsOnly = SessionSet(
            sessionExerciseId: "e1", orderIndex: 1,
            entries: [SetEntry(groupIndex: 0, target: EntryValues(reps: 10), actual: nil)])
        let sets = [completed(92.5, actual: 95), repsOnly]
        XCTAssertNil(suggested(1, in: sets, current: 0, weight: 95))
        XCTAssertNil(suggested(5, in: sets), "out-of-range index")
    }

    // MARK: - Helpers

    private func pending(_ target: Double, unit: WeightUnit = .lbs) -> SessionSet {
        SessionSet(
            sessionExerciseId: "e1", orderIndex: 0,
            entries: [SetEntry(
                groupIndex: 0,
                target: EntryValues(weight: MeasuredWeight(value: target, unit: unit), reps: 5),
                actual: nil)])
    }

    private func completed(_ target: Double, actual: Double) -> SessionSet {
        SessionSet(
            sessionExerciseId: "e1", orderIndex: 0,
            entries: [SetEntry(
                groupIndex: 0,
                target: EntryValues(weight: MeasuredWeight(value: target, unit: .lbs), reps: 5),
                actual: EntryValues(weight: MeasuredWeight(value: actual, unit: .lbs), reps: 5))],
            status: .completed)
    }
}

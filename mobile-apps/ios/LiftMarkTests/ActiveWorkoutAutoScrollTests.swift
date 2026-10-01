import XCTest
@testable import LiftMark

/// Tests for `ActiveWorkoutViewModel.autoScrollTarget` — where the active
/// workout list scrolls after a set is completed. Guards #433: when the new
/// current set is timed, its exercise timer must be scrolled into view.
final class ActiveWorkoutAutoScrollTests: XCTestCase {

    private typealias Target = ActiveWorkoutViewModel.AutoScrollTarget

    // MARK: - Single exercises

    func testTimedSetInSameExerciseTargetsItsTimer() {
        // Plank set 1 done; set 2 (timed) is now current — scroll to its timer.
        let plank = exercise("plank", sets: [
            timedSet("p1", status: .completed), timedSet("p2"), timedSet("p3")
        ])
        XCTAssertEqual(target([plank], last: "plank"), .exerciseTimer(setId: "p2"))
    }

    func testRepSetInSameExerciseStaysPut() {
        let bench = exercise("bench", sets: [repSet("b1", status: .completed), repSet("b2")])
        XCTAssertNil(target([bench], last: "bench"))
    }

    func testTimedNextExerciseTargetsItsTimer() {
        // Finishing the previous exercise moves focus to a timed stretch: the
        // timer, not just the card top, must come into view (#433).
        let lunges = exercise("lunges", sets: [repSet("l1", status: .completed)])
        let stretch = exercise("stretch", sets: [timedSet("w-left"), timedSet("w-right")])
        XCTAssertEqual(target([lunges, stretch], last: "lunges"), .exerciseTimer(setId: "w-left"))
    }

    func testRepNextExerciseTargetsCardTop() {
        let squat = exercise("squat", sets: [repSet("s1", status: .completed)])
        let deadlift = exercise("deadlift", sets: [repSet("d1")])
        XCTAssertEqual(target([squat, deadlift], last: "squat"), .card(id: "deadlift"))
    }

    func testTimedTargetSkipsCompletedAndSkippedSets() {
        let plank = exercise("plank", sets: [
            timedSet("p1", status: .completed), timedSet("p2", status: .skipped), timedSet("p3")
        ])
        XCTAssertEqual(target([plank], last: "plank"), .exerciseTimer(setId: "p3"))
    }

    func testZeroTargetTimeIsNotTimed() {
        let first = exercise("a", sets: [repSet("a1", status: .completed)])
        let zero = exercise("b", sets: [timedSet("b1", seconds: 0)])
        XCTAssertEqual(target([first, zero], last: "a"), .card(id: "b"))
    }

    // MARK: - Search order

    func testNoInteractionTargetsFirstPendingCard() {
        let done = exercise("a", sets: [repSet("a1", status: .completed)])
        let next = exercise("b", sets: [repSet("b1")])
        XCTAssertEqual(target([done, next], last: nil), .card(id: "b"))
    }

    func testSearchWrapsToEarlierPendingExercise() {
        let skippedEarlier = exercise("a", sets: [repSet("a1")])
        let justFinished = exercise("b", sets: [repSet("b1", status: .completed)])
        XCTAssertEqual(target([skippedEarlier, justFinished], last: "b"), .card(id: "a"))
    }

    func testAllDoneReturnsNil() {
        let done = exercise("a", sets: [repSet("a1", status: .completed)])
        let skipped = exercise("b", sets: [timedSet("b1", status: .skipped)])
        XCTAssertNil(target([done, skipped], last: "b"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(target([], last: nil))
    }

    // MARK: - Supersets

    func testSupersetTimedSetTargetsTimerInRoundRobinOrder() {
        // A1 done → round-robin current set is B1 (timed), not A2.
        let exercises = superset(
            childA: [repSet("a1", status: .completed), repSet("a2")],
            childB: [timedSet("b1"), timedSet("b2")])
        XCTAssertEqual(target(exercises, last: "child-a"), .exerciseTimer(setId: "b1"))
    }

    func testSupersetStaysPutWhenSiblingStillPending() {
        // The interacted child is finished but its sibling is not: the user
        // is still inside the same superset card, so do not scroll.
        let exercises = superset(
            childA: [repSet("a1", status: .completed)],
            childB: [repSet("b1")])
        XCTAssertNil(target(exercises, last: "child-a"))
    }

    func testNextSupersetTargetsParentCard() {
        // Superset cards are identified by their parent id; child ids have no
        // view in the scroll content.
        let warmup = exercise("warmup", sets: [repSet("w1", status: .completed)])
        let exercises = [warmup] + superset(childA: [repSet("a1")], childB: [repSet("b1")])
        XCTAssertEqual(target(exercises, last: "warmup"), .card(id: "ss"))
    }

    // MARK: - Scroll id

    func testExerciseTimerScrollIdDiffersFromSetId() {
        // The set row already uses the set id; the timer needs its own.
        XCTAssertNotEqual(ActiveWorkoutViewModel.exerciseTimerScrollId(setId: "s1"), "s1")
    }

    // MARK: - Helpers

    private func target(_ exercises: [SessionExercise], last: String?) -> Target? {
        ActiveWorkoutViewModel.autoScrollTarget(exercises: exercises, lastInteractedExerciseId: last)
    }

    private func exercise(
        _ id: String, groupType: GroupType? = nil, parent: String? = nil, sets: [SessionSet]
    ) -> SessionExercise {
        SessionExercise(
            id: id, workoutSessionId: "session1", exerciseName: id, orderIndex: 0,
            groupType: groupType, parentExerciseId: parent, sets: sets, status: .pending)
    }

    private func superset(childA: [SessionSet], childB: [SessionSet]) -> [SessionExercise] {
        [
            exercise("ss", groupType: .superset, sets: []),
            exercise("child-a", parent: "ss", sets: childA),
            exercise("child-b", parent: "ss", sets: childB)
        ]
    }

    private func repSet(_ id: String, status: SetStatus = .pending) -> SessionSet {
        SessionSet(id: id, sessionExerciseId: "e", orderIndex: 0, targetReps: 5, status: status)
    }

    private func timedSet(_ id: String, seconds: Int = 30, status: SetStatus = .pending) -> SessionSet {
        SessionSet(id: id, sessionExerciseId: "e", orderIndex: 0, targetTime: seconds, status: status)
    }
}

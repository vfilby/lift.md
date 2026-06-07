import XCTest
@testable import LiftMark

/// The single source of truth for a plan's exercise/set tally
/// (`WorkoutPlan.displayExerciseCount` / `.plannedSetCount` /
/// `PlannedExercise.isStructuralHeader`). These back every count shown across
/// the app — plan cards, the detail header, the inbox row + preview, and the
/// import confirmation — so the same plan can't report two different numbers.
/// Regression guard for the inbox "16 exercises vs 14 exercises" mismatch.
final class WorkoutPlanCountTests: XCTestCase {

    private func set(_ exId: String, reps: Int) -> PlannedSet {
        PlannedSet(plannedExerciseId: exId, orderIndex: 0, targetReps: reps)
    }

    /// Mirrors the reported plan: a "Warm-Up" section header + a real superset
    /// (parent + 2 children) + 2 standalone exercises. The raw
    /// `exercises.count` is 6 (incl. the two structural headers); the display
    /// count is 4 (the section header and the empty superset parent drop out).
    func testDisplayExerciseCountExcludesStructuralHeaders() {
        let exercises: [PlannedExercise] = [
            PlannedExercise(workoutPlanId: "p", exerciseName: "Warm-Up", orderIndex: 0, groupType: .section, sets: []),
            PlannedExercise(workoutPlanId: "p", exerciseName: "Superset: Arms", orderIndex: 1, groupType: .superset, sets: []),
            PlannedExercise(workoutPlanId: "p", exerciseName: "Tricep Pushdown", orderIndex: 2, groupType: .superset, parentExerciseId: "ss", sets: [set("c1", reps: 12), set("c1", reps: 12)]),
            PlannedExercise(workoutPlanId: "p", exerciseName: "Curl", orderIndex: 3, groupType: .superset, parentExerciseId: "ss", sets: [set("c2", reps: 12), set("c2", reps: 12)]),
            PlannedExercise(workoutPlanId: "p", exerciseName: "Squat", orderIndex: 4, sets: [set("e1", reps: 5), set("e1", reps: 5), set("e1", reps: 5)]),
            PlannedExercise(workoutPlanId: "p", exerciseName: "Deadlift", orderIndex: 5, sets: [set("e2", reps: 5)]),
        ]
        let plan = WorkoutPlan(name: "Lower", exercises: exercises)

        XCTAssertEqual(plan.exercises.count, 6, "raw array includes structural headers")
        XCTAssertEqual(plan.displayExerciseCount, 4, "section header + empty superset parent excluded")
        XCTAssertEqual(plan.plannedSetCount, 2 + 2 + 3 + 1)
    }

    func testIsStructuralHeaderPredicate() {
        let section = PlannedExercise(workoutPlanId: "p", exerciseName: "Warm-Up", orderIndex: 0, groupType: .section, sets: [])
        let supersetParent = PlannedExercise(workoutPlanId: "p", exerciseName: "Superset", orderIndex: 1, groupType: .superset, sets: [])
        let supersetChild = PlannedExercise(workoutPlanId: "p", exerciseName: "Child", orderIndex: 2, groupType: .superset, parentExerciseId: "ss", sets: [set("c", reps: 8)])
        let regular = PlannedExercise(workoutPlanId: "p", exerciseName: "Squat", orderIndex: 3, sets: [set("r", reps: 5)])

        XCTAssertTrue(section.isStructuralHeader)
        XCTAssertTrue(supersetParent.isStructuralHeader)
        XCTAssertFalse(supersetChild.isStructuralHeader, "a superset child has sets — it is a performed exercise")
        XCTAssertFalse(regular.isStructuralHeader)
    }

    func testEmptyPlanCountsZero() {
        let plan = WorkoutPlan(name: "Empty", exercises: [])
        XCTAssertEqual(plan.displayExerciseCount, 0)
        XCTAssertEqual(plan.plannedSetCount, 0)
    }

    /// A plain plan (no grouping) counts every exercise — nothing is excluded.
    func testPlainPlanCountsAllExercises() {
        let exercises = (0..<3).map { i in
            PlannedExercise(workoutPlanId: "p", exerciseName: "Ex\(i)", orderIndex: i, sets: [set("e\(i)", reps: 5)])
        }
        let plan = WorkoutPlan(name: "Plain", exercises: exercises)
        XCTAssertEqual(plan.displayExerciseCount, 3)
        XCTAssertEqual(plan.plannedSetCount, 3)
    }
}

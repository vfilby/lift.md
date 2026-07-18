import XCTest
@testable import LiftMark

final class ExerciseHistoryRepositoryTests: XCTestCase {

    private var repo: ExerciseHistoryRepository!
    private var sessionRepo: SessionRepository!
    private var planRepo: WorkoutPlanRepository!

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        repo = ExerciseHistoryRepository()
        sessionRepo = SessionRepository()
        planRepo = WorkoutPlanRepository()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    // MARK: - getAllExerciseNames

    func testGetAllExerciseNamesReturnsEmpty() throws {
        let names = try repo.getAllExerciseNames()
        XCTAssertTrue(names.isEmpty)
    }

    func testGetAllExerciseNamesFromCompletedSessions() throws {
        try createCompletedSession(exercises: [
            ("Bench Press", 225, 5),
            ("Squat", 315, 3)
        ])

        let names = try repo.getAllExerciseNames()
        XCTAssertTrue(names.contains("Bench Press"))
        XCTAssertTrue(names.contains("Squat"))
    }

    func testGetAllExerciseNamesExcludesInProgressSessions() throws {
        let plan = makePlan(exercises: [
            makePlannedExercise(name: "Deadlift", sets: [makePlannedSet(weight: 405, reps: 1)])
        ])
        try planRepo.create(plan)
        _ = try sessionRepo.createFromPlan(plan) // Not completed

        let names = try repo.getAllExerciseNames()
        XCTAssertFalse(names.contains("Deadlift"))
    }

    func testGetAllExerciseNamesReturnsDistinct() throws {
        try createCompletedSession(exercises: [("Bench Press", 225, 5)])
        try createCompletedSession(exercises: [("Bench Press", 235, 3)])

        let names = try repo.getAllExerciseNames()
        XCTAssertEqual(names.filter { $0 == "Bench Press" }.count, 1)
    }

    // MARK: - getHistory

    func testGetHistoryReturnsDataPoints() throws {
        try createCompletedSession(exercises: [("Bench Press", 225, 5)])

        let history = try repo.getHistory(forExercise: "Bench Press")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].maxWeight, 225)
        XCTAssertEqual(history[0].setsCount, 1)
    }

    func testGetHistoryReturnsEmptyForUnknownExercise() throws {
        let history = try repo.getHistory(forExercise: "Unknown Exercise")
        XCTAssertTrue(history.isEmpty)
    }

    func testGetHistoryMultipleSessions() throws {
        try createCompletedSession(exercises: [("Bench Press", 225, 5)])
        try createCompletedSession(exercises: [("Bench Press", 235, 3)])

        let history = try repo.getHistory(forExercise: "Bench Press")
        XCTAssertEqual(history.count, 2)
    }

    // MARK: - getMaxWeight

    func testGetMaxWeightReturnsHighest() throws {
        try createCompletedSession(exercises: [("Bench Press", 225, 5)])
        try createCompletedSession(exercises: [("Bench Press", 245, 3)])

        let max = try repo.getMaxWeight(forExercise: "Bench Press")
        XCTAssertNotNil(max)
        XCTAssertEqual(max?.weight, 245)
    }

    func testGetMaxWeightReturnsNilForUnknownExercise() throws {
        let max = try repo.getMaxWeight(forExercise: "Unknown")
        XCTAssertNil(max)
    }

    func testGetMaxWeightReturnsNilWhenNoCompletedSessions() throws {
        let max = try repo.getMaxWeight(forExercise: "Bench Press")
        XCTAssertNil(max)
    }

    // MARK: - Helpers

    private func createCompletedSession(exercises: [(String, Double, Int)]) throws {
        var plannedExercises: [PlannedExercise] = []
        for (i, ex) in exercises.enumerated() {
            plannedExercises.append(
                PlannedExercise(
                    workoutPlanId: "plan",
                    exerciseName: ex.0,
                    orderIndex: i,
                    sets: [PlannedSet(
                        plannedExerciseId: "ex",
                        orderIndex: 0,
                        targetWeight: ex.1,
                        targetWeightUnit: .lbs,
                        targetReps: ex.2
                    )]
                )
            )
        }
        let plan = WorkoutPlan(name: "Test", exercises: plannedExercises)
        try planRepo.create(plan)
        let (session, _) = try sessionRepo.createFromPlan(plan)

        // Complete all sets
        for exercise in session.exercises {
            for set in exercise.sets {
                try sessionRepo.updateSessionSet(
                    set.id,
                    actualWeight: set.targetWeight,
                    actualWeightUnit: .lbs,
                    actualReps: set.targetReps,
                    actualTime: nil,
                    actualRpe: nil,
                    status: .completed
                )
            }
        }
        try sessionRepo.complete(session.id)
    }

    private func makePlan(exercises: [PlannedExercise] = []) -> WorkoutPlan {
        WorkoutPlan(name: "Test", exercises: exercises)
    }

    private func makePlannedExercise(name: String, sets: [PlannedSet] = []) -> PlannedExercise {
        PlannedExercise(workoutPlanId: "plan", exerciseName: name, orderIndex: 0, sets: sets)
    }

    private func makePlannedSet(weight: Double, reps: Int) -> PlannedSet {
        PlannedSet(plannedExerciseId: "ex", orderIndex: 0, targetWeight: weight, targetWeightUnit: .lbs,
                   targetReps: reps)
    }
}

import XCTest
@testable import LiftMark

final class LiveActivityServiceTests: XCTestCase {

    private var service: LiveActivityService { LiveActivityService.shared }

    // MARK: - Singleton

    func testSharedInstanceExists() {
        XCTAssertNotNil(service)
    }

    func testSharedInstanceIsSameReference() {
        XCTAssertTrue(LiveActivityService.shared === LiveActivityService.shared)
    }

    // MARK: - isAvailable

    func testIsAvailableReturnsBoolWithoutCrashing() {
        // Should return a boolean without crashing, regardless of platform
        let result = service.isAvailable()
        // On simulator, Live Activities are typically not available
        XCTAssertNotNil(result)
    }

    // MARK: - formatWeight

    func testFormatWeightWithValueAndUnit() {
        XCTAssertEqual(service.formatWeight(135, unit: .lbs), "135 lbs")
    }

    func testFormatWeightWithKilograms() {
        XCTAssertEqual(service.formatWeight(60, unit: .kg), "60 kg")
    }

    func testFormatWeightWithNilReturnsBodyweight() {
        XCTAssertEqual(service.formatWeight(nil, unit: nil), "BW")
    }

    func testFormatWeightWithZeroReturnsBodyweight() {
        XCTAssertEqual(service.formatWeight(0, unit: .lbs), "BW")
    }

    func testFormatWeightWithNilUnitDefaultsToLbs() {
        XCTAssertEqual(service.formatWeight(100, unit: nil), "100 lbs")
    }

    // MARK: - formatReps

    func testFormatRepsWithTargetReps() {
        let set = makeSet(targetReps: 10)
        XCTAssertEqual(service.formatReps(set), "10")
    }

    func testFormatRepsWithTargetTime() {
        let set = makeSet(targetTime: 30)
        XCTAssertEqual(service.formatReps(set), "0:30")
    }

    func testFormatRepsWithNilSet() {
        XCTAssertEqual(service.formatReps(nil), "?")
    }

    func testFormatRepsWithNoRepsOrTime() {
        let set = makeSet()
        XCTAssertEqual(service.formatReps(set), "?")
    }

    func testFormatRepsPreferRepsOverTime() {
        // When both targetReps and targetTime are set, reps takes precedence
        let set = makeSet(targetReps: 8, targetTime: 60)
        XCTAssertEqual(service.formatReps(set), "8")
    }

    // MARK: - findNextExercise

    func testFindNextExerciseReturnsNextWithPendingSets() {
        let ex1 = makeExercise(name: "Bench Press", sets: [
            makeSet(status: .completed)
        ], status: .completed)
        let ex2 = makeExercise(name: "Squat", sets: [
            makeSet(status: .pending)
        ])
        let session = makeSession(exercises: [ex1, ex2])

        let next = service.findNextExercise(after: ex1, in: session)
        XCTAssertEqual(next?.exerciseName, "Squat")
    }

    func testFindNextExerciseSkipsCompletedExercises() {
        let ex1 = makeExercise(name: "Bench Press", sets: [
            makeSet(status: .completed)
        ], status: .completed)
        let ex2 = makeExercise(name: "Squat", sets: [
            makeSet(status: .completed)
        ], status: .completed)
        let ex3 = makeExercise(name: "Deadlift", sets: [
            makeSet(status: .pending)
        ])
        let session = makeSession(exercises: [ex1, ex2, ex3])

        let next = service.findNextExercise(after: ex1, in: session)
        XCTAssertEqual(next?.exerciseName, "Deadlift")
    }

    func testFindNextExerciseReturnsNilWhenNoPending() {
        let ex1 = makeExercise(name: "Bench Press", sets: [
            makeSet(status: .completed)
        ], status: .completed)
        let ex2 = makeExercise(name: "Squat", sets: [
            makeSet(status: .completed)
        ], status: .completed)
        let session = makeSession(exercises: [ex1, ex2])

        let next = service.findNextExercise(after: ex1, in: session)
        XCTAssertNil(next)
    }

    func testFindNextExerciseReturnsNilWhenLastExercise() {
        let ex1 = makeExercise(name: "Bench Press", sets: [
            makeSet(status: .pending)
        ])
        let session = makeSession(exercises: [ex1])

        let next = service.findNextExercise(after: ex1, in: session)
        XCTAssertNil(next)
    }

    func testFindNextExerciseReturnsNilForUnknownExercise() {
        let ex1 = makeExercise(name: "Bench Press", sets: [
            makeSet(status: .pending)
        ])
        let unknown = makeExercise(name: "Unknown", sets: [
            makeSet(status: .pending)
        ])
        let session = makeSession(exercises: [ex1])

        let next = service.findNextExercise(after: unknown, in: session)
        XCTAssertNil(next)
    }

    // MARK: - nextExerciseSetDetail

    func testNextExerciseSetDetailFormatsFirstPendingSet() {
        let exercise = makeExercise(name: "Squat", sets: [
            makeSet(targetWeight: 225, targetWeightUnit: .lbs, targetReps: 5, status: .pending)
        ])
        let detail = service.nextExerciseSetDetail(exercise)
        XCTAssertEqual(detail, "225 lbs \u{00D7} 5")
    }

    func testNextExerciseSetDetailSkipsCompletedSets() {
        let exercise = makeExercise(name: "Squat", sets: [
            makeSet(targetWeight: 135, targetWeightUnit: .lbs, targetReps: 10, status: .completed),
            makeSet(targetWeight: 185, targetWeightUnit: .lbs, targetReps: 8, status: .pending)
        ])
        let detail = service.nextExerciseSetDetail(exercise)
        XCTAssertEqual(detail, "185 lbs \u{00D7} 8")
    }

    func testNextExerciseSetDetailReturnsNilWhenNoPendingSets() {
        let exercise = makeExercise(name: "Squat", sets: [
            makeSet(targetWeight: 135, targetWeightUnit: .lbs, targetReps: 10, status: .completed)
        ])
        let detail = service.nextExerciseSetDetail(exercise)
        XCTAssertNil(detail)
    }

    func testNextExerciseSetDetailBodyweight() {
        let exercise = makeExercise(name: "Pull-ups", sets: [
            makeSet(targetReps: 10, status: .pending)
        ])
        let detail = service.nextExerciseSetDetail(exercise)
        XCTAssertEqual(detail, "BW \u{00D7} 10")
    }

    func testNextExerciseSetDetailWithTime() {
        let exercise = makeExercise(name: "Plank", sets: [
            makeSet(targetTime: 60, status: .pending)
        ])
        let detail = service.nextExerciseSetDetail(exercise)
        XCTAssertEqual(detail, "BW \u{00D7} 1:00")
    }

    // MARK: - resolveContentState: cursor advance on skip (#144)

    /// Mirrors ActiveWorkoutViewModel.updateLiveActivity's derivation of the
    /// current exercise/set so the tests exercise the same handoff that the app
    /// uses after a skip.
    private func currentCursor(in session: WorkoutSession) -> (exercise: SessionExercise?, setIndex: Int) {
        let current = session.exercises.first { ex in ex.sets.contains { $0.status == .pending } }
        let idx = current?.sets.firstIndex { $0.status == .pending } ?? 0
        return (current, idx)
    }

    func testResolveAdvancesToNextExerciseWhenCurrentSkipped() throws {
        guard #available(iOS 16.2, *) else { throw XCTSkip("Requires iOS 16.2") }
        // ex1's only set is skipped → cursor advances to ex2.
        let ex1 = makeExercise(name: "Bench Press", sets: [
            makeSet(targetWeight: 185, targetWeightUnit: .lbs, targetReps: 5, status: .skipped)
        ])
        let ex2 = makeExercise(name: "Squat", sets: [
            makeSet(targetWeight: 225, targetWeightUnit: .lbs, targetReps: 5, status: .pending)
        ])
        let session = makeSession(exercises: [ex1, ex2])

        let cursor = currentCursor(in: session)
        XCTAssertEqual(cursor.exercise?.exerciseName, "Squat")

        let state = service.resolveContentState(
            session: session,
            exercise: cursor.exercise,
            setIndex: cursor.setIndex,
            progress: (completed: 0, total: 2)
        )
        XCTAssertFalse(state.isRestTimer)
        XCTAssertEqual(state.exerciseName, "Squat")
        XCTAssertEqual(state.weightReps, "225 lbs \u{00D7} 5")
    }

    func testResolveAdvancesPastSkippedLastSetWithinExercise() throws {
        guard #available(iOS 16.2, *) else { throw XCTSkip("Requires iOS 16.2") }
        // First set completed, last set skipped on ex1 → advance to ex2.
        let ex1 = makeExercise(name: "Bench Press", sets: [
            makeSet(targetWeight: 135, targetWeightUnit: .lbs, targetReps: 5, status: .completed),
            makeSet(targetWeight: 155, targetWeightUnit: .lbs, targetReps: 5, status: .skipped)
        ])
        let ex2 = makeExercise(name: "Squat", sets: [
            makeSet(targetWeight: 225, targetWeightUnit: .lbs, targetReps: 5, status: .pending)
        ])
        let session = makeSession(exercises: [ex1, ex2])

        let cursor = currentCursor(in: session)
        let state = service.resolveContentState(
            session: session,
            exercise: cursor.exercise,
            setIndex: cursor.setIndex,
            progress: (completed: 1, total: 3)
        )
        XCTAssertEqual(state.exerciseName, "Squat")
    }

    func testResolveShowsFinishingStateWhenLastExerciseSkipped() throws {
        guard #available(iOS 16.2, *) else { throw XCTSkip("Requires iOS 16.2") }
        // Every set across the session is completed or skipped → finishing state.
        let ex1 = makeExercise(name: "Bench Press", sets: [
            makeSet(status: .completed)
        ], status: .completed)
        let ex2 = makeExercise(name: "Squat", sets: [
            makeSet(status: .skipped)
        ], status: .skipped)
        let session = makeSession(exercises: [ex1, ex2])

        let cursor = currentCursor(in: session)
        XCTAssertNil(cursor.exercise, "No pending sets should resolve current exercise to nil")

        let state = service.resolveContentState(
            session: session,
            exercise: cursor.exercise,
            setIndex: cursor.setIndex,
            progress: (completed: 1, total: 2)
        )
        XCTAssertEqual(state.exerciseName, LiveActivityService.completeTitle)
        XCTAssertEqual(state.weightReps, LiveActivityService.completeSubtitle)
        XCTAssertEqual(state.progress, 1.0)
        XCTAssertFalse(state.isRestTimer)
    }

    func testResolveFinishingStateMatchesEndCompletionMessage() throws {
        guard #available(iOS 16.2, *) else { throw XCTSkip("Requires iOS 16.2") }
        // The in-place finishing state must read identically to the explicit
        // end-of-workout completion message so skip-to-finish and tap-Finish
        // look the same.
        let finishing = LiveActivityService.finishingState
        XCTAssertEqual(finishing.exerciseName, "Workout Complete")
        XCTAssertEqual(finishing.weightReps, "Great job!")
        XCTAssertEqual(finishing.progress, 1.0)
    }

    // MARK: - Cleanup (Graceful in Test Environment)

    func testCleanupOrphanedActivitiesDoesNotCrash() {
        service.cleanupOrphanedActivities()
    }

    func testEndWorkoutActivityDoesNotCrash() {
        service.endWorkoutActivity()
    }

    // MARK: - Helpers

    private func makeSession(
        exercises: [SessionExercise] = []
    ) -> WorkoutSession {
        WorkoutSession(
            name: "Test Workout",
            date: "2024-06-15",
            startTime: "2024-06-15T10:00:00Z",
            endTime: "2024-06-15T11:00:00Z",
            duration: 3600,
            exercises: exercises,
            status: .completed
        )
    }

    private func makeExercise(
        name: String = "Exercise",
        sets: [SessionSet] = [],
        status: ExerciseStatus = .pending
    ) -> SessionExercise {
        SessionExercise(
            workoutSessionId: "s1",
            exerciseName: name,
            orderIndex: 0,
            sets: sets,
            status: status
        )
    }

    private func makeSet(
        targetWeight: Double? = nil,
        targetWeightUnit: WeightUnit? = nil,
        targetReps: Int? = nil,
        targetTime: Int? = nil,
        status: SetStatus = .pending
    ) -> SessionSet {
        SessionSet(
            sessionExerciseId: "e1",
            orderIndex: 0,
            targetWeight: targetWeight,
            targetWeightUnit: targetWeightUnit,
            targetReps: targetReps,
            targetTime: targetTime,
            status: status
        )
    }
}

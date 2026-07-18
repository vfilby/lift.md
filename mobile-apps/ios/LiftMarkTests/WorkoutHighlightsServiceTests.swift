import XCTest
@testable import LiftMark

final class WorkoutHighlightsServiceTests: XCTestCase {

    let service = WorkoutHighlightsService()

    // MARK: - getExerciseMaxWeight

    func testGetExerciseMaxWeightReturnsHighestCompletedSet() {
        let exercise = makeExercise(sets: [
            makeSet(actualWeight: 185, actualReps: 8, unit: .lbs, status: .completed),
            makeSet(actualWeight: 225, actualReps: 5, unit: .lbs, status: .completed),
            makeSet(actualWeight: 205, actualReps: 6, unit: .lbs, status: .completed)
        ])
        let result = service.getExerciseMaxWeight(exercise)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.weight, 225)
        XCTAssertEqual(result?.reps, 5)
        XCTAssertEqual(result?.unit, "lbs")
    }

    func testGetExerciseMaxWeightIgnoresSkippedSets() {
        let exercise = makeExercise(sets: [
            makeSet(actualWeight: 300, actualReps: 1, unit: .lbs, status: .skipped),
            makeSet(actualWeight: 185, actualReps: 8, unit: .lbs, status: .completed)
        ])
        let result = service.getExerciseMaxWeight(exercise)
        XCTAssertEqual(result?.weight, 185)
    }

    func testGetExerciseMaxWeightReturnsNilForNoCompletedSets() {
        let exercise = makeExercise(sets: [
            makeSet(actualWeight: 225, actualReps: 5, unit: .lbs, status: .skipped)
        ])
        XCTAssertNil(service.getExerciseMaxWeight(exercise))
    }

    func testGetExerciseMaxWeightReturnsNilForBodyweightExercise() {
        let exercise = makeExercise(sets: [
            makeSet(actualWeight: nil, actualReps: 20, unit: nil, status: .completed)
        ])
        XCTAssertNil(service.getExerciseMaxWeight(exercise))
    }

    func testGetExerciseMaxWeightReturnsNilForEmptySets() {
        let exercise = makeExercise(sets: [])
        XCTAssertNil(service.getExerciseMaxWeight(exercise))
    }

    func testGetExerciseMaxWeightUsesKgUnit() {
        let exercise = makeExercise(sets: [
            makeSet(actualWeight: 100, actualReps: 5, unit: .kg, status: .completed)
        ])
        let result = service.getExerciseMaxWeight(exercise)
        XCTAssertEqual(result?.unit, "kg")
    }

    // MARK: - getSessionMaxWeights

    func testGetSessionMaxWeightsReturnsMaxPerExercise() {
        let session = makeSession(exercises: [
            makeExercise(name: "Bench Press", sets: [
                makeSet(actualWeight: 185, actualReps: 8, unit: .lbs, status: .completed),
                makeSet(actualWeight: 225, actualReps: 5, unit: .lbs, status: .completed)
            ]),
            makeExercise(name: "Squat", sets: [
                makeSet(actualWeight: 315, actualReps: 3, unit: .lbs, status: .completed)
            ])
        ])
        let result = service.getSessionMaxWeights(session)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["Bench Press"]?.weight, 225)
        XCTAssertEqual(result["Back Squat"]?.weight, 315)
    }

    func testGetSessionMaxWeightsExcludesExercisesWithNoSets() {
        let session = makeSession(exercises: [
            makeExercise(name: "Bench Press", sets: []),
            makeExercise(name: "Squat", sets: [
                makeSet(actualWeight: 315, actualReps: 3, unit: .lbs, status: .completed)
            ])
        ])
        let result = service.getSessionMaxWeights(session)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result["Bench Press"])
    }

    func testGetSessionMaxWeightsReturnsEmptyForEmptySession() {
        let session = makeSession(exercises: [])
        let result = service.getSessionMaxWeights(session)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - calculateSessionVolume

    func testCalculateSessionVolumeBasic() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(actualWeight: 225, actualReps: 5, unit: .lbs, status: .completed),
                makeSet(actualWeight: 225, actualReps: 5, unit: .lbs, status: .completed)
            ])
        ])
        XCTAssertEqual(service.calculateSessionVolume(session), 2250) // 225*5 + 225*5
    }

    func testCalculateSessionVolumeIgnoresSkippedSets() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(actualWeight: 225, actualReps: 5, unit: .lbs, status: .completed),
                makeSet(actualWeight: 225, actualReps: 5, unit: .lbs, status: .skipped)
            ])
        ])
        XCTAssertEqual(service.calculateSessionVolume(session), 1125)
    }

    func testCalculateSessionVolumeIgnoresBodyweightSets() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(actualWeight: nil, actualReps: 20, unit: nil, status: .completed)
            ])
        ])
        XCTAssertEqual(service.calculateSessionVolume(session), 0)
    }

    func testCalculateSessionVolumeZeroForEmptySession() {
        let session = makeSession(exercises: [])
        XCTAssertEqual(service.calculateSessionVolume(session), 0)
    }

    func testCalculateSessionVolumeMultipleExercises() {
        let session = makeSession(exercises: [
            makeExercise(sets: [
                makeSet(actualWeight: 100, actualReps: 10, unit: .lbs, status: .completed)
            ]),
            makeExercise(sets: [
                makeSet(actualWeight: 50, actualReps: 12, unit: .lbs, status: .completed)
            ])
        ])
        XCTAssertEqual(service.calculateSessionVolume(session), 1600) // 1000 + 600
    }

    // MARK: - findLastSessionWithExercise

    func testFindLastSessionWithExerciseFindsMatch() {
        let sessions = [
            makeSession(id: "s1", exercises: [
                makeExercise(name: "Bench Press",
                             sets: [makeSet(actualWeight: 225, actualReps: 5, unit: .lbs, status: .completed)])
            ]),
            makeSession(id: "s2", exercises: [
                makeExercise(name: "Squat",
                             sets: [makeSet(actualWeight: 315, actualReps: 5, unit: .lbs, status: .completed)])
            ])
        ]
        let result = service.findLastSessionWithExercise(sessions, exerciseName: "Bench Press", excludeSessionId: "s3")
        XCTAssertEqual(result?.id, "s1")
    }

    func testFindLastSessionWithExerciseExcludesCurrentSession() {
        let sessions = [
            makeSession(id: "s1", exercises: [
                makeExercise(name: "Bench Press",
                             sets: [makeSet(actualWeight: 225, actualReps: 5, unit: .lbs, status: .completed)])
            ])
        ]
        let result = service.findLastSessionWithExercise(sessions, exerciseName: "Bench Press", excludeSessionId: "s1")
        XCTAssertNil(result)
    }

    func testFindLastSessionWithExerciseReturnsNilWhenNotFound() {
        let sessions = [
            makeSession(id: "s1", exercises: [
                makeExercise(name: "Squat",
                             sets: [makeSet(actualWeight: 315, actualReps: 5, unit: .lbs, status: .completed)])
            ])
        ]
        let result = service.findLastSessionWithExercise(sessions, exerciseName: "Bench Press", excludeSessionId: "s2")
        XCTAssertNil(result)
    }

    func testFindLastSessionWithExerciseIgnoresEmptySets() {
        let sessions = [
            makeSession(id: "s1", exercises: [
                makeExercise(name: "Bench Press", sets: [])
            ])
        ]
        let result = service.findLastSessionWithExercise(sessions, exerciseName: "Bench Press", excludeSessionId: "s2")
        XCTAssertNil(result)
    }

    // MARK: - createPRHighlight

    func testCreatePRHighlightWithPreviousWeight() {
        let pr = ExercisePR(exerciseName: "Bench Press", newWeight: 225, newReps: 5,
                            oldWeight: 215, oldReps: 5, unit: "lbs")
        let highlight = service.createPRHighlight(pr)
        XCTAssertEqual(highlight.type, .pr)
        XCTAssertEqual(highlight.title, "New PR!")
        XCTAssertTrue(highlight.message.contains("225"))
        XCTAssertTrue(highlight.message.contains("215"))
        XCTAssertTrue(highlight.message.contains("Bench Press"))
    }

    func testCreatePRHighlightFirstPR() {
        let pr = ExercisePR(exerciseName: "Squat", newWeight: 315, newReps: 5,
                            oldWeight: nil, oldReps: nil, unit: "lbs")
        let highlight = service.createPRHighlight(pr)
        XCTAssertEqual(highlight.title, "First PR!")
        XCTAssertTrue(highlight.message.contains("315"))
        XCTAssertFalse(highlight.message.contains("previous"))
    }

    // MARK: - createWeightIncreaseHighlight

    func testCreateWeightIncreaseHighlight() {
        let increase = ExercisePR(exerciseName: "OHP", newWeight: 135, newReps: 5,
                                  oldWeight: 125, oldReps: 5, unit: "lbs")
        let highlight = service.createWeightIncreaseHighlight(increase)
        XCTAssertEqual(highlight.type, .weightIncrease)
        XCTAssertTrue(highlight.message.contains("135"))
        XCTAssertTrue(highlight.message.contains("125"))
        XCTAssertTrue(highlight.message.contains("OHP"))
    }

    // MARK: - createVolumeHighlight

    func testCreateVolumeHighlight() {
        let comparison = VolumeComparison(currentVolume: 10000, previousVolume: 8000, percentageIncrease: 25)
        let highlight = service.createVolumeHighlight(comparison)
        XCTAssertEqual(highlight.type, .volumeIncrease)
        XCTAssertTrue(highlight.message.contains("25%"))
    }

    // MARK: - createStreakHighlight

    func testCreateStreakHighlightDays() {
        let highlight = service.createStreakHighlight(5)
        XCTAssertEqual(highlight.type, .streak)
        XCTAssertTrue(highlight.message.contains("5-day"))
    }

    func testCreateStreakHighlightWeeks() {
        let highlight = service.createStreakHighlight(14)
        XCTAssertTrue(highlight.message.contains("2-week"))
    }

    func testCreateStreakHighlightOneWeek() {
        let highlight = service.createStreakHighlight(7)
        XCTAssertTrue(highlight.message.contains("1-week"))
    }

    func testCreateStreakHighlightSixDays() {
        let highlight = service.createStreakHighlight(6)
        XCTAssertTrue(highlight.message.contains("6-day"))
    }

    // MARK: - Helpers

    private func makeSession(
        id: String = UUID().uuidString,
        exercises: [SessionExercise] = []
    ) -> WorkoutSession {
        WorkoutSession(
            id: id,
            name: "Test",
            date: "2024-01-15",
            exercises: exercises,
            status: .completed
        )
    }

    private func makeExercise(
        name: String = "Exercise",
        sets: [SessionSet] = []
    ) -> SessionExercise {
        SessionExercise(
            workoutSessionId: "s1",
            exerciseName: name,
            orderIndex: 0,
            sets: sets,
            status: .completed
        )
    }

    private func makeSet(
        actualWeight: Double? = nil,
        actualReps: Int? = nil,
        unit: WeightUnit? = nil,
        status: SetStatus = .completed
    ) -> SessionSet {
        SessionSet(
            sessionExerciseId: "e1",
            orderIndex: 0,
            actualWeight: actualWeight,
            actualWeightUnit: unit,
            actualReps: actualReps,
            status: status
        )
    }
}

import XCTest
@testable import LiftMark

final class WorkoutHistoryServiceTests: XCTestCase {

    let service = WorkoutHistoryService()

    // MARK: - formatSetCompact

    func testFormatSetCompactWeightAndReps() {
        let set = makeSessionSet(actualWeight: 185, actualReps: 8)
        XCTAssertEqual(service.formatSetCompact(set), "185x8")
    }

    func testFormatSetCompactBodyweightReps() {
        let set = makeSessionSet(actualReps: 10)
        XCTAssertEqual(service.formatSetCompact(set), "bwx10")
    }

    func testFormatSetCompactTimeOnly() {
        let set = makeSessionSet(actualTime: 60)
        XCTAssertEqual(service.formatSetCompact(set), "1:00")
    }

    func testFormatSetCompactFallsBackToTargetValues() {
        let set = makeSessionSet(targetWeight: 225, targetReps: 5)
        XCTAssertEqual(service.formatSetCompact(set), "225x5")
    }

    func testFormatSetCompactEmptySetReturnsEmpty() {
        let set = makeSessionSet()
        XCTAssertEqual(service.formatSetCompact(set), "")
    }

    func testFormatSetCompactTimeWithRepsUsesReps() {
        // If both time and reps exist, reps take priority
        let set = makeSessionSet(actualReps: 15, actualTime: 30)
        XCTAssertEqual(service.formatSetCompact(set), "bwx15")
    }

    func testFormatSetCompactZeroWeightTreatedAsBodyweight() {
        let set = makeSessionSet(actualWeight: 0, actualReps: 12)
        XCTAssertEqual(service.formatSetCompact(set), "bwx12")
    }

    // MARK: - formatExerciseCompact

    func testFormatExerciseCompactWithCompletedSets() {
        let exercise = makeSessionExercise(
            name: "Bench Press",
            sets: [
                makeSessionSet(actualWeight: 185, actualReps: 8, status: .completed),
                makeSessionSet(actualWeight: 205, actualReps: 5, status: .completed)
            ]
        )
        XCTAssertEqual(service.formatExerciseCompact(exercise), "Bench 185x8,205x5")
    }

    func testFormatExerciseCompactFiltersOutNonCompletedSets() {
        let exercise = makeSessionExercise(
            name: "Bench Press",
            sets: [
                makeSessionSet(actualWeight: 185, actualReps: 8, status: .completed),
                makeSessionSet(actualWeight: 205, actualReps: 5, status: .skipped),
                makeSessionSet(actualWeight: 225, actualReps: 3, status: .completed)
            ]
        )
        XCTAssertEqual(service.formatExerciseCompact(exercise), "Bench 185x8,225x3")
    }

    func testFormatExerciseCompactAllSkippedReturnsEmpty() {
        let exercise = makeSessionExercise(
            name: "Squat",
            sets: [
                makeSessionSet(actualWeight: 225, actualReps: 5, status: .skipped)
            ]
        )
        XCTAssertEqual(service.formatExerciseCompact(exercise), "")
    }

    func testFormatExerciseCompactNoSetsReturnsEmpty() {
        let exercise = makeSessionExercise(name: "Squat", sets: [])
        XCTAssertEqual(service.formatExerciseCompact(exercise), "")
    }

    func testFormatExerciseCompactUsesAbbreviatedName() {
        let exercise = makeSessionExercise(
            name: "Overhead Press",
            sets: [makeSessionSet(actualWeight: 135, actualReps: 5, status: .completed)]
        )
        XCTAssertEqual(service.formatExerciseCompact(exercise), "OHP 135x5")
    }

    // MARK: - abbreviateExerciseName

    func testAbbreviateKnownExercises() {
        XCTAssertEqual(service.abbreviateExerciseName("Bench Press"), "Bench")
        XCTAssertEqual(service.abbreviateExerciseName("bench press"), "Bench")
        XCTAssertEqual(service.abbreviateExerciseName("Overhead Press"), "OHP")
        XCTAssertEqual(service.abbreviateExerciseName("Military Press"), "OHP")
        XCTAssertEqual(service.abbreviateExerciseName("Deadlift"), "DL")
        XCTAssertEqual(service.abbreviateExerciseName("Romanian Deadlift"), "RDL")
        XCTAssertEqual(service.abbreviateExerciseName("Lat Pulldown"), "Pulldown")
        XCTAssertEqual(service.abbreviateExerciseName("Pull-ups"), "Pullups")
        XCTAssertEqual(service.abbreviateExerciseName("Bicep Curls"), "Curls")
        XCTAssertEqual(service.abbreviateExerciseName("Lateral Raises"), "Lat Raise")
        XCTAssertEqual(service.abbreviateExerciseName("Back Squat"), "Squat")
        XCTAssertEqual(service.abbreviateExerciseName("Front Squat"), "Fr Squat")
    }

    func testAbbreviateUnknownExerciseReturnsCanonicalOrOriginal() {
        // Known aliases get normalized to canonical name
        XCTAssertEqual(service.abbreviateExerciseName("Bulgarian Split Squats"), "Bulgarian Split Squat")
        XCTAssertEqual(service.abbreviateExerciseName("Hip Thrusts"), "Hip Thrust")
        // Truly unknown exercises return original
        XCTAssertEqual(service.abbreviateExerciseName("Zercher Squat"), "Zercher Squat")
    }

    func testAbbreviateCaseInsensitive() {
        XCTAssertEqual(service.abbreviateExerciseName("BENCH PRESS"), "Bench")
        XCTAssertEqual(service.abbreviateExerciseName("DeAdLiFt"), "DL")
    }

    // MARK: - formatSessionCompact

    func testFormatSessionCompactBasicSession() {
        let session = makeSession(
            name: "Push Day",
            date: "2024-01-15T10:30:00Z",
            exercises: [
                makeSessionExercise(
                    name: "Bench Press",
                    sets: [
                        makeSessionSet(actualWeight: 185, actualReps: 8, status: .completed),
                        makeSessionSet(actualWeight: 205, actualReps: 5, status: .completed)
                    ]
                ),
                makeSessionExercise(
                    name: "Overhead Press",
                    sets: [
                        makeSessionSet(actualWeight: 95, actualReps: 10, status: .completed)
                    ]
                )
            ]
        )

        let result = service.formatSessionCompact(session)
        XCTAssertEqual(result, "2024-01-15 Push Day: Bench 185x8,205x5; OHP 95x10")
    }

    func testFormatSessionCompactExcludesEmptyExercises() {
        let session = makeSession(
            name: "Leg Day",
            date: "2024-01-15",
            exercises: [
                makeSessionExercise(
                    name: "Squat",
                    sets: [makeSessionSet(actualWeight: 225, actualReps: 5, status: .completed)]
                ),
                makeSessionExercise(name: "Empty Exercise", sets: [])
            ]
        )

        let result = service.formatSessionCompact(session)
        XCTAssertTrue(result.contains("Squat 225x5"))
        XCTAssertFalse(result.contains("Empty Exercise"))
    }

    // MARK: - formatProgression

    func testFormatProgressionEmptyWhenNoSessions() {
        XCTAssertEqual(service.formatProgression(sessions: []), "")
    }

    func testFormatProgressionPrefersCompounds() {
        // 3 compound, 3 isolation. Top 2 should both be compound.
        let sessions: [WorkoutSession] = [
            makeSession(exercises: [
                makeSessionExercise(name: "Bench Press", sets: [
                    makeSessionSet(actualWeight: 185, actualReps: 5, status: .completed)
                ]),
                makeSessionExercise(name: "Bicep Curl", sets: [
                    makeSessionSet(actualWeight: 35, actualReps: 10, status: .completed)
                ])
            ]),
            makeSession(exercises: [
                makeSessionExercise(name: "Back Squat", sets: [
                    makeSessionSet(actualWeight: 225, actualReps: 5, status: .completed)
                ]),
                makeSessionExercise(name: "Bicep Curl", sets: [
                    makeSessionSet(actualWeight: 40, actualReps: 10, status: .completed)
                ])
            ])
        ]
        let output = service.formatProgression(sessions: sessions, topN: 2)
        XCTAssertTrue(output.contains("Bench"))
        XCTAssertTrue(output.contains("Squat"))
        XCTAssertFalse(output.contains("Curls"))
    }

    func testFormatProgressionPadsWithNonCompoundsWhenShort() {
        // Only 1 compound, topN=3 → pads with 2 isolations.
        let sessions: [WorkoutSession] = [
            makeSession(exercises: [
                makeSessionExercise(name: "Bench Press", sets: [
                    makeSessionSet(actualWeight: 185, actualReps: 5, status: .completed)
                ]),
                makeSessionExercise(name: "Bicep Curl", sets: [
                    makeSessionSet(actualWeight: 35, actualReps: 10, status: .completed)
                ]),
                makeSessionExercise(name: "Lateral Raise", sets: [
                    makeSessionSet(actualWeight: 15, actualReps: 12, status: .completed)
                ])
            ])
        ]
        let output = service.formatProgression(sessions: sessions, topN: 3)
        XCTAssertTrue(output.contains("Bench"))
        XCTAssertTrue(output.contains("Curls"))
        XCTAssertTrue(output.contains("Lat Raise"))
    }

    func testFormatProgressionEmitsOldestToNewestTrajectory() {
        // Session 1 (oldest entered first in list → but repository returns newest first;
        // we honor that convention: sessions[0] is most recent).
        let sessions: [WorkoutSession] = [
            makeSession(exercises: [
                makeSessionExercise(name: "Bench Press", sets: [
                    makeSessionSet(actualWeight: 205, actualReps: 5, status: .completed)
                ])
            ]),
            makeSession(exercises: [
                makeSessionExercise(name: "Bench Press", sets: [
                    makeSessionSet(actualWeight: 195, actualReps: 5, status: .completed)
                ])
            ]),
            makeSession(exercises: [
                makeSessionExercise(name: "Bench Press", sets: [
                    makeSessionSet(actualWeight: 185, actualReps: 5, status: .completed)
                ])
            ])
        ]
        let output = service.formatProgression(sessions: sessions, topN: 1)
        XCTAssertTrue(output.contains("185x5→195x5→205x5"))
    }

    func testFormatProgressionSkipsSessionsWithoutCompletedSets() {
        let sessions: [WorkoutSession] = [
            makeSession(exercises: [
                makeSessionExercise(name: "Bench Press", sets: [
                    makeSessionSet(actualWeight: 185, actualReps: 5, status: .skipped)
                ])
            ])
        ]
        XCTAssertEqual(service.formatProgression(sessions: sessions), "")
    }

    // MARK: - Helpers

    private func makeSession(
        name: String = "Test Workout",
        date: String = "2024-01-15",
        exercises: [SessionExercise] = []
    ) -> WorkoutSession {
        WorkoutSession(
            id: UUID().uuidString,
            name: name,
            date: date,
            exercises: exercises,
            status: .completed
        )
    }

    private func makeSessionExercise(
        name: String = "Exercise",
        sets: [SessionSet] = []
    ) -> SessionExercise {
        SessionExercise(
            workoutSessionId: "session-1",
            exerciseName: name,
            orderIndex: 0,
            sets: sets,
            status: .completed
        )
    }

    private func makeSessionSet(
        targetWeight: Double? = nil,
        targetReps: Int? = nil,
        targetTime: Int? = nil,
        actualWeight: Double? = nil,
        actualReps: Int? = nil,
        actualTime: Int? = nil,
        status: SetStatus = .pending
    ) -> SessionSet {
        SessionSet(
            sessionExerciseId: "exercise-1",
            orderIndex: 0,
            targetWeight: targetWeight,
            targetReps: targetReps,
            targetTime: targetTime,
            actualWeight: actualWeight,
            actualReps: actualReps,
            actualTime: actualTime,
            status: status
        )
    }
}

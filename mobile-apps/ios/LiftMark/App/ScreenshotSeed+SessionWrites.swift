#if DEBUG
import Foundation
import GRDB

// MARK: - Session writes

extension ScreenshotSeed {

    /// Timestamp bundle for one seeded session: its calendar date plus
    /// ISO 8601 start/end instants.
    struct SessionTiming {
        let date: String
        let start: String
        let end: String
    }

    static func writeCompletedSession(
        plan: WorkoutPlan,
        timing: SessionTiming,
        weeksFromLatest: Int,
        in dbQueue: DatabaseQueue
    ) throws {
        try dbQueue.write { db in
            let sessionId = IDGenerator.generate()
            let duration = Int(ISO8601DateFormatter().date(from: timing.end)!
                .timeIntervalSince(ISO8601DateFormatter().date(from: timing.start)!))

            try WorkoutSessionRow(
                id: sessionId,
                workoutTemplateId: plan.id,
                name: plan.name,
                date: timing.date,
                startTime: timing.start,
                endTime: timing.end,
                duration: duration,
                notes: nil,
                status: SessionStatus.completed.rawValue,
                updatedAt: timing.end
            ).insert(db)

            // Map plan exercise IDs → session exercise IDs so parent links survive.
            var planToSession: [String: String] = [:]
            for exercise in plan.exercises {
                planToSession[exercise.id] = IDGenerator.generate()
            }

            for exercise in plan.exercises {
                guard let sessionExerciseId = planToSession[exercise.id] else { continue }
                let parentId = exercise.parentExerciseId.flatMap { planToSession[$0] }
                try SessionExerciseRow(
                    id: sessionExerciseId,
                    workoutSessionId: sessionId,
                    exerciseName: exercise.exerciseName,
                    orderIndex: exercise.orderIndex,
                    notes: exercise.notes,
                    equipmentType: exercise.equipmentType,
                    groupType: exercise.groupType?.rawValue,
                    groupName: exercise.groupName,
                    parentExerciseId: parentId,
                    status: ExerciseStatus.completed.rawValue,
                    updatedAt: timing.end
                ).insert(db)

                try insertCompletedSets(
                    for: exercise,
                    sessionExerciseId: sessionExerciseId,
                    weeksFromLatest: weeksFromLatest,
                    completedAt: timing.end,
                    in: db
                )
            }
        }
    }

    private static func insertCompletedSets(
        for exercise: PlannedExercise,
        sessionExerciseId: String,
        weeksFromLatest: Int,
        completedAt: String,
        in db: Database
    ) throws {
        for (index, set) in exercise.sets.enumerated() {
            let setId = IDGenerator.generate()
            try SessionSetRow(
                id: setId,
                sessionExerciseId: sessionExerciseId,
                orderIndex: index,
                restSeconds: set.restSeconds,
                completedAt: completedAt,
                status: SetStatus.completed.rawValue,
                notes: nil,
                isDropset: set.isDropset ? 1 : 0,
                isPerSide: set.isPerSide ? 1 : 0,
                isAmrap: set.isAmrap ? 1 : 0,
                side: nil,
                updatedAt: completedAt
            ).insert(db)

            for entry in set.entries {
                if let target = entry.target {
                    for row in target.toMeasurementRows(
                        setId: setId, parentType: "session", role: "target",
                        groupIndex: entry.groupIndex, now: completedAt
                    ) {
                        try row.insert(db)
                    }
                }
                let actual = actualValues(
                    forExercise: exercise.exerciseName,
                    target: entry.target,
                    weeksFromLatest: weeksFromLatest
                )
                for row in actual.toMeasurementRows(
                    setId: setId, parentType: "session", role: "actual",
                    groupIndex: entry.groupIndex, now: completedAt
                ) {
                    try row.insert(db)
                }
            }
        }
    }

    /// Build "actual" values that match the planned target plus a small,
    /// exercise-specific weight regression so older sessions lifted slightly
    /// less. The latest session matches the plan exactly; each prior week
    /// removes a per-exercise increment from the working weights.
    private static func actualValues(
        forExercise name: String,
        target: EntryValues?,
        weeksFromLatest: Int
    ) -> EntryValues {
        guard let target = target else { return EntryValues() }
        var actual = target
        let bump = -Double(weeksFromLatest) * weeklyIncrement(forExercise: name)
        if let weight = actual.weight, bump != 0 {
            let progressed = max(weight.value + bump, weight.value * 0.6)
            actual.weight = MeasuredWeight(value: progressed.rounded(), unit: weight.unit)
        }
        return actual
    }

    /// Per-exercise per-week progression. Compound lifts get bigger jumps,
    /// accessories smaller, isolation work effectively flat. Anything not
    /// listed here progresses at 0 (timed/bodyweight/stretches).
    private static let weeklyIncrements: [String: Double] = [
        "Barbell Bench Press": 5,
        "Overhead Press": 2.5,
        "Barbell Row": 5,
        "Conventional Deadlift": 10,
        "Barbell Back Squat": 10,
        "Romanian Deadlift": 5,
        "Leg Press": 15,
        "Incline Dumbbell Press": 2.5,
        "Lat Pulldown": 5,
        "Cable Tricep Pushdown": 2.5,
        "Dumbbell Bicep Curl": 2.5,
        "Bulgarian Split Squat": 2.5
    ]

    private static func weeklyIncrement(forExercise name: String) -> Double {
        weeklyIncrements[name] ?? 0
    }
}
#endif

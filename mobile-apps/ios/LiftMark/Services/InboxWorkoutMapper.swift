import Foundation

// MARK: - Wire Types

/// Server-side WorkoutPlan as emitted by the validator's parser. Mirrors
/// `validator/src/parser/types.ts:WorkoutPlan` field-for-field (camelCase on
/// the wire — APIClient's snake_case strategy still works because none of
/// these field names contain underscores).
///
/// This is decoded from the `workout` field of `GET /v1/workouts/:inbox_id`
/// and translated into the app's `WorkoutPlan` model by `InboxWorkoutMapper`.
struct InboxWorkout: Codable {
    let name: String
    let description: String?
    let tags: [String]?
    let defaultWeightUnit: String?
    let exercises: [InboxExercise]
}

struct InboxExercise: Codable {
    let exerciseName: String
    let orderIndex: Int?
    let notes: String?
    let equipmentType: String?
    let groupType: String?
    let groupName: String?
    let parentExerciseId: String?
    let sets: [InboxSet]
}

struct InboxSet: Codable {
    let orderIndex: Int?
    let targetWeight: Double?
    let targetWeightUnit: String?
    let targetReps: Int?
    let targetTime: Int?
    let targetDistance: Double?
    let targetDistanceUnit: String?
    let targetRpe: Int?
    let restSeconds: Int?
    let tempo: String?
    let isDropset: Bool?
    let isPerSide: Bool?
    let isAmrap: Bool?
    let notes: String?
}

// MARK: - InboxWorkoutMapper

/// Translates a server-side `InboxWorkout` into the app's `WorkoutPlan` model.
///
/// IDs are regenerated on the client: the server's `id` is a parser-local
/// UUID, but the app's WorkoutPlan/exercise/set IDs need to be fresh so the
/// new rows don't collide with anything already in the local DB or sync
/// graph.
///
/// Field-level mismatches are dropped gracefully — we'd rather save a
/// partially-mapped workout than reject the whole import for one weird set.
enum InboxWorkoutMapper {
    static func toWorkoutPlan(_ inbox: InboxWorkout) -> WorkoutPlan {
        let planId = UUID().uuidString
        let nowISO = ISO8601DateFormatter().string(from: Date())

        let defaultUnit = inbox.defaultWeightUnit.flatMap { WeightUnit(rawValue: $0) }

        let exercises: [PlannedExercise] = inbox.exercises.enumerated().map { offset, inboxEx in
            mapExercise(inboxEx, planId: planId, fallbackOrder: offset, defaultUnit: defaultUnit)
        }

        return WorkoutPlan(
            id: planId,
            name: inbox.name,
            description: inbox.description,
            tags: inbox.tags ?? [],
            defaultWeightUnit: defaultUnit,
            sourceMarkdown: nil,
            createdAt: nowISO,
            updatedAt: nowISO,
            isFavorite: false,
            exercises: exercises
        )
    }

    // MARK: - Private

    private static func mapExercise(
        _ inboxEx: InboxExercise,
        planId: String,
        fallbackOrder: Int,
        defaultUnit: WeightUnit?
    ) -> PlannedExercise {
        let exerciseId = UUID().uuidString
        let groupType = inboxEx.groupType.flatMap { GroupType(rawValue: $0) }
        if inboxEx.groupType != nil, groupType == nil {
            Logger.shared.warn(
                .network,
                "Unknown groupType in inbox workout — dropped",
                metadata: ["groupType": inboxEx.groupType ?? ""]
            )
        }

        let sets: [PlannedSet] = inboxEx.sets.enumerated().map { offset, inboxSet in
            mapSet(
                inboxSet,
                exerciseId: exerciseId,
                fallbackOrder: offset,
                defaultUnit: defaultUnit
            )
        }

        return PlannedExercise(
            id: exerciseId,
            workoutPlanId: planId,
            exerciseName: inboxEx.exerciseName,
            orderIndex: inboxEx.orderIndex ?? fallbackOrder,
            notes: inboxEx.notes,
            equipmentType: inboxEx.equipmentType,
            groupType: groupType,
            groupName: inboxEx.groupName,
            // parentExerciseId is intentionally not propagated: it refers to
            // the server's parser-local exercise UUID, which doesn't exist
            // in our regenerated graph. Group membership is preserved via
            // groupType/groupName, which is what the rest of the app uses.
            parentExerciseId: nil,
            sets: sets
        )
    }

    private static func mapSet(
        _ inboxSet: InboxSet,
        exerciseId: String,
        fallbackOrder: Int,
        defaultUnit: WeightUnit?
    ) -> PlannedSet {
        let weightUnit = inboxSet.targetWeightUnit.flatMap { WeightUnit(rawValue: $0) } ?? defaultUnit
        let distanceUnit = inboxSet.targetDistanceUnit.flatMap { DistanceUnit(rawValue: $0) }

        return PlannedSet(
            id: UUID().uuidString,
            plannedExerciseId: exerciseId,
            orderIndex: inboxSet.orderIndex ?? fallbackOrder,
            targetWeight: inboxSet.targetWeight,
            targetWeightUnit: weightUnit,
            targetReps: inboxSet.targetReps,
            targetTime: inboxSet.targetTime,
            targetDistance: inboxSet.targetDistance,
            targetDistanceUnit: distanceUnit,
            targetRpe: inboxSet.targetRpe,
            restSeconds: inboxSet.restSeconds,
            tempo: inboxSet.tempo,
            isDropset: inboxSet.isDropset ?? false,
            isPerSide: inboxSet.isPerSide ?? false,
            isAmrap: inboxSet.isAmrap ?? false,
            notes: inboxSet.notes
        )
    }
}

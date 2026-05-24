import Foundation

/// Device-local representation of a workout pushed to this user from
/// outside the app (e.g., Claude Code via PAT). See
/// `spec/services/workout-inbox.md`.
///
/// Items live here until the user discards them or promotes them to a
/// `WorkoutPlan` via the Inbox section on the Plans screen.
struct InboxItem: Identifiable, Hashable {
    /// Server ULID. Stable across re-polls — upsert key.
    let id: String
    let fetchedAt: Date
    let createdAtServer: Date
    let sourceTokenId: String?
    let lmwfText: String
    /// Full parsed `InboxWorkout` JSON, ready to feed into
    /// `InboxWorkoutMapper.toWorkoutPlan` on promote.
    let workoutJSON: String
    let summaryName: String
    let summaryExerciseCount: Int
    let summarySetCount: Int
}

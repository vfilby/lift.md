import Foundation

#if os(iOS)
import ActivityKit
// WorkoutActivityAttributes is defined in Shared/WorkoutActivityAttributes.swift
// and included in both the main app and LiveWorkouts widget extension targets.
#endif

// MARK: - LiveActivityService

final class LiveActivityService: @unchecked Sendable {
    static let shared = LiveActivityService()

    #if os(iOS)
    @available(iOS 16.2, *)
    private var currentActivity: Activity<WorkoutActivityAttributes>?
    #endif

    private var lastUpdateTime: Date?
    private static let updateThrottleInterval: TimeInterval = 1.0

    /// Default title/subtitle shown when a workout is complete. Shared by the
    /// in-place finishing state (skip-to-finish) and the dismissal message in
    /// `endWorkoutActivity` so both paths read identically.
    static let completeTitle = "Workout Complete"
    static let completeSubtitle = "Great job!"

    #if os(iOS)
    /// Content state shown when no exercise has pending sets remaining — every
    /// set is completed or skipped. Visually matches the completion message but
    /// keeps the activity alive (it is dismissed only by `endWorkoutActivity`).
    @available(iOS 16.2, *)
    static var finishingState: WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            isRestTimer: false,
            exerciseName: completeTitle,
            setInfo: "",
            weightReps: completeSubtitle,
            progress: 1.0
        )
    }
    #endif

    private init() {}

    // MARK: - Availability

    /// Check if Live Activities are available (iOS 16.2+).
    func isAvailable() -> Bool {
        #if os(iOS)
        if #available(iOS 16.2, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    // MARK: - Start

    /// Start a Live Activity for a workout session.
    /// Awaits cleanup of any existing or orphaned activities before creating a new one.
    func startWorkoutActivity(
        session: WorkoutSession,
        exercise: SessionExercise?,
        setIndex: Int,
        progress: (completed: Int, total: Int)
    ) {
        #if os(iOS)
        guard isAvailable() else { return }

        if #available(iOS 16.2, *) {
            Task {
                // End any existing tracked activity first (awaited)
                await endWorkoutActivityAsync()

                // Clean up any orphaned activities not tracked by currentActivity
                await cleanupOrphanedActivitiesInternal()

                do {
                    let state: WorkoutActivityAttributes.ContentState
                    if let exercise {
                        state = buildActiveSetState(
                            session: session, exercise: exercise, setIndex: setIndex, progress: progress)
                    } else {
                        state = WorkoutActivityAttributes.ContentState(
                            isRestTimer: false,
                            exerciseName: session.name,
                            setInfo: "",
                            weightReps: "Starting workout...",
                            progress: 0
                        )
                    }

                    let attributes = WorkoutActivityAttributes(workoutName: session.name)
                    let content = ActivityContent(state: state, staleDate: nil)

                    let activity = try Activity.request(
                        attributes: attributes,
                        content: content,
                        pushType: nil
                    )
                    currentActivity = activity
                } catch {
                    // Silently fail — Live Activities are optional
                }
            }
        }
        #endif
    }

    // MARK: - Update

    /// Update the Live Activity with current workout state.
    func updateWorkoutActivity(
        session: WorkoutSession,
        exercise: SessionExercise?,
        setIndex: Int,
        progress: (completed: Int, total: Int),
        restTimer: (remainingSeconds: Int, nextExercise: SessionExercise?)? = nil
    ) {
        #if os(iOS)
        guard isAvailable() else { return }

        if #available(iOS 16.2, *) {
            guard let activity = currentActivity else { return }

            // A nil exercise with no active rest timer means every set is now
            // completed or skipped — the workout is effectively done. This
            // transition into the finishing state (e.g. after skipping the last
            // pending set) must NOT be dropped by the throttle, or the activity
            // would stay stuck on the just-skipped exercise (#144).
            let isFinishingTransition = (restTimer == nil || restTimer?.remainingSeconds == 0) && exercise == nil

            // Throttle ordinary content refreshes; always let the finishing
            // transition through.
            if !isFinishingTransition,
               let lastUpdate = lastUpdateTime,
               Date().timeIntervalSince(lastUpdate) < Self.updateThrottleInterval {
                return
            }
            lastUpdateTime = Date()

            let state = resolveContentState(
                session: session,
                exercise: exercise,
                setIndex: setIndex,
                progress: progress,
                restTimer: restTimer
            )

            let content = ActivityContent(state: state, staleDate: nil)
            Task {
                await activity.update(content)
            }
        }
        #endif
    }

    #if os(iOS)
    /// Pure resolution of which content state to display for the given inputs.
    /// Extracted so the cursor-advance / finishing-state logic (#144) is
    /// testable without a live `Activity` instance.
    @available(iOS 16.2, *)
    func resolveContentState(
        session: WorkoutSession,
        exercise: SessionExercise?,
        setIndex: Int,
        progress: (completed: Int, total: Int),
        restTimer: (remainingSeconds: Int, nextExercise: SessionExercise?)? = nil
    ) -> WorkoutActivityAttributes.ContentState {
        if let restTimer, restTimer.remainingSeconds > 0 {
            return buildRestState(
                session: session,
                remainingSeconds: restTimer.remainingSeconds,
                nextExercise: restTimer.nextExercise,
                progress: progress
            )
        } else if let exercise {
            return buildActiveSetState(session: session, exercise: exercise, setIndex: setIndex, progress: progress)
        } else {
            // No exercise has pending sets remaining: show the finishing
            // state (kept alive — the activity is only dismissed by
            // endWorkoutActivity when the user formally finishes).
            return Self.finishingState
        }
    }
    #endif

    // MARK: - End

    /// End the Live Activity with an optional completion message.
    /// Uses `.immediate` dismissal for discards/pauses and `.default` for completions.
    func endWorkoutActivity(message: String? = nil, subtitle: String? = nil, immediate: Bool = false) {
        #if os(iOS)
        guard isAvailable() else { return }

        if #available(iOS 16.2, *) {
            guard let activity = currentActivity else { return }

            let finalState = WorkoutActivityAttributes.ContentState(
                isRestTimer: false,
                exerciseName: message ?? Self.completeTitle,
                setInfo: "",
                weightReps: subtitle ?? Self.completeSubtitle,
                progress: 1.0
            )

            let content = ActivityContent(state: finalState, staleDate: nil)
            let dismissalPolicy: ActivityUIDismissalPolicy = immediate ? .immediate : .default
            let activityToEnd = activity
            currentActivity = nil

            Task {
                await activityToEnd.end(content, dismissalPolicy: dismissalPolicy)
            }
        }
        #endif
    }

    /// Internal async version of endWorkoutActivity that awaits the end call.
    /// Used by startWorkoutActivity to ensure proper serialization.
    #if os(iOS)
    @available(iOS 16.2, *)
    private func endWorkoutActivityAsync() async {
        guard let activity = currentActivity else { return }

        let finalState = WorkoutActivityAttributes.ContentState(
            isRestTimer: false,
            exerciseName: "Workout Complete",
            setInfo: "",
            weightReps: "",
            progress: 1.0
        )

        let content = ActivityContent(state: finalState, staleDate: nil)
        currentActivity = nil
        await activity.end(content, dismissalPolicy: .immediate)
    }

    /// Clean up any orphaned activities not tracked by currentActivity.
    @available(iOS 16.2, *)
    private func cleanupOrphanedActivitiesInternal() async {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            let finalState = WorkoutActivityAttributes.ContentState(
                isRestTimer: false,
                exerciseName: "",
                setInfo: "",
                weightReps: "",
                progress: 0
            )
            let content = ActivityContent(state: finalState, staleDate: nil)
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }
    #endif

    /// Clean up any orphaned Live Activities on app launch.
    func cleanupOrphanedActivities() {
        #if os(iOS)
        if #available(iOS 16.2, *) {
            Task {
                await cleanupOrphanedActivitiesInternal()
            }
        }
        #endif
    }

    // MARK: - Display State Builders

    #if os(iOS)
    @available(iOS 16.2, *)
    private func buildActiveSetState(
        session: WorkoutSession,
        exercise: SessionExercise,
        setIndex: Int,
        progress: (completed: Int, total: Int)
    ) -> WorkoutActivityAttributes.ContentState {
        let set = exercise.sets.indices.contains(setIndex) ? exercise.sets[setIndex] : nil
        let setNumber = setIndex + 1
        let totalSets = exercise.sets.count

        let target = set?.entries.first?.target
        let weight = formatWeight(target?.weight?.value, unit: target?.weight?.unit)
        let reps = formatReps(set)

        let progressValue = progress.total > 0 ? Double(progress.completed) / Double(progress.total) : 0

        // Find the next exercise (first exercise after current with pending sets)
        let nextExercise = findNextExercise(after: exercise, in: session)
        let nextSetDetail = nextExercise.flatMap { nextExerciseSetDetail($0) }

        return WorkoutActivityAttributes.ContentState(
            isRestTimer: false,
            exerciseName: exercise.exerciseName,
            setInfo: "Set \(setNumber)/\(totalSets)",
            weightReps: "\(weight) \u{00D7} \(reps)",
            nextExerciseName: nextExercise?.exerciseName,
            nextSetDetail: nextSetDetail,
            progress: progressValue
        )
    }

    @available(iOS 16.2, *)
    private func buildRestState(
        session: WorkoutSession,
        remainingSeconds: Int,
        nextExercise: SessionExercise?,
        progress: (completed: Int, total: Int)
    ) -> WorkoutActivityAttributes.ContentState {
        let progressValue = progress.total > 0 ? Double(progress.completed) / Double(progress.total) : 0
        let timerEnd = Date().addingTimeInterval(TimeInterval(remainingSeconds))

        // For rest state, the "next exercise" is the one with the next pending set
        let nextSetDetail = nextExercise.flatMap { nextExerciseSetDetail($0) }

        return WorkoutActivityAttributes.ContentState(
            isRestTimer: true,
            exerciseName: "Rest",
            setInfo: "",
            weightReps: "",
            nextExerciseName: nextExercise?.exerciseName,
            nextSetDetail: nextSetDetail,
            progress: progressValue,
            timerEndDate: timerEnd
        )
    }
    #endif

    /// Find the next exercise after the current one that has pending sets.
    func findNextExercise(after current: SessionExercise, in session: WorkoutSession) -> SessionExercise? {
        guard let currentIndex = session.exercises.firstIndex(where: { $0.id == current.id }) else { return nil }
        // Look for exercises after the current one with pending sets
        for i in (currentIndex + 1)..<session.exercises.count {
            let ex = session.exercises[i]
            if ex.sets.contains(where: { $0.status == .pending }) {
                return ex
            }
        }
        return nil
    }

    /// Format the first pending set of an exercise as "weight × reps".
    func nextExerciseSetDetail(_ exercise: SessionExercise) -> String? {
        guard let set = exercise.sets.first(where: { $0.status == .pending }) else { return nil }
        let target = set.entries.first?.target
        let weight = formatWeight(target?.weight?.value, unit: target?.weight?.unit)
        let reps = formatReps(set)
        return "\(weight) \u{00D7} \(reps)"
    }

    func formatWeight(_ weight: Double?, unit: WeightUnit?) -> String {
        guard let weight, weight > 0 else { return "BW" }
        return "\(Int(weight)) \(unit?.rawValue ?? "lbs")"
    }

    func formatReps(_ set: SessionSet?) -> String {
        guard let set else { return "?" }
        let target = set.entries.first?.target
        if let reps = target?.reps {
            return String(reps)
        } else if let time = target?.time {
            return DurationFormat.mmss(time)
        }
        return "?"
    }
}

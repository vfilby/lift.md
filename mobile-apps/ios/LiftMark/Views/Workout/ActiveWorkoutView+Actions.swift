import SwiftUI

/// Set/workout mutation actions for `ActiveWorkoutView`, split out so the
/// main view stays within SwiftLint's file/type-length limits.
extension ActiveWorkoutView {
    // MARK: - Actions

    func finishWorkout() {
        ActiveWorkoutViewModel.endLiveActivity(settings: settingsStore.settings, message: "Workout Complete")
        // Snapshot the in-memory session and stamp end_time/duration locally — the
        // repository writes those on complete(), but we don't round-trip the result
        // back to the in-memory copy, so the summary needs them computed here.
        var completedSession = sessionStore.activeSession
        if var snap = completedSession {
            let nowDate = Date()
            let nowIso = ISO8601DateFormatter().string(from: nowDate)
            snap.endTime = nowIso
            // Tolerant parse: a session resumed from another device carries a
            // fractional-second startTime that a bare ISO8601DateFormatter rejects.
            if let start = ISO8601.parse(snap.startTime) {
                snap.duration = Int(nowDate.timeIntervalSince(start))
            }
            snap.status = .completed
            completedSession = snap
        }
        completedSessionForSummary = completedSession
        sessionStore.completeSession()
        navigateToSummary = true
        ActiveWorkoutViewModel.saveToHealthKitIfEnabled(completedSession, settings: settingsStore.settings)
    }

    func completeSet(
        exerciseIndex: Int, setIndex: Int,
        userWeight: Double? = nil, userReps: Int? = nil, elapsedTime: Int? = nil
    ) {
        guard let set = prepareSetInteraction(exerciseIndex: exerciseIndex, setIndex: setIndex) else { return }

        // Persist with actual values — prefer user-edited, then existing actual, then target
        let target = set.entries.first?.target
        let actual = set.entries.first?.actual
        sessionStore.completeSet(
            setId: set.id,
            actualWeight: userWeight ?? actual?.weight?.value ?? target?.weight?.value,
            // Fall back to the user's default unit so a weight added to a
            // previously reps-only set (GH #194) is logged in their unit.
            actualWeightUnit: actual?.weight?.unit ?? target?.weight?.unit ?? settingsStore.settings?.defaultWeightUnit,
            actualReps: userReps ?? actual?.reps ?? target?.reps,
            actualTime: elapsedTime ?? actual?.time ?? target?.time,
            actualRpe: actual?.rpe ?? target?.rpe
        )

        startRestTimerOrRefreshActivity(after: set)
    }

    func completeDropSet(
        exerciseIndex: Int, setIndex: Int,
        entries: [(weight: Double?, weightUnit: WeightUnit?, reps: Int?)]
    ) {
        guard let set = prepareSetInteraction(exerciseIndex: exerciseIndex, setIndex: setIndex) else { return }

        sessionStore.completeDropSet(setId: set.id, entries: entries)

        startRestTimerOrRefreshActivity(after: set)
    }

    func skipSet(exerciseIndex: Int, setIndex: Int) {
        guard let set = prepareSetInteraction(exerciseIndex: exerciseIndex, setIndex: setIndex) else { return }

        sessionStore.skipSet(setId: set.id)
        ActiveWorkoutViewModel.updateLiveActivity(session: sessionStore.activeSession, settings: settingsStore.settings)
    }

    func unlogSet(exerciseIndex: Int, setIndex: Int) {
        guard let set = prepareSetInteraction(exerciseIndex: exerciseIndex, setIndex: setIndex) else { return }

        sessionStore.unlogSet(setId: set.id)
        ActiveWorkoutViewModel.updateLiveActivity(session: sessionStore.activeSession, settings: settingsStore.settings)
    }

    func saveEditedSet(exerciseIndex: Int, setIndex: Int, weight: Double?, reps: Int?, time: Int?) {
        guard let session, exerciseIndex < session.exercises.count else { return }
        let exercise = session.exercises[exerciseIndex]
        guard setIndex < exercise.sets.count else { return }
        let set = exercise.sets[setIndex]

        let setTarget = set.entries.first?.target
        let setActual = set.entries.first?.actual
        sessionStore.completeSet(
            setId: set.id,
            actualWeight: weight,
            // Fall back to the user's default unit so a weight added to a
            // previously reps-only set (GH #194) is logged in their unit.
            actualWeightUnit: setActual?.weight?.unit ?? setTarget?.weight?.unit
                ?? settingsStore.settings?.defaultWeightUnit,
            actualReps: reps,
            actualTime: time ?? setActual?.time ?? setTarget?.time,
            actualRpe: setActual?.rpe ?? setTarget?.rpe
        )
    }

    func addExerciseFromMarkdown(_ markdown: String) {
        guard let parsed = ActiveWorkoutViewModel.parseExerciseFromMarkdown(markdown) else { return }
        sessionStore.addExercise(exerciseName: parsed.name, sets: parsed.sets)
    }

    // MARK: - Shared Set-Interaction Plumbing

    /// Common preamble for set interactions: bounds-check the indices, record
    /// the interacted exercise, and dismiss any running rest timer. Returns
    /// the targeted set, or nil when the indices are stale.
    private func prepareSetInteraction(exerciseIndex: Int, setIndex: Int) -> SessionSet? {
        guard let session, exerciseIndex < session.exercises.count else { return nil }
        let exercise = session.exercises[exerciseIndex]
        guard setIndex < exercise.sets.count else { return nil }

        lastInteractedExerciseId = exercise.id
        activeRestTimer = nil
        return exercise.sets[setIndex]
    }

    /// After completing a set: start the rest timer when configured, and push
    /// the corresponding Live Activity update either way.
    private func startRestTimerOrRefreshActivity(after set: SessionSet) {
        if let rest = set.restSeconds, rest > 0,
           settingsStore.settings?.autoStartRestTimer == true {
            activeRestTimer = RestTimerState(seconds: rest, triggeringSetId: set.id)
            restTimerGeneration += 1
            let updatedSession = sessionStore.activeSession
            let nextExercise = updatedSession?.exercises.first { ex in ex.sets.contains { $0.status == .pending } }
            ActiveWorkoutViewModel.updateLiveActivity(
                session: sessionStore.activeSession,
                settings: settingsStore.settings,
                restTimer: (remainingSeconds: rest, nextExercise: nextExercise))
        } else {
            ActiveWorkoutViewModel.updateLiveActivity(
                session: sessionStore.activeSession, settings: settingsStore.settings)
        }
    }
}

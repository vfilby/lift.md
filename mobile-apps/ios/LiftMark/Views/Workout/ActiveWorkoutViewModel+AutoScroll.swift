import Foundation

// MARK: - Auto-Scroll After Set Completion

extension ActiveWorkoutViewModel {

    /// Where the active-workout list scrolls after a set is completed.
    enum AutoScrollTarget: Equatable {
        /// Bring the top of the card with this id into view (the next exercise).
        case card(id: String)
        /// Center the exercise timer of the now-current timed set (#433).
        case exerciseTimer(setId: String)
        /// Keep the running rest timer on screen (#444): pin it to the top of
        /// the viewport, or scroll only as much as needed to reveal it.
        case restTimer(pinToTop: Bool)
    }

    /// Scroll-view identity of the `ExerciseTimerView` for a timed set. Kept
    /// distinct from the set id, which already identifies the set row.
    static func exerciseTimerScrollId(setId: String) -> String {
        "exercise-timer-\(setId)"
    }

    /// Scroll-view identity of the `RestTimerView`. Also its view identity, so
    /// each new rest timer (new generation) starts with fresh state.
    static func restTimerScrollId(generation: Int) -> String {
        "rest-timer-\(generation)"
    }

    /// Decides where to scroll after a set is completed.
    ///
    /// The *focus card* is the card the user just worked in while it still has
    /// pending sets; otherwise the next card with pending sets after it
    /// (wrapping around). If the focus card's current set is timed, its timer
    /// is the target so the user never has to scroll to find it (#433).
    /// Otherwise the list scrolls to the top of the next card only when focus
    /// moved to a different card, and stays put when it did not.
    ///
    /// A running rest timer must not be scrolled off-screen (#444). When focus
    /// moves to a new card the rest timer (left behind on the finished card) is
    /// pinned to the top instead, with the next card directly below it. In the
    /// same card a timed set's timer is still centered — the rest timer sits
    /// right above it — and otherwise the rest timer is just revealed.
    static func autoScrollTarget(
        exercises: [SessionExercise], lastInteractedExerciseId: String?, restTimer: RestTimerState?
    ) -> AutoScrollTarget? {
        guard !exercises.isEmpty else { return nil }
        let restRunning = ownsRestTimer(exercises: exercises, restTimer: restTimer)
        let lastIndex = lastInteractedExerciseId.flatMap { id in exercises.firstIndex { $0.id == id } }

        let lastCard = lastIndex.map { card(containing: exercises[$0], in: exercises) }

        let focus: (id: String, members: [SessionExercise])
        let movedToNewCard: Bool
        if let lastCard, hasPendingSet(lastCard.members) {
            focus = lastCard
            movedToNewCard = false
        } else {
            // Search after the anchor, wrapping so earlier-skipped exercises
            // still get picked up once everything later is done.
            let anchor = lastIndex ?? -1
            let count = exercises.count
            guard let next = (1...count).lazy
                .map({ exercises[(anchor + $0) % count] })
                .first(where: { hasPendingSet([$0]) })
            else { return restRunning ? .restTimer(pinToTop: false) : nil }
            focus = card(containing: next, in: exercises)
            movedToNewCard = true
        }

        if restRunning && movedToNewCard { return .restTimer(pinToTop: true) }
        if let set = currentSet(of: focus.members), (set.entries.first?.target?.time ?? 0) > 0 {
            return .exerciseTimer(setId: set.id)
        }
        if restRunning { return .restTimer(pinToTop: false) }
        return movedToNewCard ? .card(id: focus.id) : nil
    }

    /// The card an exercise renders in: its real superset (identified by the
    /// parent id, members in session order) or the exercise on its own.
    /// Mirrors `buildDisplayItems`.
    private static func card(
        containing exercise: SessionExercise, in exercises: [SessionExercise]
    ) -> (id: String, members: [SessionExercise]) {
        if let parentId = exercise.parentExerciseId,
           exercises.contains(where: { $0.id == parentId && $0.groupType == .superset && $0.sets.isEmpty }) {
            let members = exercises.filter { $0.parentExerciseId == parentId }
            if SupersetGrouping.isRealSuperset(childCount: members.count) {
                return (parentId, members)
            }
        }
        return (exercise.id, [exercise])
    }

    private static func hasPendingSet(_ members: [SessionExercise]) -> Bool {
        members.contains { $0.sets.contains { $0.status == .pending } }
    }

    /// The card's current set: the first pending set in round-robin order
    /// across members (a single exercise is the trivial one-member case).
    /// Mirrors how `ActiveExerciseCard` and `SupersetCard` pick the set that
    /// gets the inline exercise timer.
    private static func currentSet(of members: [SessionExercise]) -> SessionSet? {
        let rounds = members.map(\.sets.count).max() ?? 0
        for round in 0..<rounds {
            for member in members where round < member.sets.count && member.sets[round].status == .pending {
                return member.sets[round]
            }
        }
        return nil
    }
}

import Foundation

/// Pure-logic helper for ActiveWorkoutView. Operates on WorkoutSession data
/// without holding any SwiftUI state itself.
enum ActiveWorkoutViewModel {

    // MARK: - Progress

    static func completedSets(in session: WorkoutSession?) -> Int {
        session?.exercises.reduce(0) { sum, ex in
            sum + ex.sets.filter { $0.status == .completed }.count
        } ?? 0
    }

    static func skippedSets(in session: WorkoutSession?) -> Int {
        session?.exercises.reduce(0) { sum, ex in
            sum + ex.sets.filter { $0.status == .skipped }.count
        } ?? 0
    }

    static func totalSets(in session: WorkoutSession?) -> Int {
        session?.exercises.reduce(0) { $0 + $1.sets.count } ?? 0
    }

    /// Count of sets that are still pending (not completed and not skipped).
    /// Used for the finish-workout confirmation to exclude intentionally skipped sets.
    static func pendingSets(in session: WorkoutSession?) -> Int {
        session?.exercises.reduce(0) { sum, ex in
            sum + ex.sets.filter { $0.status == .pending }.count
        } ?? 0
    }

    static func progress(in session: WorkoutSession?) -> Double {
        let total = totalSets(in: session)
        guard total > 0 else { return 0 }
        return Double(completedSets(in: session)) / Double(total)
    }

    /// True when more than 50% of sets were skipped/not completed
    static func isSkipHeavy(in session: WorkoutSession?) -> Bool {
        let total = totalSets(in: session)
        guard total > 0 else { return false }
        return completedSets(in: session) < total / 2
    }

    // MARK: - Active Exercise

    /// The name of the first exercise with a pending set, used for the iPad landscape history panel.
    static func activeExerciseName(in session: WorkoutSession?) -> String? {
        session?.exercises.first(where: { ex in
            ex.sets.contains { $0.status == .pending }
        })?.exerciseName
    }

    // MARK: - Display Items

    static func buildDisplayItems(from exercises: [SessionExercise]) -> [ExerciseDisplayItem] {
        var items: [ExerciseDisplayItem] = []
        var processedIds = Set<String>()
        var displayNumber = 1

        for (index, exercise) in exercises.enumerated() {
            if processedIds.contains(exercise.id) { continue }

            // Check if this is a superset parent (groupType == .superset with no sets)
            if exercise.groupType == .superset && exercise.sets.isEmpty {
                // Gather children
                var children: [(exercise: SessionExercise, exerciseIndex: Int, displayNumber: Int)] = []
                for (childIndex, child) in exercises.enumerated() where child.parentExerciseId == exercise.id {
                    children.append((exercise: child, exerciseIndex: childIndex, displayNumber: displayNumber))
                    displayNumber += 1
                    processedIds.insert(child.id)
                }
                processedIds.insert(exercise.id)
                if SupersetGrouping.isRealSuperset(childCount: children.count) {
                    items.append(.superset(parent: exercise, children: children))
                } else {
                    // Single-member superset is not a real superset — render the
                    // lone child as a standalone exercise, matching the plan view.
                    for child in children {
                        items.append(.single(exercise: child.exercise, exerciseIndex: child.exerciseIndex, displayNumber: child.displayNumber))
                    }
                }
            } else if exercise.parentExerciseId != nil {
                // Skip orphan children (already handled by superset parent)
                continue
            } else if exercise.groupType == .section && exercise.sets.isEmpty {
                // Section header — emit section divider then gather children. A
                // child that is itself a superset parent must recurse so the
                // grandchildren render inside SupersetCard; otherwise the
                // superset parent (which has no sets) shows as an empty single
                // card and the grandchildren are dropped as orphans.
                processedIds.insert(exercise.id)
                let sectionName = exercise.groupName ?? exercise.exerciseName
                if !sectionName.isEmpty {
                    items.append(.section(name: sectionName))
                }
                for (childIndex, child) in exercises.enumerated() {
                    guard child.parentExerciseId == exercise.id else { continue }
                    if child.groupType == .superset && child.sets.isEmpty {
                        var grandchildren: [(exercise: SessionExercise, exerciseIndex: Int, displayNumber: Int)] = []
                        for (gIndex, grandchild) in exercises.enumerated()
                        where grandchild.parentExerciseId == child.id {
                            grandchildren.append((exercise: grandchild, exerciseIndex: gIndex, displayNumber: displayNumber))
                            displayNumber += 1
                            processedIds.insert(grandchild.id)
                        }
                        processedIds.insert(child.id)
                        if SupersetGrouping.isRealSuperset(childCount: grandchildren.count) {
                            items.append(.superset(parent: child, children: grandchildren))
                        } else {
                            // Single-member superset inside a section — render the
                            // lone grandchild standalone, matching the plan view.
                            for grandchild in grandchildren {
                                items.append(.single(exercise: grandchild.exercise, exerciseIndex: grandchild.exerciseIndex, displayNumber: grandchild.displayNumber))
                            }
                        }
                    } else {
                        items.append(.single(exercise: child, exerciseIndex: childIndex, displayNumber: displayNumber))
                        displayNumber += 1
                        processedIds.insert(child.id)
                    }
                }
            } else {
                items.append(.single(exercise: exercise, exerciseIndex: index, displayNumber: displayNumber))
                displayNumber += 1
                processedIds.insert(exercise.id)
            }
        }
        return items
    }

    // MARK: - Live Activity

    static func updateLiveActivity(session: WorkoutSession?, settings: UserSettings?, restTimer: (remainingSeconds: Int, nextExercise: SessionExercise?)? = nil) {
        guard settings?.liveActivitiesEnabled == true,
              LiveActivityService.shared.isAvailable(),
              let session else { return }

        let currentExercise = session.exercises.first { ex in ex.sets.contains { $0.status == .pending } }
        let currentSetIdx = currentExercise?.sets.firstIndex { $0.status == .pending } ?? 0

        LiveActivityService.shared.updateWorkoutActivity(
            session: session,
            exercise: currentExercise,
            setIndex: currentSetIdx,
            progress: (completed: completedSets(in: session), total: totalSets(in: session)),
            restTimer: restTimer
        )
    }

    static func startLiveActivity(session: WorkoutSession?, settings: UserSettings?) {
        guard settings?.liveActivitiesEnabled == true,
              LiveActivityService.shared.isAvailable(),
              let session else { return }

        let currentExercise = session.exercises.first { ex in ex.sets.contains { $0.status == .pending } }
        let currentSetIdx = currentExercise?.sets.firstIndex { $0.status == .pending } ?? 0

        LiveActivityService.shared.startWorkoutActivity(
            session: session,
            exercise: currentExercise,
            setIndex: currentSetIdx,
            progress: (completed: completedSets(in: session), total: totalSets(in: session))
        )
    }

    static func endLiveActivity(settings: UserSettings?, message: String? = nil, subtitle: String? = nil, immediate: Bool = false) {
        guard settings?.liveActivitiesEnabled == true,
              LiveActivityService.shared.isAvailable() else { return }
        LiveActivityService.shared.endWorkoutActivity(message: message, subtitle: subtitle, immediate: immediate)
    }

    // MARK: - HealthKit

    static func saveToHealthKitIfEnabled(_ session: WorkoutSession?, settings: UserSettings?) {
        guard let session,
              settings?.healthKitEnabled == true else { return }
        Task {
            let result = await HealthKitService.saveWorkout(session)
            if !result.success, let error = result.error {
                Logger.shared.error(.app, "Failed to save workout to HealthKit: \(error)")
            }
        }
    }

    // MARK: - Markdown Parsing

    static func parseExerciseFromMarkdown(_ markdown: String) -> (name: String, sets: [SessionSetDraft])? {
        // LMWF requires a `# Workout` header, but the Add Exercise sheet accepts a single
        // exercise block (`## Name` + sets). Prepend a synthetic workout header when missing
        // so the full-workout parser can handle the fragment.
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hasWorkoutHeader = trimmed.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("# ") || t == "#"
        }
        let source = hasWorkoutHeader ? markdown : "# Workout\n" + markdown
        let result = MarkdownParser.parseWorkout(source)
        guard let plan = result.data, let firstExercise = plan.exercises.first else {
            Logger.shared.warn(.app, "Add Exercise markdown failed to parse: \(result.errors.joined(separator: "; "))")
            return nil
        }
        let sets = firstExercise.sets.map { set -> SessionSetDraft in
            let target = set.entries.first?.target
            return SessionSetDraft(
                weight: target?.weight?.value,
                unit: target?.weight?.unit,
                reps: target?.reps,
                time: target?.time,
                rest: set.restSeconds
            )
        }
        return (name: firstExercise.exerciseName, sets: sets)
    }

    // MARK: - Collapse Logic

    static func isExerciseCollapsed(
        _ exercise: SessionExercise,
        expandedExercises: Set<String>,
        collapsedExercises: Set<String>,
        lastInteractedExerciseId: String?,
        allExercises: [SessionExercise]?
    ) -> Bool {
        if expandedExercises.contains(exercise.id) { return false }
        if collapsedExercises.contains(exercise.id) { return true }

        let allDone = exercise.sets.allSatisfy { $0.status == .completed || $0.status == .skipped }
        if allDone { return true }

        let isCurrentExercise: Bool = {
            if let lastId = lastInteractedExerciseId, lastId == exercise.id {
                return exercise.sets.contains { $0.status == .pending }
            }
            guard let exercises = allExercises else { return false }
            return exercises.first(where: { $0.sets.contains { $0.status == .pending } })?.id == exercise.id
        }()

        if isCurrentExercise { return false }
        return true
    }

    static func isSupersetCollapsed(
        _ parent: SessionExercise,
        children: [(exercise: SessionExercise, exerciseIndex: Int, displayNumber: Int)],
        expandedExercises: Set<String>,
        collapsedExercises: Set<String>,
        lastInteractedExerciseId: String?,
        allExercises: [SessionExercise]?
    ) -> Bool {
        if expandedExercises.contains(parent.id) { return false }
        if collapsedExercises.contains(parent.id) { return true }

        let allDone = children.allSatisfy { child in
            child.exercise.sets.allSatisfy { $0.status == .completed || $0.status == .skipped }
        }
        if allDone { return true }

        let isCurrentSuperset = children.contains { child in
            if let lastId = lastInteractedExerciseId, lastId == child.exercise.id {
                return child.exercise.sets.contains { $0.status == .pending }
            }
            return false
        }
        if isCurrentSuperset { return false }

        guard let exercises = allExercises else { return true }
        let firstPendingId = exercises.first(where: { $0.sets.contains { $0.status == .pending } })?.id
        if children.contains(where: { $0.exercise.id == firstPendingId }) { return false }

        return true
    }

    // MARK: - Rest Timer Scoping

    /// Whether a card composed of the given exercises owns the active rest
    /// timer — i.e. one of its sets is the timer's triggering set. Only the
    /// owning card should render the inline timer view; this prevents the
    /// "timer echoed on every in-progress card" bug when the user completes
    /// sets out of order (#123).
    ///
    /// Returns false when `restTimer` is nil or no exercise contains the
    /// triggering set. Passing the children of a superset (their full
    /// exercise list) is supported via a single call.
    static func ownsRestTimer(exercises: [SessionExercise], restTimer: RestTimerState?) -> Bool {
        guard let triggeringSetId = restTimer?.triggeringSetId else { return false }
        return exercises.contains { ex in
            ex.sets.contains { $0.id == triggeringSetId }
        }
    }
}

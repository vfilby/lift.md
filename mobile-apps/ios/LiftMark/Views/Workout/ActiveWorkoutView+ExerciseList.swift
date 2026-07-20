import SwiftUI

/// The scrolling exercise list for `ActiveWorkoutView`, split out so the main
/// view stays within SwiftLint's file/type-length limits.
extension ActiveWorkoutView {
    // MARK: - Exercise List

    /// The collapse state passed to the collapse-decision helpers.
    private var collapseContext: ActiveWorkoutViewModel.CollapseContext {
        .init(
            expandedExercises: expandedExercises,
            collapsedExercises: collapsedExercises,
            lastInteractedExerciseId: lastInteractedExerciseId,
            allExercises: session?.exercises)
    }

    var exerciseListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                    if let exercises = session?.exercises {
                        let displayItems = ActiveWorkoutViewModel.buildDisplayItems(from: exercises)
                        ForEach(displayItems) { item in
                            switch item {
                            case .single(let exercise, let exerciseIndex, let displayNumber):
                                singleExerciseCard(
                                    exercise: exercise, exerciseIndex: exerciseIndex,
                                    displayNumber: displayNumber)

                            case .section(let name):
                                sectionHeader(name: name)

                            case .superset(let parentExercise, let children):
                                supersetCard(parentExercise: parentExercise, children: children)
                            }
                        }
                    }
                }
                .padding()
            }
            .onChange(of: completedSets) { _, _ in
                scrollToNextPendingExercise(proxy: proxy)
            }
        }
    }

    // MARK: - Single Exercise Card

    @ViewBuilder
    private func singleExerciseCard(
        exercise: SessionExercise, exerciseIndex: Int, displayNumber: Int
    ) -> some View {
        let collapsed = ActiveWorkoutViewModel.isExerciseCollapsed(exercise, context: collapseContext)
        // The rest timer renders only on the card that
        // owns the triggering set. When sets are
        // completed out of order, multiple cards have
        // pending sets — without this scoping every
        // card would echo the same timer (#123).
        let ownsRestTimer = ActiveWorkoutViewModel.ownsRestTimer(
            exercises: [exercise], restTimer: activeRestTimer)
        ActiveExerciseCard(
            exercise: exercise,
            exerciseIndex: exerciseIndex,
            displayNumber: displayNumber,
            settings: settingsStore.settings,
            isCollapsed: collapsed,
            activeRestTimer: ownsRestTimer ? activeRestTimer : nil,
            onToggleCollapse: {
                toggleCollapse(exerciseId: exercise.id, currentlyCollapsed: collapsed)
            },
            onCompleteSet: { setIndex, weight, reps, elapsedTime in
                completeSet(
                    exerciseIndex: exerciseIndex, setIndex: setIndex,
                    userWeight: weight, userReps: reps, elapsedTime: elapsedTime)
            },
            onCompleteDropSet: { setIndex, entries in
                completeDropSet(
                    exerciseIndex: exerciseIndex, setIndex: setIndex, entries: entries)
            },
            onSkipSet: { setIndex in
                skipSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
            },
            onEditExercise: {
                editingExercise = exercise
            },
            onSaveSet: { setIndex, weight, reps, time in
                saveEditedSet(
                    exerciseIndex: exerciseIndex, setIndex: setIndex,
                    weight: weight, reps: reps, time: time)
            },
            onUnlogSet: { setIndex in
                unlogSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
            },
            onDismissRest: {
                activeRestTimer = nil
                ActiveWorkoutViewModel.updateLiveActivity(
                    session: sessionStore.activeSession,
                    settings: settingsStore.settings)
            },
            restTimerGeneration: restTimerGeneration
        )
        .id(exercise.id)
    }

    // MARK: - Superset Card

    @ViewBuilder
    private func supersetCard(
        parentExercise: SessionExercise,
        children: [(exercise: SessionExercise, exerciseIndex: Int, displayNumber: Int)]
    ) -> some View {
        let collapsed = ActiveWorkoutViewModel.isSupersetCollapsed(
            parentExercise, children: children, context: collapseContext)
        let ownsRestTimer = ActiveWorkoutViewModel.ownsRestTimer(
            exercises: children.map { $0.exercise },
            restTimer: activeRestTimer)
        SupersetCard(
            parentExercise: parentExercise,
            children: children,
            settings: settingsStore.settings,
            isCollapsed: collapsed,
            activeRestTimer: ownsRestTimer ? activeRestTimer : nil,
            onToggleCollapse: {
                toggleCollapse(exerciseId: parentExercise.id, currentlyCollapsed: collapsed)
            },
            onCompleteSet: { exerciseIndex, setIndex, weight, reps, elapsedTime in
                completeSet(
                    exerciseIndex: exerciseIndex, setIndex: setIndex,
                    userWeight: weight, userReps: reps, elapsedTime: elapsedTime)
            },
            onCompleteDropSet: { exerciseIndex, setIndex, entries in
                completeDropSet(
                    exerciseIndex: exerciseIndex, setIndex: setIndex, entries: entries)
            },
            onSkipSet: { exerciseIndex, setIndex in
                skipSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
            },
            onSaveSet: { exerciseIndex, setIndex, weight, reps, time in
                saveEditedSet(
                    exerciseIndex: exerciseIndex, setIndex: setIndex,
                    weight: weight, reps: reps, time: time)
            },
            onUnlogSet: { exerciseIndex, setIndex in
                unlogSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
            },
            onDismissRest: {
                activeRestTimer = nil
                ActiveWorkoutViewModel.updateLiveActivity(
                    session: sessionStore.activeSession,
                    settings: settingsStore.settings)
            },
            restTimerGeneration: restTimerGeneration
        )
        .id(parentExercise.id)
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(name: String) -> some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Rectangle()
                .fill(sectionColor(for: name))
                .frame(height: 1)
            Text(name.uppercased())
                .font(.lmSubheadline)
                .fontWeight(.semibold)
                .foregroundStyle(sectionColor(for: name))
                .tracking(1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Rectangle()
                .fill(sectionColor(for: name))
                .frame(height: 1)
        }
        .padding(.vertical, LiftMarkTheme.spacingSM)
    }

    private func sectionColor(for name: String) -> Color {
        switch name.lowercased() {
        case "warmup", "warm-up", "warm up": return LiftMarkTheme.warmupAccent
        case "cooldown", "cool-down", "cool down": return LiftMarkTheme.cooldownAccent
        default: return LiftMarkTheme.primary
        }
    }

    // MARK: - Collapse Helpers

    private func toggleCollapse(exerciseId: String, currentlyCollapsed: Bool) {
        if currentlyCollapsed {
            expandedExercises.insert(exerciseId)
            collapsedExercises.remove(exerciseId)
        } else {
            collapsedExercises.insert(exerciseId)
            expandedExercises.remove(exerciseId)
        }
    }

    private func scrollToNextPendingExercise(proxy: ScrollViewProxy) {
        guard let exercises = session?.exercises, !exercises.isEmpty else { return }

        // Only advance once the just-interacted exercise is fully done; otherwise
        // stay put so the user can keep working on it.
        let anchorIdx: Int
        if let lastId = lastInteractedExerciseId,
           let idx = exercises.firstIndex(where: { $0.id == lastId }) {
            let allDone = exercises[idx].sets.allSatisfy { $0.status == .completed || $0.status == .skipped }
            guard allDone else { return }
            anchorIdx = idx
        } else {
            anchorIdx = -1 // no anchor — search from the start
        }

        // Search for the next pending exercise starting *after* the anchor,
        // wrapping around so earlier-skipped exercises still get picked up
        // once everything later is done.
        let count = exercises.count
        for offset in 1...count {
            let i = (anchorIdx + offset) % count
            if exercises[i].sets.contains(where: { $0.status == .pending }) {
                withAnimation {
                    proxy.scrollTo(exercises[i].id, anchor: .top)
                }
                return
            }
        }
    }
}

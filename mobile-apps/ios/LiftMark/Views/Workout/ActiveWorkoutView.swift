import SwiftUI

struct ActiveWorkoutView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showAddExercise = false
    @State private var editingExercise: SessionExercise?
    @State private var addExerciseMarkdown = ""
    @State private var activeRestTimer: RestTimerState?
    @State private var showFinishConfirm = false
    @State private var navigateToSummary = false
    @State private var showDiscardConfirm = false
    @State private var expandedExercises: Set<String> = []
    @State private var collapsedExercises: Set<String> = []
    @State private var restTimerGeneration: Int = 0
    @State private var lastInteractedExerciseId: String?
    @State private var completedSessionForSummary: WorkoutSession?
    @State private var showNotesSheet = false

    private var session: WorkoutSession? { sessionStore.activeSession }

    private var completedSets: Int { ActiveWorkoutViewModel.completedSets(in: session) }
    private var skippedSets: Int { ActiveWorkoutViewModel.skippedSets(in: session) }
    private var totalSets: Int { ActiveWorkoutViewModel.totalSets(in: session) }
    private var progress: Double { ActiveWorkoutViewModel.progress(in: session) }
    private var isSkipHeavy: Bool { ActiveWorkoutViewModel.isSkipHeavy(in: session) }
    private var activeExerciseName: String? { ActiveWorkoutViewModel.activeExerciseName(in: session) }
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if navigateToSummary {
                WorkoutSummaryView(session: completedSessionForSummary)
            } else {
                workoutContent
            }
        }
        .alert("Finish Workout?", isPresented: $showFinishConfirm) {
            Button("Cancel", role: .cancel) {}
            let pending = ActiveWorkoutViewModel.pendingSets(in: session)
            Button(pending > 0 ? "Finish Anyway" : "Finish") {
                finishWorkout()
            }
        } message: {
            let pending = ActiveWorkoutViewModel.pendingSets(in: session)
            if pending > 0 {
                Text("You have \(pending) incomplete sets. They will be marked as skipped.")
            } else {
                Text("Great job completing all your sets!")
            }
        }
        .alert("Discard Workout?", isPresented: $showDiscardConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Log Anyway") {
                finishWorkout()
            }
            Button("Discard", role: .destructive) {
                ActiveWorkoutViewModel.endLiveActivity(settings: settingsStore.settings, message: "Workout Discarded", subtitle: "Workout not saved", immediate: true)
                sessionStore.cancelSession()
                dismiss()
            }
        } message: {
            Text("You've skipped most of your sets. Do you want to discard this workout?")
        }
    }

    // MARK: - Workout Content

    private var workoutContent: some View {
        VStack(spacing: 0) {
            workoutHeader
            progressBar

            Divider()

            // Workout content — adaptive layout for iPad
            GeometryReader { geometry in
                if isRegularWidth {
                    HStack(spacing: 0) {
                        exerciseListView
                            .frame(width: geometry.size.width * 0.4)
                        Divider()
                        exerciseHistoryPanel
                            .frame(width: geometry.size.width * 0.6)
                    }
                } else {
                    exerciseListView
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("active-workout-scroll")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("active-workout-screen")
        .safeAreaInset(edge: .bottom) {
            workoutFooter
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            if session == nil {
                dismiss()
                return
            }
            if settingsStore.settings?.keepScreenAwake == true {
                #if canImport(UIKit)
                UIApplication.shared.isIdleTimerDisabled = true
                #endif
            }
            ActiveWorkoutViewModel.startLiveActivity(session: session, settings: settingsStore.settings)
        }
        .onDisappear {
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
        .sheet(isPresented: $showAddExercise) {
            AddExerciseSheet(onAdd: { markdown in
                addExerciseFromMarkdown(markdown)
            })
        }
        .sheet(isPresented: $showNotesSheet) {
            SessionNotesSheet(
                initialNotes: sessionStore.activeSession?.notes,
                title: "Workout Notes",
                onSave: { newNotes in
                    sessionStore.updateActiveSessionNotes(newNotes)
                }
            )
        }
        .sheet(item: $editingExercise) { exercise in
            EditExerciseSheet(
                exercise: exercise,
                onSave: { name, notes, equipmentType, setChanges in
                    sessionStore.updateExercise(exerciseId: exercise.id, name: name, notes: notes, equipmentType: equipmentType)
                    for change in setChanges {
                        switch change {
                        case .update(let setId, let weight, let reps, let time, let rest):
                            sessionStore.updateSetTarget(setId: setId, targetWeight: weight, targetReps: reps, targetTime: time, restSeconds: rest)
                        case .add(let weight, let unit, let reps, let time, let rest):
                            sessionStore.addSetToExercise(exerciseId: exercise.id, targetWeight: weight, targetWeightUnit: unit, targetReps: reps, targetTime: time, restSeconds: rest)
                        case .delete(let setId):
                            sessionStore.deleteSet(setId: setId)
                        }
                    }
                    editingExercise = nil
                }
            )
        }
    }

    // MARK: - Header

    private var workoutHeader: some View {
        ActiveWorkoutHeader(
            sessionName: session?.name ?? "Workout",
            hasNotes: !(session?.notes?.isEmpty ?? true),
            onPause: {
                ActiveWorkoutViewModel.endLiveActivity(settings: settingsStore.settings, immediate: true)
                dismiss()
            },
            onNotes: { showNotesSheet = true },
            onFinish: confirmFinish
        )
    }

    private var workoutFooter: some View {
        ActiveWorkoutFooter(
            onAddExercise: { showAddExercise = true },
            onFinish: confirmFinish
        )
    }

    private func confirmFinish() {
        if isSkipHeavy {
            showDiscardConfirm = true
        } else {
            showFinishConfirm = true
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        ActiveWorkoutProgressBar(
            completedSets: completedSets,
            skippedSets: skippedSets,
            totalSets: totalSets
        )
    }

    // MARK: - Exercise List

    private var exerciseListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                    if let exercises = session?.exercises {
                        let displayItems = ActiveWorkoutViewModel.buildDisplayItems(from: exercises)
                        ForEach(displayItems) { item in
                            switch item {
                            case .single(let exercise, let exerciseIndex, let displayNumber):
                                let collapsed = ActiveWorkoutViewModel.isExerciseCollapsed(
                                    exercise, expandedExercises: expandedExercises,
                                    collapsedExercises: collapsedExercises,
                                    lastInteractedExerciseId: lastInteractedExerciseId,
                                    allExercises: session?.exercises)
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
                                        completeSet(exerciseIndex: exerciseIndex, setIndex: setIndex, userWeight: weight, userReps: reps, elapsedTime: elapsedTime)
                                    },
                                    onCompleteDropSet: { setIndex, entries in
                                        completeDropSet(exerciseIndex: exerciseIndex, setIndex: setIndex, entries: entries)
                                    },
                                    onSkipSet: { setIndex in
                                        skipSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
                                    },
                                    onEditExercise: {
                                        editingExercise = exercise
                                    },
                                    onSaveSet: { setIndex, weight, reps, time in
                                        saveEditedSet(exerciseIndex: exerciseIndex, setIndex: setIndex, weight: weight, reps: reps, time: time)
                                    },
                                    onUnlogSet: { setIndex in
                                        unlogSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
                                    },
                                    onDismissRest: {
                                        activeRestTimer = nil
                                        ActiveWorkoutViewModel.updateLiveActivity(session: sessionStore.activeSession, settings: settingsStore.settings)
                                    },
                                    restTimerGeneration: restTimerGeneration
                                )
                                .id(exercise.id)

                            case .section(let name):
                                sectionHeader(name: name)

                            case .superset(let parentExercise, let children):
                                let collapsed = ActiveWorkoutViewModel.isSupersetCollapsed(
                                    parentExercise, children: children,
                                    expandedExercises: expandedExercises,
                                    collapsedExercises: collapsedExercises,
                                    lastInteractedExerciseId: lastInteractedExerciseId,
                                    allExercises: session?.exercises)
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
                                        completeSet(exerciseIndex: exerciseIndex, setIndex: setIndex, userWeight: weight, userReps: reps, elapsedTime: elapsedTime)
                                    },
                                    onCompleteDropSet: { exerciseIndex, setIndex, entries in
                                        completeDropSet(exerciseIndex: exerciseIndex, setIndex: setIndex, entries: entries)
                                    },
                                    onSkipSet: { exerciseIndex, setIndex in
                                        skipSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
                                    },
                                    onSaveSet: { exerciseIndex, setIndex, weight, reps, time in
                                        saveEditedSet(exerciseIndex: exerciseIndex, setIndex: setIndex, weight: weight, reps: reps, time: time)
                                    },
                                    onUnlogSet: { exerciseIndex, setIndex in
                                        unlogSet(exerciseIndex: exerciseIndex, setIndex: setIndex)
                                    },
                                    onDismissRest: {
                                        activeRestTimer = nil
                                        ActiveWorkoutViewModel.updateLiveActivity(session: sessionStore.activeSession, settings: settingsStore.settings)
                                    },
                                    restTimerGeneration: restTimerGeneration
                                )
                                .id(parentExercise.id)
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

    // MARK: - Exercise History Panel (iPad Landscape)

    private var exerciseHistoryPanel: some View {
        ActiveWorkoutHistoryPanel(activeExerciseName: activeExerciseName)
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

    // MARK: - Actions

    private func finishWorkout() {
        ActiveWorkoutViewModel.endLiveActivity(settings: settingsStore.settings, message: "Workout Complete")
        // Snapshot the in-memory session and stamp end_time/duration locally — the
        // repository writes those on complete(), but we don't round-trip the result
        // back to the in-memory copy, so the summary needs them computed here.
        var completedSession = sessionStore.activeSession
        if var snap = completedSession {
            let nowDate = Date()
            let nowIso = ISO8601DateFormatter().string(from: nowDate)
            snap.endTime = nowIso
            if let startTime = snap.startTime,
               let start = ISO8601DateFormatter().date(from: startTime) {
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

    private func completeSet(exerciseIndex: Int, setIndex: Int, userWeight: Double? = nil, userReps: Int? = nil, elapsedTime: Int? = nil) {
        guard let session, exerciseIndex < session.exercises.count else { return }
        let exercise = session.exercises[exerciseIndex]
        guard setIndex < exercise.sets.count else { return }
        let set = exercise.sets[setIndex]

        lastInteractedExerciseId = exercise.id

        // Dismiss any running rest timer before starting a new one
        activeRestTimer = nil

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

        // Trigger rest timer if applicable
        if let rest = set.restSeconds, rest > 0,
           settingsStore.settings?.autoStartRestTimer == true {
            activeRestTimer = RestTimerState(seconds: rest, triggeringSetId: set.id)
            restTimerGeneration += 1
            let updatedSession = sessionStore.activeSession
            let nextExercise = updatedSession?.exercises.first { ex in ex.sets.contains { $0.status == .pending } }
            ActiveWorkoutViewModel.updateLiveActivity(session: sessionStore.activeSession, settings: settingsStore.settings, restTimer: (remainingSeconds: rest, nextExercise: nextExercise))
        } else {
            ActiveWorkoutViewModel.updateLiveActivity(session: sessionStore.activeSession, settings: settingsStore.settings)
        }
    }

    private func completeDropSet(exerciseIndex: Int, setIndex: Int, entries: [(weight: Double?, weightUnit: WeightUnit?, reps: Int?)]) {
        guard let session, exerciseIndex < session.exercises.count else { return }
        let exercise = session.exercises[exerciseIndex]
        guard setIndex < exercise.sets.count else { return }
        let set = exercise.sets[setIndex]

        lastInteractedExerciseId = exercise.id

        // Dismiss any running rest timer before starting a new one
        activeRestTimer = nil

        sessionStore.completeDropSet(setId: set.id, entries: entries)

        // Trigger rest timer if applicable
        if let rest = set.restSeconds, rest > 0,
           settingsStore.settings?.autoStartRestTimer == true {
            activeRestTimer = RestTimerState(seconds: rest, triggeringSetId: set.id)
            restTimerGeneration += 1
            let updatedSession = sessionStore.activeSession
            let nextExercise = updatedSession?.exercises.first { ex in ex.sets.contains { $0.status == .pending } }
            ActiveWorkoutViewModel.updateLiveActivity(session: sessionStore.activeSession, settings: settingsStore.settings, restTimer: (remainingSeconds: rest, nextExercise: nextExercise))
        } else {
            ActiveWorkoutViewModel.updateLiveActivity(session: sessionStore.activeSession, settings: settingsStore.settings)
        }
    }

    private func skipSet(exerciseIndex: Int, setIndex: Int) {
        guard let session, exerciseIndex < session.exercises.count else { return }
        let exercise = session.exercises[exerciseIndex]
        guard setIndex < exercise.sets.count else { return }

        lastInteractedExerciseId = exercise.id

        // Dismiss any running rest timer on skip
        activeRestTimer = nil

        sessionStore.skipSet(setId: exercise.sets[setIndex].id)
        ActiveWorkoutViewModel.updateLiveActivity(session: sessionStore.activeSession, settings: settingsStore.settings)
    }

    private func unlogSet(exerciseIndex: Int, setIndex: Int) {
        guard let session, exerciseIndex < session.exercises.count else { return }
        let exercise = session.exercises[exerciseIndex]
        guard setIndex < exercise.sets.count else { return }

        lastInteractedExerciseId = exercise.id
        activeRestTimer = nil

        sessionStore.unlogSet(setId: exercise.sets[setIndex].id)
        ActiveWorkoutViewModel.updateLiveActivity(session: sessionStore.activeSession, settings: settingsStore.settings)
    }

    private func saveEditedSet(exerciseIndex: Int, setIndex: Int, weight: Double?, reps: Int?, time: Int?) {
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
            actualWeightUnit: setActual?.weight?.unit ?? setTarget?.weight?.unit ?? settingsStore.settings?.defaultWeightUnit,
            actualReps: reps,
            actualTime: time ?? setActual?.time ?? setTarget?.time,
            actualRpe: setActual?.rpe ?? setTarget?.rpe
        )
    }

    private func addExerciseFromMarkdown(_ markdown: String) {
        guard let parsed = ActiveWorkoutViewModel.parseExerciseFromMarkdown(markdown) else { return }
        sessionStore.addExercise(exerciseName: parsed.name, sets: parsed.sets)
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

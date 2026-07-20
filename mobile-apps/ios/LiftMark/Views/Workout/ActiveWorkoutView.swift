import SwiftUI

struct ActiveWorkoutView: View {
    // Stores, session state, and interaction state are non-private so the
    // exercise-list and set-action helpers in ActiveWorkoutView+ExerciseList.swift
    // and ActiveWorkoutView+Actions.swift (split out for SwiftLint's file/type
    // length limits) can read and mutate them.
    @Environment(SessionStore.self) var sessionStore
    @Environment(SettingsStore.self) var settingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showAddExercise = false
    @State var editingExercise: SessionExercise?
    @State private var addExerciseMarkdown = ""
    @State var activeRestTimer: RestTimerState?
    @State private var showFinishConfirm = false
    @State var navigateToSummary = false
    @State private var showDiscardConfirm = false
    @State var expandedExercises: Set<String> = []
    @State var collapsedExercises: Set<String> = []
    @State var restTimerGeneration: Int = 0
    @State var lastInteractedExerciseId: String?
    @State var completedSessionForSummary: WorkoutSession?
    @State private var showNotesSheet = false

    var session: WorkoutSession? { sessionStore.activeSession }

    var completedSets: Int { ActiveWorkoutViewModel.completedSets(in: session) }
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
                ActiveWorkoutViewModel.endLiveActivity(
                    settings: settingsStore.settings,
                    message: "Workout Discarded",
                    subtitle: "Workout not saved",
                    immediate: true)
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
                            sessionStore.updateSetTarget(
                                setId: setId, targetWeight: weight, targetReps: reps,
                                targetTime: time, restSeconds: rest)
                        case .add(let weight, let unit, let reps, let time, let rest):
                            sessionStore.addSetToExercise(
                                exerciseId: exercise.id, targetWeight: weight, targetWeightUnit: unit,
                                targetReps: reps, targetTime: time, restSeconds: rest)
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

    // MARK: - Exercise History Panel (iPad Landscape)

    private var exerciseHistoryPanel: some View {
        ActiveWorkoutHistoryPanel(activeExerciseName: activeExerciseName)
    }
}

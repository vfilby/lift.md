import SwiftUI

struct HomeView: View {
    @Environment(WorkoutPlanStore.self) private var planStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(InboxPollerService.self) private var inboxPoller
    @Environment(FeatureFlagsStore.self) private var featureFlags
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Environment(NavigationCoordinator.self) private var navCoordinator
    @State private var showImport = false
    @State private var showExercisePicker = false
    @State private var editingTileIndex: Int?

    private var inboxCount: Int { inboxPoller.pendingCount }

    // Cached max-lift computations to avoid O(n³) work on every body evaluation
    @State private var cachedMaxWeights: [String: Double] = [:]
    @State private var cachedSparklines: [String: [Double]] = [:]

    private var homeTiles: [String] {
        settingsStore.settings?.homeTiles ?? ["Back Squat", "Deadlift", "Bench Press", "Overhead Press"]
    }

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    private var maxLiftColumns: [GridItem] {
        if isRegularWidth {
            return Array(repeating: GridItem(.flexible()), count: 4)
        } else {
            return [GridItem(.flexible()), GridItem(.flexible())]
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: LiftMarkTheme.spacingMD) {
                // Brand lockup — the app mark beside the wordmark logo (the
                // wordmark carries the custom 'l' the typeface lacks).
                HStack(spacing: 10) {
                    Image("BrandMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM, style: .continuous))
                        .accessibilityHidden(true)
                    Image("BrandWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 34)
                        .accessibilityLabel("lift.md")
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                }

                // Resume Workout Banner
                if let activeSession = sessionStore.activeSession {
                    NavigationLink(value: AppDestination.activeWorkout) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Resume \(activeSession.name)")
                                    .font(.lmHeadline)
                                Text(setProgressText(for: activeSession))
                                    .font(.lmSubheadline)
                                    .opacity(0.9)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .frame(maxWidth: isRegularWidth ? nil : .infinity, alignment: .leading)
                        .padding()
                        .background(LiftMarkTheme.primary)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                        .if(isRegularWidth) { view in
                            view.fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .accessibilityIdentifier("resume-workout-banner")
                    .accessibilityLabel("Resume \(activeSession.name), \(setProgressText(for: activeSession))")
                    .accessibilityHint("Returns to the active workout")
                }

                // Inbox card — shown only when the feature flag is on AND
                // something is waiting locally. See
                // `spec/services/feature-flags.md`.
                if featureFlags.isEnabled(.workoutInbox) && inboxCount > 0 {
                    Button {
                        navCoordinator.selectedTab = .plans
                    } label: {
                        HStack {
                            Image(systemName: "tray.full")
                                .font(.lmTitle2)
                                .foregroundStyle(LiftMarkTheme.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(inboxCount == 1
                                     ? "1 workout in your inbox"
                                     : "\(inboxCount) workouts in your inbox")
                                    .font(.lmHeadline)
                                    .foregroundStyle(LiftMarkTheme.label)
                                Text("Tap to review")
                                    .font(.lmSubheadline)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        }
                        .padding()
                        .background(LiftMarkTheme.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                        .overlay(
                            RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD)
                                .strokeBorder(LiftMarkTheme.tertiaryLabel.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-inbox-card")
                    .accessibilityLabel("\(inboxCount) workouts in your inbox. Tap to review.")
                }

                // Max Lifts Section
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
                    Text("Max Lifts")
                        .font(.lmHeadline)

                    LazyVGrid(columns: maxLiftColumns, spacing: LiftMarkTheme.spacingSM) {
                        ForEach(Array(homeTiles.enumerated()), id: \.offset) { index, exerciseName in
                            MaxLiftTile(
                                exerciseName: exerciseName,
                                maxWeight: cachedMaxWeights[exerciseName],
                                unit: settingsStore.settings?.defaultWeightUnit ?? .lbs,
                                isRegularWidth: isRegularWidth,
                                sparklineData: isRegularWidth ? (cachedSparklines[exerciseName] ?? []) : [],
                                onLongPress: {
                                    editingTileIndex = index
                                    showExercisePicker = true
                                }
                            )
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("max-lift-tile-\(index)")
                        }
                    }
                }

                // Recent Plans Section
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
                    Text("Recent Plans")
                        .font(.lmHeadline)

                    if planStore.plans.isEmpty {
                        VStack(spacing: LiftMarkTheme.spacingSM) {
                            Image(systemName: "dumbbell")
                                .font(.lmLargeTitle)
                                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                                .accessibilityHidden(true)
                            Text("No plans yet")
                                .font(.lmHeadline)
                                .foregroundStyle(LiftMarkTheme.label)
                            Text("Import your first workout plan to get started")
                                .font(.lmSubheadline)
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(LiftMarkTheme.spacingLG)
                        .accessibilityIdentifier("empty-state")
                    } else if isRegularWidth {
                        // iPad: fixed two-column grid showing up to 4 plans so the
                        // grid fills evenly (2×2) instead of leaving a lone card on a
                        // second row (the awkward 2+1 wrap of an odd count).
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: LiftMarkTheme.spacingSM
                        ) {
                            ForEach(planStore.plans.prefix(4)) { plan in
                                Button {
                                    navCoordinator.navigateToPlan(id: plan.id)
                                } label: {
                                    WorkoutPlanCard(plan: plan)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("workout-card-\(plan.id)")
                            }
                        }
                    } else {
                        ForEach(planStore.plans.prefix(3)) { plan in
                            NavigationLink(value: AppDestination.workoutDetail(id: plan.id)) {
                                WorkoutPlanCard(plan: plan)
                            }
                            .accessibilityIdentifier("workout-card-\(plan.id)")
                        }
                    }
                }
                .accessibilityIdentifier("recent-plans")
            }
            .padding()
            .frame(maxWidth: isRegularWidth ? 800 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                showImport = true
            } label: {
                Label("Create Plan", systemImage: "plus")
                    .font(.lmHeadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("button-import-workout")
            .padding(.horizontal)
            .padding(.bottom, LiftMarkTheme.spacingSM)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-screen")
        // No text title — the wordmark logo in the content serves as the
        // screen heading (the typeface renders a plain 'l'; the logo keeps
        // the custom one). Empty + inline collapses the nav-bar title area.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showImport) {
            ImportView()
        }
        .sheet(isPresented: $showExercisePicker) {
            ExercisePickerView { selectedExercise in
                if let index = editingTileIndex {
                    var tiles = homeTiles
                    if index < tiles.count {
                        tiles[index] = selectedExercise
                    }
                    if var settings = settingsStore.settings {
                        settings.homeTiles = tiles
                        settingsStore.updateSettings(settings)
                    }
                }
            }
        }
        .navigationDestination(for: AppDestination.self) { destination in
            switch destination {
            case .workoutDetail(let id):
                WorkoutDetailView(planId: id)
            case .activeWorkout:
                ActiveWorkoutView()
            case .workoutSummary:
                WorkoutSummaryView()
            default:
                EmptyView()
            }
        }
        .onAppear {
            recomputeMaxLifts()
        }
        .onChange(of: sessionStore.sessions) {
            recomputeMaxLifts()
        }
        .onChange(of: homeTiles) {
            recomputeMaxLifts()
        }
    }

    private func recomputeMaxLifts() {
        var weights: [String: Double] = [:]
        for exerciseName in homeTiles {
            let canonical = ExerciseDictionary.getCanonicalName(exerciseName)
            if let best = sessionStore.bestWeights[canonical] {
                weights[exerciseName] = best.weight
            }
        }
        cachedMaxWeights = weights
        // Sparklines still need per-session data, keep existing logic
        var sparklines: [String: [Double]] = [:]
        for exerciseName in homeTiles {
            sparklines[exerciseName] = findMaxWeightsPerSession(for: exerciseName)
        }
        cachedSparklines = sparklines
    }

    private func findMaxWeightsPerSession(for exerciseName: String) -> [Double] {
        // Get completed sessions sorted by date, find max weight per session for this exercise
        let completedSessions = sessionStore.sessions
            .filter { $0.status == .completed }
            .sorted { $0.date < $1.date }

        var weights: [Double] = []
        for session in completedSessions {
            for exercise in session.exercises
            where ExerciseDictionary.isSameExercise(exercise.exerciseName, exerciseName) {
                if let maxW = exercise.sets
                    .filter({ $0.status == .completed })
                    .compactMap({ $0.entries.first?.actual?.weight?.value })
                    .max() {
                    weights.append(maxW)
                }
            }
        }
        return Array(weights.suffix(6))
    }

    private func setProgressText(for session: WorkoutSession) -> String {
        let totalSets = session.exercises.flatMap { $0.sets }.count
        let completedSets = session.exercises.flatMap { $0.sets }.filter { $0.status == .completed }.count
        return "\(completedSets)/\(totalSets) sets completed"
    }
}

// MARK: - Conditional View Modifier

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

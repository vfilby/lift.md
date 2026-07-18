import SwiftUI

struct WorkoutSummaryView: View {
    // The store, session accessor, and sheet/notes state are non-private so
    // the stats, notes, and highlights helpers in
    // WorkoutSummaryView+Sections.swift (split out for SwiftLint's file/type
    // length limits) can read and mutate them.
    @Environment(SessionStore.self) var sessionStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(NavigationCoordinator.self) private var navCoordinator
    @Environment(\.dismiss) private var dismiss

    /// The completed session to display. When provided directly (from ActiveWorkoutView),
    /// uses the passed session. Otherwise falls back to the most recently completed session.
    private let providedSession: WorkoutSession?

    var session: WorkoutSession? {
        providedSession ?? sessionStore.sessions.first
    }

    init(session: WorkoutSession? = nil) {
        self.providedSession = session
    }

    @State var exportFileItem: ExportFile?
    @State var showExportError = false
    @State var exportErrorMessage = ""
    @State var showNotesSheet = false
    /// Local override for the session's notes: the completed session is passed in as
    /// a value and we don't need to round-trip through the store to show the latest text.
    @State var notesOverride: String?
    @State var notesOverrideSet = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: LiftMarkTheme.spacingLG) {
                    // Success Header
                    VStack(spacing: LiftMarkTheme.spacingSM) {
                        // Green circle with white checkmark
                        ZStack {
                            Circle()
                                .fill(LiftMarkTheme.success)
                                .frame(width: 70, height: 70)
                            Image(systemName: "checkmark")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .accessibilityHidden(true)

                        Text("Workout Complete!")
                            .font(.lmDisplay(size: 26, relativeTo: .title))

                        if let name = session?.name {
                            Text(name)
                                .font(.lmSubheadline)
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, LiftMarkTheme.spacingLG)
                    .accessibilityIdentifier("workout-summary-success-header")

                    // Highlights
                    Group {
                        if !highlights.isEmpty {
                            VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
                                Text("Highlights")
                                    .font(.lmHeadline)

                                ForEach(highlights) { highlight in
                                    HStack(spacing: LiftMarkTheme.spacingSM) {
                                        Text(highlight.emoji)
                                            .font(.lmTitle2)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(highlight.title)
                                                .font(.lmSubheadline.bold())
                                            Text(highlight.message)
                                                .font(.lmCaption)
                                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                                        }

                                        Spacer()
                                    }
                                    .padding(.vertical, LiftMarkTheme.spacingXS)
                                }
                            }
                            .padding()
                            .background(LiftMarkTheme.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                        } else {
                            VStack(spacing: LiftMarkTheme.spacingSM) {
                                Text("Highlights")
                                    .font(.lmHeadline)
                                Text("Complete more workouts to see highlights and personal records.")
                                    .font(.lmSubheadline)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                                    .multilineTextAlignment(.center)
                            }
                            .padding()
                            .background(LiftMarkTheme.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                        }
                    }
                    .accessibilityIdentifier("workout-summary-highlights")

                    // Stats strip — compact inline row, four stats with dividers
                    HStack(spacing: 0) {
                        StatPill(title: "Duration", value: durationText)
                        Divider().frame(height: 32)
                        StatPill(title: "Sets", value: "\(completedSets)")
                        Divider().frame(height: 32)
                        StatPill(title: "Reps", value: "\(totalReps)")
                        Divider().frame(height: 32)
                        StatPill(title: "Volume", value: formatVolume(totalVolume))
                    }
                    .padding(.vertical, LiftMarkTheme.spacingSM)
                    .background(LiftMarkTheme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                    .accessibilityIdentifier("workout-summary-stats")

                    // Completion Card
                    VStack(spacing: LiftMarkTheme.spacingSM) {
                        Text("Completion")
                            .font(.lmHeadline)

                        HStack(spacing: LiftMarkTheme.spacingMD) {
                            VStack(spacing: 2) {
                                Text("\(completedSets)")
                                    .font(.lmDisplay(size: 24, relativeTo: .title2))
                                    .foregroundStyle(LiftMarkTheme.success)
                                Text("Completed")
                                    .font(.lmCaption)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            .frame(maxWidth: .infinity)

                            VStack(spacing: 2) {
                                Text("\(skippedSets)")
                                    .font(.lmDisplay(size: 24, relativeTo: .title2))
                                Text("Skipped")
                                    .font(.lmCaption)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            .frame(maxWidth: .infinity)

                            VStack(spacing: 2) {
                                Text("\(Int(completionRate * 100))%")
                                    .font(.lmDisplay(size: 24, relativeTo: .title2))
                                    .foregroundStyle(LiftMarkTheme.primary)
                                Text("Rate")
                                    .font(.lmCaption)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        // Progress bar with orange fill
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusXS)
                                    .fill(LiftMarkTheme.tertiaryLabel.opacity(0.3))
                                    .frame(height: 8)
                                RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusXS)
                                    .fill(.orange)
                                    .frame(width: geometry.size.width * completionRate, height: 8)
                            }
                        }
                        .frame(height: 8)
                    }
                    .padding()
                    .background(LiftMarkTheme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                    .accessibilityIdentifier("workout-summary-completion")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Completion: \(completedSets) completed, \(skippedSets) skipped, "
                        + "\(Int(completionRate * 100)) percent rate")

                    // Notes card — prompts the user to add notes on the just-finished workout.
                    notesCard

                    // Exercise Summary
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Exercises")
                            .font(.lmTitle3.bold())
                            .padding(.bottom, LiftMarkTheme.spacingSM)

                        if let exercises = session?.exercises {
                            let displayExercises = exercises.enumerated().filter { _, exercise in
                                // Exclude section headers and superset parents (they have no sets)
                                !((exercise.groupType == .section || exercise.groupType == .superset)
                                    && exercise.sets.isEmpty)
                            }
                            ForEach(Array(displayExercises.enumerated()), id: \.element.1.id) { outerIndex, pair in
                                let (_, exercise) = pair
                                ExerciseSummaryRow(exercise: exercise, number: outerIndex + 1)

                                if outerIndex < displayExercises.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("workout-summary-exercises")
                }
                .padding()
            }
            .accessibilityIdentifier("workout-summary-scroll")

            Divider()

            // Done Button — pinned to bottom outside ScrollView
            Button {
                sessionStore.clearActiveSession()
                dismiss()
                navCoordinator.popToRoot()
            } label: {
                Text("Done")
                    .font(.lmBody.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(LiftMarkTheme.primary)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workout-summary-done-button")
            .padding(.horizontal)
            .padding(.vertical, LiftMarkTheme.spacingSM)
            .background(LiftMarkTheme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout-summary-screen")
        .navigationTitle("Summary")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportSession()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityIdentifier("share-session-button")
                .accessibilityLabel("Share workout")
                .accessibilityHint("Exports workout data for sharing")
            }
        }
        .shareSheet(item: $exportFileItem)
        .sheet(isPresented: $showNotesSheet) {
            SessionNotesSheet(
                initialNotes: currentNotes,
                title: "Workout Notes",
                onSave: { newNotes in
                    notesOverride = newNotes
                    notesOverrideSet = true
                    if let sid = session?.id {
                        sessionStore.updateSessionNotes(sessionId: sid, notes: newNotes)
                    }
                }
            )
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage)
        }
    }

}

// Uses WorkoutHighlight from WorkoutHighlightsService

// MARK: - Stat Card

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.lmHeadline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.lmCaption2)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Exercise Summary Row

private struct ExerciseSummaryRow: View {
    let exercise: SessionExercise
    let number: Int

    private var completedCount: Int {
        exercise.sets.filter { $0.status == .completed }.count
    }

    private var totalCount: Int {
        exercise.sets.count
    }

    var body: some View {
        HStack(spacing: LiftMarkTheme.spacingMD) {
            Text("\(number)")
                .font(.lmCaption.bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.gray)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.exerciseName)
                    .font(.lmSubheadline)

                if let equipment = exercise.equipmentType {
                    Text(equipment)
                        .font(.lmCaption2)
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                }
            }

            Spacer()

            Text("\(completedCount)/\(totalCount) sets")
                .font(.lmCaption)
                .foregroundStyle(completedCount == totalCount ? LiftMarkTheme.success : LiftMarkTheme.secondaryLabel)

            // Best set weight
            if let bestWeight = exercise.sets
                .filter({ $0.status == .completed })
                .compactMap({ $0.entries.first?.actual?.weight?.value })
                .max() {
                let unit = exercise.sets.first?.entries.first?.actual?.weight?.unit
                    ?? exercise.sets.first?.entries.first?.target?.weight?.unit ?? .lbs
                Text("\(formatWeight(bestWeight)) \(unit.rawValue)")
                    .font(.lmCaption.monospacedDigit())
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
        }
        .padding(.vertical, LiftMarkTheme.spacingXS)
    }

    private func formatWeight(_ weight: Double) -> String {
        weight.formattedWeight
    }
}

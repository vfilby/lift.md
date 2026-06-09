import SwiftUI

struct WorkoutSummaryView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(NavigationCoordinator.self) private var navCoordinator
    @Environment(\.dismiss) private var dismiss

    /// The completed session to display. When provided directly (from ActiveWorkoutView),
    /// uses the passed session. Otherwise falls back to the most recently completed session.
    private let providedSession: WorkoutSession?

    private var session: WorkoutSession? {
        providedSession ?? sessionStore.sessions.first
    }

    init(session: WorkoutSession? = nil) {
        self.providedSession = session
    }

    private var completedSets: Int {
        session?.exercises.reduce(0) { sum, ex in
            sum + ex.sets.filter { $0.status == .completed }.count
        } ?? 0
    }

    private var skippedSets: Int {
        session?.exercises.reduce(0) { sum, ex in
            sum + ex.sets.filter { $0.status == .skipped }.count
        } ?? 0
    }

    private var totalSets: Int {
        session?.exercises.reduce(0) { $0 + $1.sets.count } ?? 0
    }

    private var totalReps: Int {
        session?.exercises.reduce(0) { sum, ex in
            sum + ex.sets.filter { $0.status == .completed }.reduce(0) { total, set in
                let actual = set.entries.first?.actual
                let target = set.entries.first?.target
                return total + (actual?.reps ?? target?.reps ?? 0)
            }
        } ?? 0
    }

    private var totalVolume: Double {
        session?.exercises.reduce(0.0) { sum, ex in
            sum + ex.sets.filter { $0.status == .completed }.reduce(0.0) { setSum, set in
                let actual = set.entries.first?.actual
                let target = set.entries.first?.target
                let weight = actual?.weight?.value ?? target?.weight?.value ?? 0
                let reps = Double(actual?.reps ?? target?.reps ?? 0)
                return setSum + (weight * reps)
            }
        } ?? 0
    }

    private var durationText: String {
        guard let duration = session?.duration else { return "--" }
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private var completionRate: Double {
        guard totalSets > 0 else { return 0 }
        return Double(completedSets) / Double(totalSets)
    }

    private var highlights: [WorkoutHighlight] {
        computeHighlights()
    }

    @State private var exportFileItem: ExportFile?
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var showNotesSheet = false
    /// Local override for the session's notes: the completed session is passed in as
    /// a value and we don't need to round-trip through the store to show the latest text.
    @State private var notesOverride: String?
    @State private var notesOverrideSet = false

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
                    .accessibilityLabel("Completion: \(completedSets) completed, \(skippedSets) skipped, \(Int(completionRate * 100)) percent rate")

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
                                !((exercise.groupType == .section || exercise.groupType == .superset) && exercise.sets.isEmpty)
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

    // MARK: - Notes

    /// The most-recent notes to show/edit: prefer the local override (if the user
    /// has edited on this screen), else the session's persisted notes.
    private var currentNotes: String? {
        if notesOverrideSet { return notesOverride }
        return session?.notes
    }

    @ViewBuilder
    private var notesCard: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            HStack {
                Text("Notes")
                    .font(.lmHeadline)
                Spacer()
                Button(currentNotes?.isEmpty ?? true ? "Add" : "Edit") {
                    showNotesSheet = true
                }
                .font(.lmSubheadline)
                .accessibilityIdentifier("workout-summary-notes-edit-button")
            }

            if let notes = currentNotes, !notes.isEmpty {
                Text(notes)
                    .font(.lmBody)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("How did this workout feel? Capture any notes while it's fresh.")
                    .font(.lmSubheadline)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .accessibilityIdentifier("workout-summary-notes")
    }

    // MARK: - Highlights Computation

    private func computeHighlights() -> [WorkoutHighlight] {
        guard let session else { return [] }
        var result: [WorkoutHighlight] = []

        // Check for PRs by comparing against previous sessions
        for exercise in session.exercises {
            let maxWeight = exercise.sets
                .filter { $0.status == .completed }
                .compactMap { $0.entries.first?.actual?.weight?.value }
                .max()

            if let maxWeight {
                // Check if this is a PR across all completed sessions
                let previousMax = sessionStore.sessions.dropLast().reduce(0.0) { best, prevSession in
                    let exerciseMax = prevSession.exercises
                        .filter { $0.exerciseName == exercise.exerciseName }
                        .flatMap { $0.sets.filter { $0.status == .completed } }
                        .compactMap { $0.entries.first?.actual?.weight?.value }
                        .max() ?? 0
                    return max(best, exerciseMax)
                }

                if maxWeight > previousMax && previousMax > 0 {
                    let unit = exercise.sets.first?.entries.first?.actual?.weight?.unit ?? exercise.sets.first?.entries.first?.target?.weight?.unit ?? .lbs
                    result.append(WorkoutHighlight(
                        type: .pr,
                        emoji: "🏆",
                        title: "PR: \(exercise.exerciseName)",
                        message: "\(formatWeight(maxWeight)) \(unit.rawValue) (previous: \(formatWeight(previousMax)) \(unit.rawValue))"
                    ))
                }
            }
        }

        // Consecutive-week streak: weeks (Mon–Sun) with ≥1 completed workout,
        // counted backward from this session's week. Only highlighted at 2+.
        if let weeks = consecutiveWeekStreak(endingWith: session), weeks >= 2 {
            result.append(WorkoutHighlight(
                type: .streak,
                emoji: "🔥",
                title: "Streak",
                message: "\(weeks) weeks in a row"
            ))
        }

        return result
    }

    /// Number of consecutive ISO calendar weeks ending in `session`'s week that
    /// contain at least one completed workout.
    private func consecutiveWeekStreak(endingWith session: WorkoutSession) -> Int? {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2 // Monday
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone

        guard let anchor = formatter.date(from: session.date),
              let anchorWeekStart = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start
        else { return nil }

        let completedWeekStarts: Set<Date> = Set(
            sessionStore.sessions.compactMap { s -> Date? in
                guard s.status == .completed,
                      let d = formatter.date(from: s.date),
                      let wk = calendar.dateInterval(of: .weekOfYear, for: d)?.start
                else { return nil }
                return wk
            }
        )

        var weeks = 0
        var cursor = anchorWeekStart
        while completedWeekStarts.contains(cursor) {
            weeks += 1
            guard let prev = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return weeks
    }

    private func exportSession() {
        guard let session else { return }
        let exportService = WorkoutExportService()
        do {
            let url = try exportService.exportSingleSessionAsJson(session)
            exportFileItem = ExportFile(url: url)
        } catch {
            exportErrorMessage = "Could not export workout: \(error.localizedDescription)"
            showExportError = true
        }
    }

    private func formatWeight(_ w: Double) -> String {
        w.formattedWeight
    }

    private func formatVolume(_ volume: Double) -> String {
        if volume >= 1000 {
            return String(format: "%.1fk", volume / 1000)
        }
        return "\(Int(volume))"
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
                let unit = exercise.sets.first?.entries.first?.actual?.weight?.unit ?? exercise.sets.first?.entries.first?.target?.weight?.unit ?? .lbs
                Text("\(formatWeight(bestWeight)) \(unit.rawValue)")
                    .font(.lmCaption.monospacedDigit())
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
        }
        .padding(.vertical, LiftMarkTheme.spacingXS)
    }

    private func formatWeight(_ w: Double) -> String {
        w.formattedWeight
    }
}

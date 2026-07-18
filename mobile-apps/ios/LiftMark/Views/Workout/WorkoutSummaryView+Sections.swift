import SwiftUI

/// Session stats, the notes card, highlight computation, and export for
/// `WorkoutSummaryView`, split out so the main view stays within SwiftLint's
/// file/type-length limits.
extension WorkoutSummaryView {
    // MARK: - Session Stats

    var completedSets: Int {
        session?.exercises.reduce(0) { sum, ex in
            sum + ex.sets.filter { $0.status == .completed }.count
        } ?? 0
    }

    var skippedSets: Int {
        session?.exercises.reduce(0) { sum, ex in
            sum + ex.sets.filter { $0.status == .skipped }.count
        } ?? 0
    }

    var totalSets: Int {
        session?.exercises.reduce(0) { $0 + $1.sets.count } ?? 0
    }

    var totalReps: Int {
        session?.exercises.reduce(0) { sum, ex in
            sum + ex.sets.filter { $0.status == .completed }.reduce(0) { total, set in
                let actual = set.entries.first?.actual
                let target = set.entries.first?.target
                return total + (actual?.reps ?? target?.reps ?? 0)
            }
        } ?? 0
    }

    var totalVolume: Double {
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

    var durationText: String {
        guard let duration = session?.duration else { return "--" }
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var completionRate: Double {
        guard totalSets > 0 else { return 0 }
        return Double(completedSets) / Double(totalSets)
    }

    var highlights: [WorkoutHighlight] {
        computeHighlights()
    }

    // MARK: - Notes

    /// The most-recent notes to show/edit: prefer the local override (if the user
    /// has edited on this screen), else the session's persisted notes.
    var currentNotes: String? {
        if notesOverrideSet { return notesOverride }
        return session?.notes
    }

    @ViewBuilder
    var notesCard: some View {
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
                    let unit = exercise.sets.first?.entries.first?.actual?.weight?.unit
                        ?? exercise.sets.first?.entries.first?.target?.weight?.unit ?? .lbs
                    result.append(WorkoutHighlight(
                        type: .pr,
                        emoji: "🏆",
                        title: "PR: \(exercise.exerciseName)",
                        message: "\(formatWeight(maxWeight)) \(unit.rawValue) "
                            + "(previous: \(formatWeight(previousMax)) \(unit.rawValue))"
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
            sessionStore.sessions.compactMap { candidate -> Date? in
                guard candidate.status == .completed,
                      let date = formatter.date(from: candidate.date),
                      let wk = calendar.dateInterval(of: .weekOfYear, for: date)?.start
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

    func exportSession() {
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

    private func formatWeight(_ weight: Double) -> String {
        weight.formattedWeight
    }

    func formatVolume(_ volume: Double) -> String {
        if volume >= 1000 {
            return String(format: "%.1fk", volume / 1000)
        }
        return "\(Int(volume))"
    }
}

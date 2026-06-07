import SwiftUI

struct HistoryDetailView: View {
    let sessionId: String
    var isEmbedded: Bool = false
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var exportFileItem: ExportFile?
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var showExerciseHistory = false
    @State private var selectedExerciseName: String?
    @State private var showNotesSheet = false

    private var session: WorkoutSession? {
        sessionStore.sessions.first { $0.id == sessionId }
    }

    private var completedSetsCount: Int {
        guard let session else { return 0 }
        return session.exercises.flatMap(\.sets).filter { $0.status == .completed }.count
    }

    private var totalSetsCount: Int {
        guard let session else { return 0 }
        return session.exercises.flatMap(\.sets).count
    }

    private var totalVolume: Double {
        guard let session else { return 0 }
        return session.exercises.flatMap(\.sets)
            .filter { $0.status == .completed }
            .reduce(0.0) { total, set in
                let actual = set.entries.first?.actual
                return total + (actual?.weight?.value ?? 0) * Double(actual?.reps ?? 0)
            }
    }

    private var totalReps: Int {
        guard let session else { return 0 }
        return session.exercises.flatMap(\.sets)
            .filter { $0.status == .completed }
            .compactMap { $0.entries.first?.actual?.reps }
            .reduce(0, +)
    }

    var body: some View {
        Group {
            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                        // Stats card
                        statsCard(session)

                        // Exercises heading
                        Text("Exercises")
                            .font(.lmCallout)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        // Exercises grouped by section
                        let sections = exerciseSections(from: session.exercises)
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            if let sectionName = section.name {
                                sectionHeader(name: sectionName)
                            }
                            ForEach(section.exercises, id: \.exercise.id) { item in
                                exerciseCard(item.exercise, number: item.displayNumber)
                            }
                        }

                        // Notes — editable later from history, per GH #91.
                        notesCard(session)

                        // Delete button
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Text("Delete Workout")
                                .font(.lmBody)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, LiftMarkTheme.spacingMD)
                                .background(LiftMarkTheme.destructive)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, LiftMarkTheme.spacingLG)
                        .accessibilityIdentifier("delete-session-button")
                    }
                    .padding()
                }
                .accessibilityIdentifier("history-detail-view")
            } else {
                ProgressView()
            }
        }
        .accessibilityIdentifier("history-detail-screen")
        .navigationTitle(isEmbedded ? "" : (session?.name ?? "Workout"))
        .toolbar {
            if !isEmbedded {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportSession()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("share-session-button")
                }
            }
        }
        .alert("Delete Workout", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                sessionStore.deleteSession(id: sessionId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this workout? This cannot be undone.")
        }
        #if os(iOS)
        .shareSheet(item: $exportFileItem)
        #endif
        .sheet(isPresented: $showNotesSheet) {
            SessionNotesSheet(
                initialNotes: session?.notes,
                title: "Workout Notes",
                onSave: { newNotes in
                    sessionStore.updateSessionNotes(sessionId: sessionId, notes: newNotes)
                }
            )
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage)
        }
        .sheet(isPresented: $showExerciseHistory) {
            if let name = selectedExerciseName {
                NavigationStack {
                    ExerciseHistorySheetView(exerciseName: name)
                }
            }
        }
    }

    // MARK: - Section Grouping

    private struct ExerciseSection {
        let name: String?
        let exercises: [(exercise: SessionExercise, displayNumber: Int)]
    }

    private func exerciseSections(from exercises: [SessionExercise]) -> [ExerciseSection] {
        var sections: [ExerciseSection] = []
        var currentSectionName: String?
        var currentExercises: [(exercise: SessionExercise, displayNumber: Int)] = []
        var displayNumber = 1
        var processedIds = Set<String>()

        for exercise in exercises {
            if processedIds.contains(exercise.id) { continue }

            if exercise.groupType == .section && exercise.sets.isEmpty {
                // Flush current section
                if !currentExercises.isEmpty {
                    sections.append(ExerciseSection(name: currentSectionName, exercises: currentExercises))
                    currentExercises = []
                }
                currentSectionName = exercise.groupName ?? exercise.exerciseName
                processedIds.insert(exercise.id)
                // Gather children
                for child in exercises {
                    if child.parentExerciseId == exercise.id {
                        currentExercises.append((exercise: child, displayNumber: displayNumber))
                        displayNumber += 1
                        processedIds.insert(child.id)
                    }
                }
            } else if exercise.parentExerciseId != nil {
                // Skip orphan children already handled
                continue
            } else if exercise.groupType == .superset && exercise.sets.isEmpty {
                // Superset parent — skip but include children
                processedIds.insert(exercise.id)
                for child in exercises {
                    if child.parentExerciseId == exercise.id {
                        currentExercises.append((exercise: child, displayNumber: displayNumber))
                        displayNumber += 1
                        processedIds.insert(child.id)
                    }
                }
            } else {
                currentExercises.append((exercise: exercise, displayNumber: displayNumber))
                displayNumber += 1
                processedIds.insert(exercise.id)
            }
        }

        if !currentExercises.isEmpty {
            sections.append(ExerciseSection(name: currentSectionName, exercises: currentExercises))
        }

        return sections
    }

    // MARK: - Notes Card

    @ViewBuilder
    private func notesCard(_ session: WorkoutSession) -> some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            HStack {
                Text("Notes")
                    .font(.lmCallout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(session.notes?.isEmpty ?? true ? "Add" : "Edit") {
                    showNotesSheet = true
                }
                .font(.lmSubheadline)
                .accessibilityIdentifier("history-detail-notes-edit-button")
            }

            if let notes = session.notes, !notes.isEmpty {
                Text(notes)
                    .font(.lmBody)
                    .foregroundStyle(.secondary)
            } else {
                Text("No notes yet.")
                    .font(.lmSubheadline)
                    .foregroundStyle(.tertiary)
                    .italic()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .accessibilityIdentifier("history-detail-notes-card")
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

    // MARK: - Stats Card

    @ViewBuilder
    private func statsCard(_ session: WorkoutSession) -> some View {
        // Header card
        VStack(alignment: .leading, spacing: 4) {
            // When embedded in the iPad split view the navigation title is suppressed,
            // so surface the workout name here. On iPhone the name is the nav title.
            if isEmbedded {
                Text(session.name)
                    .font(.lmTitle3)
                    .fontWeight(.bold)
                    .padding(.bottom, 2)
            }

            // Full date — falls back to the calendar date when startTime is missing or
            // unparseable, never the raw ISO string.
            Text(SessionDateDisplay.fullDateLine(startTime: session.startTime, date: session.date))
                .font(.lmBody)
                .fontWeight(.semibold)

            // Start time (if known) + duration, each with its own leading separator.
            let startTime = SessionDateDisplay.shortTime(startTime: session.startTime)
            let duration = SessionDateDisplay.duration(seconds: session.duration)
            if startTime != nil || duration != nil {
                HStack(spacing: 8) {
                    if let startTime {
                        Text(startTime)
                    }
                    if let duration {
                        if startTime != nil { Text("·") }
                        Text(duration)
                    }
                }
                .font(.lmSubheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))

        // Stats grid
        HStack(spacing: LiftMarkTheme.spacingSM) {
            statCell(value: "\(completedSetsCount)", label: "Sets")
            statCell(value: "\(totalReps)", label: "Reps")
            statCell(value: totalVolume > 0 ? formatVolume(totalVolume) : "\u{2013}", label: "Volume")
        }
        .accessibilityIdentifier("session-stats-card")
    }

    @ViewBuilder
    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.lmDisplay(size: 22, relativeTo: .title2))
                .foregroundStyle(LiftMarkTheme.primary)
            Text(label)
                .font(.lmCaption)
                .fontWeight(.medium)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
    }

    // MARK: - Exercise Card

    @ViewBuilder
    private func exerciseCard(_ exercise: SessionExercise, number: Int) -> some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            HStack(alignment: .top, spacing: LiftMarkTheme.spacingMD) {
                // Numbered blue badge
                Text("\(number)")
                    .font(.lmCallout)
                    .fontWeight(.bold)
                    .foregroundStyle(LiftMarkTheme.primary)

                VStack(alignment: .leading, spacing: 2) {
                    if let groupType = exercise.groupType, groupType == .superset {
                        Text("SUPERSET")
                            .font(.lmCaption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Text(exercise.exerciseName)
                        .font(.lmCallout)
                        .fontWeight(.semibold)

                    if let equipment = exercise.equipmentType {
                        Text(equipment)
                            .font(.lmCaption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            // Sets
            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                setRow(set, index: index + 1)
            }

            // Exercise notes
            if let notes = exercise.notes, !notes.isEmpty {
                Text(notes)
                    .font(.lmCaption)
                    .foregroundStyle(.secondary)
                    .padding(.top, LiftMarkTheme.spacingXS)
            }

            // Inline trend with chart
            ExerciseTrendView(exerciseName: exercise.exerciseName, onShowDetails: {
                selectedExerciseName = exercise.exerciseName
                showExerciseHistory = true
            })
        }
        .padding()
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .accessibilityIdentifier("exercise-card-\(exercise.exerciseName)")
    }

    // MARK: - Set Row

    @ViewBuilder
    private func setRow(_ set: SessionSet, index: Int) -> some View {
        HStack(spacing: LiftMarkTheme.spacingMD) {
            // Status badge (✓ for completed, − for skipped)
            Group {
                switch set.status {
                case .completed:
                    Text("✓")
                case .skipped:
                    Text("−")
                case .failed:
                    Text("✗")
                case .pending:
                    Text("○")
                }
            }
            .font(.lmCaption)
            .fontWeight(.bold)
            .frame(width: 28, height: 28)
            .background(statusColor(set.status).opacity(0.12))
            .foregroundStyle(statusColor(set.status))
            .clipShape(Circle())

            // Weight & reps or "Skipped"
            if set.status == .skipped {
                Text("Skipped")
                    .font(.lmSubheadline)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                let actual = set.entries.first?.actual
                let target = set.entries.first?.target
                HStack(spacing: 4) {
                    if let weight = actual?.weight?.value ?? target?.weight?.value,
                       let unit = actual?.weight?.unit ?? target?.weight?.unit {
                        Text("\(Int(weight)) \(unit.rawValue)")
                            .font(.lmSubheadline)
                    }
                    if let reps = actual?.reps ?? target?.reps {
                        Text("× \(reps) reps")
                            .font(.lmSubheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let time = actual?.time ?? target?.time {
                        Text("\(time)s")
                            .font(.lmSubheadline)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func statusColor(_ status: SetStatus) -> Color {
        switch status {
        case .completed: return LiftMarkTheme.success
        case .skipped: return LiftMarkTheme.warning
        case .failed: return LiftMarkTheme.destructive
        case .pending: return LiftMarkTheme.secondaryLabel
        }
    }

    private func formatVolume(_ volume: Double) -> String {
        if volume >= 1000 {
            return String(format: "%.1fk", volume / 1000)
        }
        return "\(Int(volume))"
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
}

// MARK: - Exercise History Sheet

struct ExerciseHistorySheetView: View {
    let exerciseName: String
    @Environment(\.dismiss) private var dismiss
    @State private var historyPoints: [ExerciseHistoryPoint] = []
    @State private var isLoading = true

    private var summaryStats: (sessions: Int, maxWeight: Double, avgReps: Double, totalVolume: Double) {
        let sessions = historyPoints.count
        let maxWeight = historyPoints.map(\.maxWeight).max() ?? 0
        let avgReps = historyPoints.isEmpty ? 0 : historyPoints.map(\.avgReps).reduce(0, +) / Double(historyPoints.count)
        let totalVolume = historyPoints.map(\.totalVolume).reduce(0, +)
        return (sessions, maxWeight, avgReps, totalVolume)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if historyPoints.isEmpty {
                VStack(spacing: LiftMarkTheme.spacingMD) {
                    Image(systemName: "chart.line.downtrend.xyaxis")
                        .font(.lmLargeTitle)
                        .foregroundStyle(.secondary)
                    Text("No history for this exercise")
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                        // Summary card
                        summaryCard

                        // Chart
                        ExerciseHistoryChartView(exerciseName: exerciseName)
                            .padding()
                            .background(LiftMarkTheme.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))

                        // Session list
                        Text("Sessions")
                            .font(.lmHeadline)

                        ForEach(historyPoints, id: \.date) { point in
                            historyPointRow(point)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(exerciseName)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { loadHistory() }
    }

    @ViewBuilder
    private var summaryCard: some View {
        let stats = summaryStats
        HStack(spacing: LiftMarkTheme.spacingMD) {
            VStack {
                Text("\(stats.sessions)")
                    .font(.lmTitle3).fontWeight(.bold)
                Text("Sessions")
                    .font(.lmCaption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)

            VStack {
                Text("\(Int(stats.maxWeight))")
                    .font(.lmTitle3).fontWeight(.bold)
                Text("Max Weight")
                    .font(.lmCaption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)

            VStack {
                Text(String(format: "%.1f", stats.avgReps))
                    .font(.lmTitle3).fontWeight(.bold)
                Text("Avg Reps")
                    .font(.lmCaption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)

            VStack {
                Text(formatVolume(stats.totalVolume))
                    .font(.lmTitle3).fontWeight(.bold)
                Text("Total Vol")
                    .font(.lmCaption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity)
        }
        .padding()
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
    }

    @ViewBuilder
    private func historyPointRow(_ point: ExerciseHistoryPoint) -> some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            HStack {
                Text(point.workoutName)
                    .font(.lmSubheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(formatDate(point.date))
                    .font(.lmCaption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: LiftMarkTheme.spacingMD) {
                if point.maxWeight > 0 {
                    Label("\(Int(point.maxWeight)) \(point.unit.rawValue)", systemImage: "scalemass")
                }
                Label("\(point.setsCount) sets", systemImage: "number")
                if point.totalVolume > 0 {
                    Label(formatVolume(point.totalVolume), systemImage: "chart.bar")
                }
            }
            .font(.lmCaption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM))
    }

    private func loadHistory() {
        let repo = ExerciseHistoryRepository()
        do {
            historyPoints = try repo.getHistoryNormalized(forExercise: exerciseName)
        } catch {
            Logger.shared.error(.app, "Failed to load history", error: error)
        }
        isLoading = false
    }

    private func formatDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(dateString.prefix(10))) else { return dateString }
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        return displayFormatter.string(from: date)
    }

    private func formatVolume(_ volume: Double) -> String {
        if volume >= 1000 {
            return String(format: "%.1fk", volume / 1000)
        }
        return "\(Int(volume))"
    }
}

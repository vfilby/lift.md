import SwiftUI

// MARK: - Set Row

extension HistoryDetailView {
    @ViewBuilder
    func setRow(_ set: SessionSet, index: Int) -> some View {
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

    func statusColor(_ status: SetStatus) -> Color {
        switch status {
        case .completed: return LiftMarkTheme.success
        case .skipped: return LiftMarkTheme.warning
        case .failed: return LiftMarkTheme.destructive
        case .pending: return LiftMarkTheme.secondaryLabel
        }
    }
}

// MARK: - Exercise History Sheet

struct ExerciseHistorySheetView: View {
    let exerciseName: String
    @Environment(\.dismiss) private var dismiss
    @State private var historyPoints: [ExerciseHistoryPoint] = []
    @State private var isLoading = true

    private struct SummaryStats {
        let sessions: Int
        let maxWeight: Double
        let avgReps: Double
        let totalVolume: Double
    }

    private var summaryStats: SummaryStats {
        let sessions = historyPoints.count
        let maxWeight = historyPoints.map(\.maxWeight).max() ?? 0
        let avgReps = historyPoints.isEmpty
            ? 0 : historyPoints.map(\.avgReps).reduce(0, +) / Double(historyPoints.count)
        let totalVolume = historyPoints.map(\.totalVolume).reduce(0, +)
        return SummaryStats(sessions: sessions, maxWeight: maxWeight, avgReps: avgReps, totalVolume: totalVolume)
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

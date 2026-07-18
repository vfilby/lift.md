import SwiftUI
import Charts

/// Chart view for exercise performance history using Swift Charts.
struct ExerciseHistoryChartView: View {
    let exerciseName: String
    @State private var historyPoints: [ExerciseHistoryPoint] = []
    @State private var selectedMetric: ChartMetricType = .maxWeight
    @State private var isLoading = true

    private var sortedPoints: [ExerciseHistoryPoint] {
        historyPoints.sorted { $0.date < $1.date }
    }

    private var isTimedExercise: Bool {
        historyPoints.allSatisfy { $0.maxWeight == 0 && $0.maxTime > 0 }
    }

    private var isBodyweightExercise: Bool {
        historyPoints.allSatisfy { $0.maxWeight == 0 && $0.avgReps > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if historyPoints.isEmpty {
                Text("No history data")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                // Metric selector
                metricPicker

                // Chart
                chartContent
                    .frame(height: 200)

                // Stats row
                statsRow
            }
        }
        .onAppear { loadHistory() }
    }

    // MARK: - Metric Picker

    private var availableMetrics: [ChartMetricType] {
        if isTimedExercise {
            return [.time]
        } else if isBodyweightExercise {
            return [.reps, .totalVolume]
        } else {
            return [.maxWeight, .totalVolume, .reps]
        }
    }

    @ViewBuilder
    private var metricPicker: some View {
        let metrics = availableMetrics
        if metrics.count > 1 {
            Picker("Metric", selection: $selectedMetric) {
                ForEach(metrics, id: \.self) { metric in
                    Text(metricLabel(metric)).tag(metric)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartContent: some View {
        let data = sortedPoints
        Chart(data, id: \.date) { point in
            let value = metricValue(for: point)
            LineMark(
                x: .value("Date", chartDate(point.date)),
                y: .value(metricLabel(selectedMetric), value)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(LiftMarkTheme.primary)

            PointMark(
                x: .value("Date", chartDate(point.date)),
                y: .value(metricLabel(selectedMetric), value)
            )
            .foregroundStyle(LiftMarkTheme.primary)

            AreaMark(
                x: .value("Date", chartDate(point.date)),
                y: .value(metricLabel(selectedMetric), value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [LiftMarkTheme.primary.opacity(0.2), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(data.count, 5)))
        }
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsRow: some View {
        let data = sortedPoints
        if data.count >= 2, let firstPoint = data.first, let lastPoint = data.last {
            let current = metricValue(for: lastPoint)
            let best = data.map { metricValue(for: $0) }.max() ?? current
            let first = metricValue(for: firstPoint)
            let change = first > 0 ? ((current - first) / first) * 100 : 0

            HStack(spacing: LiftMarkTheme.spacingMD) {
                StatItem(label: "Current", value: formatMetricValue(current))
                StatItem(label: "Best", value: formatMetricValue(best))
                StatItem(
                    label: "Change",
                    value: String(format: "%+.0f%%", change),
                    color: change > 0 ? LiftMarkTheme.success : change < 0 ? LiftMarkTheme.destructive : LiftMarkTheme.secondaryLabel
                )
            }
        }
    }

    // MARK: - Helpers

    private func loadHistory() {
        let repo = ExerciseHistoryRepository()
        do {
            historyPoints = try repo.getHistoryNormalized(forExercise: exerciseName)
            // Auto-select appropriate metric
            if isTimedExercise {
                selectedMetric = .time
            } else if isBodyweightExercise {
                selectedMetric = .reps
            }
        } catch {
            Logger.shared.error(.app, "Failed to load exercise history", error: error)
        }
        isLoading = false
    }

    private func metricValue(for point: ExerciseHistoryPoint) -> Double {
        switch selectedMetric {
        case .maxWeight: return point.maxWeight
        case .totalVolume: return point.totalVolume
        case .reps: return point.avgReps
        case .time: return point.maxTime
        }
    }

    private func metricLabel(_ metric: ChartMetricType) -> String {
        switch metric {
        case .maxWeight: return "Max Weight"
        case .totalVolume: return "Volume"
        case .reps: return "Reps"
        case .time: return "Time"
        }
    }

    private func formatMetricValue(_ value: Double) -> String {
        switch selectedMetric {
        case .maxWeight: return "\(Int(value))"
        case .totalVolume:
            if value >= 1000 {
                return String(format: "%.1fk", value / 1000)
            }
            return "\(Int(value))"
        case .reps: return String(format: "%.1f", value)
        case .time: return DurationFormat.mmss(Int(value))
        }
    }

    private func chartDate(_ dateString: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(dateString.prefix(10))) ?? Date()
    }
}

// MARK: - Stat Item

private struct StatItem: View {
    let label: String
    let value: String
    var color: Color = LiftMarkTheme.label

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.lmCaption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.lmSubheadline)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}

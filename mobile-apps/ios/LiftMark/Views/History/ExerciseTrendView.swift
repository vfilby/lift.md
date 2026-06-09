import SwiftUI

/// Collapsible view showing exercise trend chart inline in history detail.
struct ExerciseTrendView: View {
    let exerciseName: String
    var onShowDetails: (() -> Void)?
    @State private var isExpanded = false
    @State private var historyPoints: [ExerciseHistoryPoint] = []
    @State private var isLoading = false

    private var hasHistory: Bool {
        !isLoading && !historyPoints.isEmpty
    }

    private var trend: String {
        guard historyPoints.count >= 2 else { return "→" }
        let sorted = historyPoints.sorted { $0.date < $1.date }
        let recent = sorted.suffix(3).map(\.maxWeight)
        let older = sorted.prefix(3).map(\.maxWeight)
        let recentAvg = recent.reduce(0, +) / Double(recent.count)
        let olderAvg = older.reduce(0, +) / Double(older.count)
        if recentAvg > olderAvg * 1.02 { return "↗" }
        if recentAvg < olderAvg * 0.98 { return "↘" }
        return "→"
    }

    private var trendColor: Color {
        switch trend {
        case "↗": return LiftMarkTheme.success
        case "↘": return LiftMarkTheme.destructive
        default: return LiftMarkTheme.secondaryLabel
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            if isLoading {
                // Still loading — show nothing
            } else if historyPoints.isEmpty {
                // No history — disabled, non-tappable
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.lmCaption)
                    Text("No History")
                        .font(.lmCaption)
                    Spacer()
                }
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
            } else {
                // Has history — tappable toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.lmCaption)
                        Text(isExpanded ? "Hide trends" : "Show trends")
                            .font(.lmCaption)
                        Text(trend)
                            .foregroundStyle(trendColor)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.lmCaption)
                    }
                    .foregroundStyle(LiftMarkTheme.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trend-toggle-\(exerciseName)")

                if isExpanded {
                    // Inline chart
                    ExerciseHistoryChartView(exerciseName: exerciseName)
                        .transition(.opacity.combined(with: .move(edge: .top)))

                    // Details button
                    if let onShowDetails {
                        Button {
                            onShowDetails()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet")
                                    .font(.lmCaption)
                                Text("Details")
                                    .font(.lmSubheadline)
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, LiftMarkTheme.spacingSM)
                            .background(LiftMarkTheme.primary)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear {
            if historyPoints.isEmpty {
                loadHistory()
            }
        }
    }

    private func loadHistory() {
        isLoading = true
        let repo = ExerciseHistoryRepository()
        do {
            historyPoints = try repo.getHistoryNormalized(forExercise: exerciseName)
        } catch {
            Logger.shared.error(.app, "Failed to load trend data", error: error)
        }
        isLoading = false
    }
}

import SwiftUI

struct ExerciseHistoryLastSessionView: View {
    let exerciseName: String
    @State private var historyPoints: [ExerciseHistoryPoint] = []
    @State private var isLoading = true

    private var lastSession: ExerciseHistoryPoint? {
        historyPoints.sorted { $0.date > $1.date }.first
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if let session = lastSession {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
                    Text("Last Session")
                        .font(.lmHeadline)

                    VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
                        HStack {
                            Text("Date")
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            Spacer()
                            Text(formatDate(session.date))
                        }
                        .font(.lmSubheadline)

                        HStack {
                            Text("Workout")
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            Spacer()
                            Text(session.workoutName)
                        }
                        .font(.lmSubheadline)

                        if session.maxWeight > 0 {
                            HStack {
                                Text("Max Weight")
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                                Spacer()
                                Text("\(Int(session.maxWeight)) \(session.unit.rawValue)")
                            }
                            .font(.lmSubheadline)
                        }

                        HStack {
                            Text("Sets")
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            Spacer()
                            Text("\(session.setsCount)")
                        }
                        .font(.lmSubheadline)

                        if session.avgReps > 0 {
                            HStack {
                                Text("Avg Reps")
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                                Spacer()
                                Text(String(format: "%.1f", session.avgReps))
                            }
                            .font(.lmSubheadline)
                        }

                        if session.maxTime > 0 {
                            HStack {
                                Text("Max Time")
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                                Spacer()
                                Text(DurationFormat.mmss(Int(session.maxTime)))
                            }
                            .font(.lmSubheadline)
                        }

                        if session.totalVolume > 0 {
                            HStack {
                                Text("Volume")
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                                Spacer()
                                Text(formatVolume(session.totalVolume))
                            }
                            .font(.lmSubheadline)
                        }
                    }
                    .padding()
                    .background(LiftMarkTheme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                }
            } else {
                Text("No previous sessions")
                    .font(.lmSubheadline)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear { loadHistory() }
    }

    private func loadHistory() {
        let repo = ExerciseHistoryRepository()
        do {
            historyPoints = try repo.getHistoryNormalized(forExercise: exerciseName)
        } catch {
            Logger.shared.error(.app, "Failed to load exercise history", error: error)
        }
        isLoading = false
    }

    private func formatDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: String(dateString.prefix(10))) else {
            return dateString
        }
        let display = DateFormatter()
        display.dateStyle = .medium
        return display.string(from: date)
    }

    private func formatVolume(_ volume: Double) -> String {
        if volume >= 1000 {
            return String(format: "%.1fk", volume / 1000)
        }
        return "\(Int(volume))"
    }
}

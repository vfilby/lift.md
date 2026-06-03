import SwiftUI

/// iPad landscape sidebar showing exercise history for the currently active exercise.
struct ActiveWorkoutHistoryPanel: View {
    let activeExerciseName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Exercise History")
                .font(.lmHeadline)
                .padding()

            Divider()

            if let exerciseName = activeExerciseName {
                ScrollView {
                    VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                        Text(exerciseName)
                            .font(.lmTitle3)
                            .fontWeight(.semibold)

                        ExerciseHistoryChartView(exerciseName: exerciseName)
                            .padding()
                            .background(LiftMarkTheme.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))

                        ExerciseHistoryLastSessionView(exerciseName: exerciseName)
                    }
                    .padding()
                }
                .id(exerciseName) // Reset scroll when exercise changes
            } else {
                VStack(spacing: LiftMarkTheme.spacingMD) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.lmLargeTitle)
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                    Text("Complete sets to see exercise history")
                        .font(.lmSubheadline)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LiftMarkTheme.secondaryBackground.opacity(0.5))
    }
}

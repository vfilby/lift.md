import ActivityKit
import WidgetKit
import SwiftUI

struct LiveWorkoutsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            // Lock screen / banner UI
            lockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeading(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(context: context)
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                if let timerEnd = context.state.timerEndDate {
                    Text(timerEnd, style: .timer)
                        .font(.lmCaption.monospacedDigit())
                        .foregroundStyle(timerEnd > Date() ? .green : .red)
                } else {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.lmCaption.monospacedDigit())
                }
            } minimal: {
                Image(systemName: "dumbbell.fill")
                    .foregroundStyle(.blue)
            }
            .widgetURL(URL(string: "liftmark://workout"))
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<WorkoutActivityAttributes>) -> some View {
        let state = context.state

        if state.isRestTimer {
            // Rest timer layout
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Rest")
                        .font(.lmHeadline)
                    Spacer()
                    if let timerEnd = state.timerEndDate {
                        Text(timerEnd, style: .timer)
                            .font(.lmTitle2.monospacedDigit().bold())
                            .foregroundStyle(timerEnd > Date() ? .green : .red)
                    }
                }

                if let nextName = state.nextExerciseName {
                    HStack {
                        Text("Up Next: \(nextName)")
                            .font(.lmSubheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let detail = state.nextSetDetail {
                            Spacer()
                            Text(detail)
                                .font(.lmSubheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ProgressView(value: state.progress)
                    .tint(.blue)
            }
            .padding()
        } else {
            // Active set layout
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(state.exerciseName)
                        .font(.lmHeadline)
                        .lineLimit(1)
                    Spacer()
                    if !state.setInfo.isEmpty {
                        Text(state.setInfo)
                            .font(.lmSubheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if !state.weightReps.isEmpty {
                    Text(state.weightReps)
                        .font(.lmTitle3.monospacedDigit().bold())
                }

                HStack {
                    if let nextName = state.nextExerciseName {
                        Text("Next: \(nextName)")
                            .font(.lmCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(Int(state.progress * 100))%")
                        .font(.lmCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: state.progress)
                    .tint(.blue)
            }
            .padding()
        }
    }

    // MARK: - Dynamic Island Expanded

    @ViewBuilder
    private func expandedLeading(context: ActivityViewContext<WorkoutActivityAttributes>) -> some View {
        let state = context.state

        if state.isRestTimer {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rest")
                    .font(.lmHeadline)
                if let nextName = state.nextExerciseName {
                    Text("Next: \(nextName)")
                        .font(.lmCaption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.exerciseName)
                    .font(.lmHeadline)
                    .lineLimit(1)
                if !state.weightReps.isEmpty {
                    Text(state.setInfo.isEmpty ? state.weightReps : "\(state.setInfo) \u{2022} \(state.weightReps)")
                        .font(.lmCaption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func expandedTrailing(context: ActivityViewContext<WorkoutActivityAttributes>) -> some View {
        let state = context.state

        if let timerEnd = state.timerEndDate {
            Text(timerEnd, style: .timer)
                .font(.lmTitle3.monospacedDigit().bold())
                .foregroundStyle(timerEnd > Date() ? .green : .red)
        } else {
            Text("\(Int(state.progress * 100))%")
                .font(.lmTitle3.bold())
        }
    }

    @ViewBuilder
    private func expandedBottom(context: ActivityViewContext<WorkoutActivityAttributes>) -> some View {
        let state = context.state

        if state.isRestTimer, let detail = state.nextSetDetail {
            Text(detail)
                .font(.lmCaption2.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if !state.isRestTimer, let nextName = state.nextExerciseName {
            Text("Next: \(nextName)")
                .font(.lmCaption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview("Notification", as: .content, using: WorkoutActivityAttributes(workoutName: "Push Day")) {
    LiveWorkoutsLiveActivity()
} contentStates: {
    WorkoutActivityAttributes.ContentState(
        isRestTimer: false,
        exerciseName: "Bench Press",
        setInfo: "Set 2/4",
        weightReps: "185 lbs × 5",
        nextExerciseName: "Overhead Press",
        nextSetDetail: "135 lbs × 8",
        progress: 0.35
    )
    WorkoutActivityAttributes.ContentState(
        isRestTimer: true,
        exerciseName: "Rest",
        setInfo: "",
        weightReps: "",
        nextExerciseName: "Overhead Press",
        nextSetDetail: "135 lbs × 8",
        progress: 0.35,
        timerEndDate: Date().addingTimeInterval(90)
    )
}

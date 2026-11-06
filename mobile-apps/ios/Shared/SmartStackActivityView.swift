import SwiftUI

// Shared between main app and LiveWorkouts widget extension so the Apple Watch
// layout is covered by the app's unit tests (the extension has no test target).

/// Apple Watch Smart Stack (small activity family) layout for the workout Live Activity.
///
/// The Smart Stack card is a fixed size that varies by watch model and does not
/// grow to fit its content — anything taller spills over the next card in the
/// stack. The view therefore picks the richest layout that fits the height the
/// system offers; see spec/services/live-activities.md.
///
/// System fonts only: the watch renders this view on-device and the custom
/// fonts bundled in the widget extension are not available there.
struct SmartStackActivityView: View {
    enum Layout: CaseIterable {
        /// Three rows: header, then a grouped details block.
        case regular
        /// Two rows: header and a single details row.
        case compact
    }

    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        adaptiveContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The layout chosen for the offered height, without the fill frame.
    var adaptiveContent: some View {
        ViewThatFits(in: .vertical) {
            content(.regular)
            content(.compact)
        }
    }

    func content(_ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isRestTimer {
                restHeader
                Spacer(minLength: 4)
                restDetails(layout)
            } else {
                activeHeader
                Spacer(minLength: 4)
                activeDetails(layout)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    // MARK: Rest timer

    private var restHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Rest")
                .font(.headline)
            Spacer(minLength: 4)
            if let timerEnd = state.timerEndDate {
                Text(timerEnd, style: .timer)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(timerEnd > Date() ? .green : .red)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private func restDetails(_ layout: Layout) -> some View {
        if let nextName = state.nextExerciseName {
            switch layout {
            case .regular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("Next: \(nextName)")
                        .font(.footnote.weight(.semibold))
                    if let detail = state.nextSetDetail {
                        nextSetDetail(detail)
                    }
                }
            case .compact:
                HStack(alignment: .firstTextBaseline) {
                    Text(nextName)
                        .font(.footnote.weight(.semibold))
                    if let detail = state.nextSetDetail {
                        Spacer(minLength: 4)
                        nextSetDetail(detail)
                            .layoutPriority(1)
                    }
                }
            }
        }
    }

    private func nextSetDetail(_ detail: String) -> some View {
        Text(detail)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    // MARK: Active set

    private var activeHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(state.exerciseName)
                .font(.headline)
            Spacer(minLength: 4)
            if !state.setInfo.isEmpty {
                Text(state.setInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
        }
    }

    @ViewBuilder
    private func activeDetails(_ layout: Layout) -> some View {
        switch layout {
        case .regular:
            VStack(alignment: .leading, spacing: 1) {
                if !state.weightReps.isEmpty {
                    weightReps
                }
                HStack(alignment: .firstTextBaseline) {
                    if let nextName = state.nextExerciseName {
                        Text("Next: \(nextName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    progress
                }
            }
        case .compact:
            HStack(alignment: .firstTextBaseline) {
                if !state.weightReps.isEmpty {
                    weightReps
                }
                Spacer(minLength: 4)
                progress
            }
        }
    }

    private var weightReps: some View {
        Text(state.weightReps)
            .font(.body.monospacedDigit().bold())
            .layoutPriority(1)
    }

    private var progress: some View {
        Text("\(Int(state.progress * 100))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

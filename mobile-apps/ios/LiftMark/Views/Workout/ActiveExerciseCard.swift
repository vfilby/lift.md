import SwiftUI

struct ActiveExerciseCard: View {
    let exercise: SessionExercise
    let exerciseIndex: Int
    let displayNumber: Int
    let settings: UserSettings?
    let isCollapsed: Bool
    let activeRestTimer: RestTimerState?
    let onToggleCollapse: () -> Void
    let onCompleteSet: (Int, Double?, Int?, Int?) -> Void
    let onCompleteDropSet: ((Int, [(weight: Double?, weightUnit: WeightUnit?, reps: Int?)]) -> Void)?
    let onSkipSet: (Int) -> Void
    let onEditExercise: () -> Void
    let onSaveSet: (Int, Double?, Int?, Int?) -> Void
    let onUnlogSet: (Int) -> Void
    let onDismissRest: () -> Void
    var restTimerGeneration: Int = 0

    @State private var currentWeightText: String = ""

    private var currentSetIndex: Int? {
        exercise.sets.firstIndex { $0.status == .pending }
    }

    private var completedSetCount: Int {
        exercise.sets.filter { $0.status == .completed || $0.status == .skipped }.count
    }

    /// Collapsed-card summary. For single-set time- or distance-based
    /// exercises, show the actual/target value (e.g. "30:00", "5.2 km")
    /// instead of "1/1 sets" — that count carries no useful information for
    /// non-rep work.
    private var collapsedSummary: String {
        if exercise.sets.count == 1, let set = exercise.sets.first {
            let entry = set.entries.first
            let actual = entry?.actual
            let target = entry?.target
            let hasReps = (actual?.reps ?? target?.reps) != nil

            if !hasReps {
                if let time = actual?.time ?? target?.time {
                    return formatTimeSummary(time)
                }
                if let distance = actual?.distance ?? target?.distance {
                    return "\(formatDistance(distance.value)) \(distance.unit.rawValue)"
                }
            }
        }
        return "\(completedSetCount)/\(exercise.sets.count) sets"
    }

    private func formatTimeSummary(_ seconds: Int) -> String {
        DurationFormat.mmss(seconds)
    }

    private func formatDistance(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))" : String(format: "%.1f", value)
    }

    /// Aggregate tint reflecting the finalized state of all sets.
    /// Neutral while any set is still pending.
    private var cardTint: ExerciseCardTint {
        ExerciseCardTint.from(statuses: exercise.sets.map { $0.status })
    }

    /// The target time for the current pending set, if it's a timed set.
    private var currentTimedSetTarget: Int? {
        guard let idx = currentSetIndex else { return nil }
        guard let targetTime = exercise.sets[idx].entries.first?.target?.time, targetTime > 0 else { return nil }
        return targetTime
    }

    /// The stable identity for the current timed set (used to reset timer when set changes).
    private var currentTimedSetId: String? {
        guard let idx = currentSetIndex, currentTimedSetTarget != nil else { return nil }
        return exercise.sets[idx].id
    }

    /// Index of the set whose completion triggered the active rest timer.
    /// The timer renders directly below this set so it's visually anchored to
    /// the action that started it — even when the user has completed other
    /// sets out of order since (#123).
    private var restTimerSetIndex: Int? {
        guard let triggeringSetId = activeRestTimer?.triggeringSetId else { return nil }
        return exercise.sets.firstIndex { $0.id == triggeringSetId }
    }

    /// The active rest timer for this card, if it owns one. Extracted so it can
    /// render in two places: inline under the triggering set when the card is
    /// expanded, and under the header when the card is collapsed — otherwise
    /// completing the last set collapses the card and hides the timer the user
    /// just started (#212).
    @ViewBuilder
    private var restTimer: some View {
        if let restState = activeRestTimer {
            RestTimerView(totalSeconds: restState.seconds) {
                onDismissRest()
            }
            .id(restTimerGeneration)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            // Exercise header
            HStack(spacing: LiftMarkTheme.spacingSM) {
                // Collapse toggle — covers number + name + spacer
                Button {
                    onToggleCollapse()
                } label: {
                    HStack(spacing: LiftMarkTheme.spacingSM) {
                        Text("\(displayNumber)")
                            .font(.lmCaption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(dotFill)
                            .clipShape(Circle())

                        Text(exercise.exerciseName)
                            .font(.lmHeadline)
                            .foregroundStyle(
                                exercise.sets.allSatisfy({ $0.status == .completed || $0.status == .skipped })
                                    ? LiftMarkTheme.secondaryLabel : LiftMarkTheme.label)

                        Spacer()

                        if isCollapsed {
                            Text(collapsedSummary)
                                .font(.lmCaption)
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            Image(systemName: "chevron.right")
                                .font(.lmCaption)
                                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed
                    ? "Expand \(exercise.exerciseName), \(collapsedSummary)"
                    : "Collapse \(exercise.exerciseName)")
                .accessibilityHint(isCollapsed ? "Shows all sets for this exercise" : "Hides sets for this exercise")

                // Edit button — separate from collapse toggle for reliable tap handling
                if !isCollapsed {
                    Button {
                        onEditExercise()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.lmBody)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("edit-exercise-button-\(exerciseIndex)")
                    .accessibilityLabel("Edit \(exercise.exerciseName)")
                    .accessibilityHint("Opens editor for exercise name, notes, and sets")
                }
            }

            if !isCollapsed {
                // Notes — indented to align with title
                if let notes = exercise.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.lmCaption)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        .italic()
                        .padding(.leading, 32) // badge width + spacing
                }

                // Sets with inline rest placeholders and rest timer
                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { setIndex, set in
                    SetRowView(
                        set: set,
                        setNumber: setIndex + 1,
                        isCurrent: setIndex == currentSetIndex,
                        exerciseName: exercise.exerciseName,
                        equipmentType: exercise.equipmentType,
                        onComplete: { weight, reps, time in
                            onCompleteSet(setIndex, weight, reps, time)
                        },
                        onCompleteDropSet: set.isDropset ? { entries in
                            onCompleteDropSet?(setIndex, entries)
                        } : nil,
                        onSkip: { onSkipSet(setIndex) },
                        onSave: { weight, reps, time in
                            onSaveSet(setIndex, weight, reps, time)
                        },
                        onUnlog: { onUnlogSet(setIndex) },
                        onWeightChanged: setIndex == currentSetIndex ? { newWeight in
                            currentWeightText = newWeight
                        } : nil
                    )

                    // Timed-exercise timer — pinned directly under the active set
                    // so the timer reads as part of that set rather than the
                    // bottom of the exercise card. Keyed by setId so state
                    // resets when the active set advances.
                    if setIndex == currentSetIndex,
                       let targetTime = currentTimedSetTarget,
                       let setId = currentTimedSetId {
                        ExerciseTimerView(targetSeconds: targetTime) { elapsedSeconds in
                            let weight = Double(currentWeightText)
                            onCompleteSet(setIndex, weight, nil, elapsedSeconds)
                        }
                        .id(setId)
                    }

                    // Inline rest timer — placed directly under the set that
                    // triggered it (see restTimerSetIndex above). Only while the
                    // card is expanded; the collapsed copy below takes over
                    // otherwise (#212).
                    if let triggerIdx = restTimerSetIndex, setIndex == triggerIdx {
                        restTimer
                    }

                    // Rest placeholder between pending sets
                    if set.status == .pending,
                       let rest = set.restSeconds, rest > 0,
                       setIndex < exercise.sets.count - 1,
                       setIndex != currentSetIndex {
                        HStack(spacing: LiftMarkTheme.spacingSM) {
                            Rectangle()
                                .fill(LiftMarkTheme.tertiaryLabel.opacity(0.3))
                                .frame(height: 1)
                                .accessibilityHidden(true)
                            Text("Rest \(DurationFormat.mmss(rest))")
                                .font(.lmCaption2)
                                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                            Rectangle()
                                .fill(LiftMarkTheme.tertiaryLabel.opacity(0.3))
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Rest \(rest) seconds between sets")
                    }
                }

                // YouTube search — bottom of expanded card
                if let url = youtubeSearchURL(for: exercise.exerciseName) {
                    Divider()
                    Link(destination: url) {
                        HStack(spacing: LiftMarkTheme.spacingSM) {
                            Image(systemName: "play.rectangle")
                                .font(.lmCaption)
                                .accessibilityHidden(true)
                            Text("Search \"\(exercise.exerciseName)\" on YouTube")
                                .font(.lmCaption)
                        }
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .accessibilityIdentifier("youtube-link-\(exercise.exerciseName)")
                    .accessibilityLabel("Search \(exercise.exerciseName) form videos on YouTube")
                    .accessibilityHint("Opens YouTube in your browser")
                }
            }

            // When the card is collapsed the inline timer above is hidden along
            // with the sets. Surface the owned rest timer under the header so it
            // stays visible after the triggering set completes and the card
            // auto-collapses (#212).
            if isCollapsed {
                restTimer
            }
        }
        .padding()
        .background {
            ZStack {
                LiftMarkTheme.secondaryBackground
                cardTint.backgroundOverlay
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exercise-card-\(exerciseIndex)")
        .accessibilityValue(cardTint.accessibilityDescription ?? "")
    }

    /// Fill for the numbered exercise dot. When every set is finalized, the
    /// dot reflects the aggregate set state — bright green (all logged), amber
    /// (all skipped), or a left/right split (mixed). While the exercise is
    /// still in progress or untouched, falls back to the per-exercise status
    /// color so the dot reads as primary/tertiary as before.
    private var dotFill: AnyShapeStyle {
        switch cardTint {
        case .completed:
            return AnyShapeStyle(LiftMarkTheme.success)
        case .skipped:
            return AnyShapeStyle(LiftMarkTheme.warning)
        case .mixed:
            return AnyShapeStyle(
                LinearGradient(
                    stops: [
                        .init(color: LiftMarkTheme.success, location: 0),
                        .init(color: LiftMarkTheme.success, location: 0.375),
                        .init(color: LiftMarkTheme.warning, location: 0.625),
                        .init(color: LiftMarkTheme.warning, location: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .neutral:
            return AnyShapeStyle(neutralDotColor)
        }
    }

    private var neutralDotColor: Color {
        switch exercise.status {
        case .completed: return LiftMarkTheme.success
        case .inProgress: return LiftMarkTheme.primary
        case .skipped: return LiftMarkTheme.warning
        case .pending: return LiftMarkTheme.tertiaryLabel
        }
    }

    private func youtubeSearchURL(for name: String) -> URL? {
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return URL(string: "https://www.youtube.com/results?search_query=\(query)+form")
    }
}

import SwiftUI

struct SupersetCard: View {
    let parentExercise: SessionExercise
    let children: [(exercise: SessionExercise, exerciseIndex: Int, displayNumber: Int)]
    let settings: UserSettings?
    let isCollapsed: Bool
    let activeRestTimer: RestTimerState?
    let onToggleCollapse: () -> Void
    let onCompleteSet: (Int, Int, Double?, Int?, Int?) -> Void  // exerciseIndex, setIndex, weight, reps, time
    let onCompleteDropSet: ((Int, Int, [(weight: Double?, weightUnit: WeightUnit?, reps: Int?)]) -> Void)?
    let onSkipSet: (Int, Int) -> Void  // exerciseIndex, setIndex
    let onSaveSet: (Int, Int, Double?, Int?, Int?) -> Void  // exerciseIndex, setIndex, weight, reps, time
    let onUnlogSet: (Int, Int) -> Void  // exerciseIndex, setIndex
    let onDismissRest: () -> Void
    var restTimerGeneration: Int = 0

    /// Weight text from the currently editing set, captured so the inline
    /// ExerciseTimerView can submit it on Done. Mirrors ActiveExerciseCard.
    @State private var currentWeightText: String = ""

    private var allSetsCompleted: Bool {
        children.allSatisfy { child in
            child.exercise.sets.allSatisfy { $0.status == .completed || $0.status == .skipped }
        }
    }

    /// Aggregate tint across all child exercises. Treats the superset as a
    /// single unit: neutral while any child set is still pending.
    private var cardTint: ExerciseCardTint {
        let allStatuses = children.flatMap { $0.exercise.sets.map { $0.status } }
        return ExerciseCardTint.from(statuses: allStatuses)
    }

    private var completedSetCount: Int {
        children.reduce(0) { sum, child in
            sum + child.exercise.sets.filter { $0.status == .completed || $0.status == .skipped }.count
        }
    }

    private var totalSetCount: Int {
        children.reduce(0) { $0 + $1.exercise.sets.count }
    }

    /// Build interleaved sets: round-robin across children
    private var interleavedSets: [(exercise: SessionExercise, exerciseIndex: Int, set: SessionSet, setIndex: Int)] {
        let maxSets = children.map { $0.exercise.sets.count }.max() ?? 0
        var result: [(exercise: SessionExercise, exerciseIndex: Int, set: SessionSet, setIndex: Int)] = []
        for round in 0..<maxSets {
            for child in children {
                if round < child.exercise.sets.count {
                    result.append((
                        exercise: child.exercise,
                        exerciseIndex: child.exerciseIndex,
                        set: child.exercise.sets[round],
                        setIndex: round
                    ))
                }
            }
        }
        return result
    }

    /// The last completed/skipped set across all children
    private var lastCompletedSetId: String? {
        let allSets = interleavedSets
        for item in allSets.reversed() {
            if item.set.status == .completed || item.set.status == .skipped {
                return item.set.id
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            // Superset header
            Button {
                onToggleCollapse()
            } label: {
                HStack(spacing: LiftMarkTheme.spacingSM) {
                    // Purple superset icon
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.purple)
                        .clipShape(Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("SUPERSET")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple)
                            .clipShape(Capsule())
                        Text(supersetTitle)
                            .font(.headline)
                            .foregroundStyle(allSetsCompleted ? LiftMarkTheme.secondaryLabel : LiftMarkTheme.label)
                        Text(children.map { "\($0.displayNumber). \($0.exercise.exerciseName)" }.joined(separator: " + "))
                            .font(.caption)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    }

                    Spacer()

                    if isCollapsed {
                        Text("\(completedSetCount)/\(totalSetCount) sets")
                            .font(.caption)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand superset, \(completedSetCount) of \(totalSetCount) sets done" : "Collapse superset")
            .accessibilityHint(isCollapsed ? "Shows all interleaved sets" : "Hides sets for this superset")

            if !isCollapsed {
                // Per-child notes — shown once at the top of the expanded card
                // so descriptions/instructions aren't lost inside a superset.
                ForEach(children, id: \.exercise.id) { child in
                    if let notes = child.exercise.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(child.exercise.exerciseName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                                .italic()
                        }
                        .padding(.leading, 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Interleaved sets
                let interleaved = interleavedSets
                let firstPendingSetId = interleaved.first(where: { $0.set.status == .pending })?.set.id
                ForEach(Array(interleaved.enumerated()), id: \.element.set.id) { idx, item in
                    let isCurrent = item.set.id == firstPendingSetId

                    // Exercise name label for each set
                    Text(item.exercise.exerciseName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        .padding(.leading, 32)

                    SetRowView(
                        set: item.set,
                        setNumber: item.setIndex + 1,
                        isCurrent: isCurrent,
                        exerciseName: item.exercise.exerciseName,
                        equipmentType: item.exercise.equipmentType,
                        onComplete: { weight, reps, time in
                            onCompleteSet(item.exerciseIndex, item.setIndex, weight, reps, time)
                        },
                        onCompleteDropSet: item.set.isDropset ? { entries in
                            onCompleteDropSet?(item.exerciseIndex, item.setIndex, entries)
                        } : nil,
                        onSkip: { onSkipSet(item.exerciseIndex, item.setIndex) },
                        onSave: { weight, reps, time in
                            onSaveSet(item.exerciseIndex, item.setIndex, weight, reps, time)
                        },
                        onUnlog: { onUnlogSet(item.exerciseIndex, item.setIndex) },
                        onWeightChanged: isCurrent ? { newWeight in
                            currentWeightText = newWeight
                        } : nil
                    )

                    // Timed-exercise timer — pinned directly under the active
                    // set, identical to ActiveExerciseCard. Without this block
                    // a timed set inside a superset has no countdown UI and
                    // can't be re-timed after being skipped + unlogged.
                    if isCurrent,
                       let targetTime = item.set.entries.first?.target?.time, targetTime > 0 {
                        ExerciseTimerView(targetSeconds: targetTime) { elapsedSeconds in
                            let weight = Double(currentWeightText)
                            onCompleteSet(item.exerciseIndex, item.setIndex, weight, nil, elapsedSeconds)
                        }
                        .id(item.set.id)
                    }

                    // Rest timer after last completed set
                    if let lastId = lastCompletedSetId, item.set.id == lastId,
                       let restState = activeRestTimer {
                        RestTimerView(totalSeconds: restState.seconds) {
                            onDismissRest()
                        }
                        .id(restTimerGeneration)
                    }
                }

                // YouTube search — one link per child. Each row has a 44pt
                // minimum height so adjacent links are independent tap targets.
                Divider()
                VStack(spacing: 16) {
                    ForEach(children, id: \.exercise.id) { child in
                        if let url = youtubeSearchURL(for: child.exercise.exerciseName) {
                            Link(destination: url) {
                                HStack(spacing: LiftMarkTheme.spacingSM) {
                                    Image(systemName: "play.rectangle")
                                        .font(.caption)
                                        .accessibilityHidden(true)
                                    Text("Search \"\(child.exercise.exerciseName)\" on YouTube")
                                        .font(.caption)
                                }
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                                .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .accessibilityIdentifier("youtube-link-\(child.exercise.exerciseName)")
                            .accessibilityLabel("Search \(child.exercise.exerciseName) form videos on YouTube")
                            .accessibilityHint("Opens YouTube in your browser")
                        }
                    }
                }
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
        .opacity(allSetsCompleted ? 0.6 : 1.0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("superset-card-\(parentExercise.exerciseName)")
        .accessibilityValue(cardTint.accessibilityDescription ?? "")
    }

    private func youtubeSearchURL(for name: String) -> URL? {
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return URL(string: "https://www.youtube.com/results?search_query=\(query)+form")
    }

    private var supersetTitle: String {
        let name = parentExercise.exerciseName
        if name.lowercased().hasPrefix("superset") {
            return name
        }
        return "Superset"
    }
}

import SwiftUI

/// Read-only preview of an inbox workout, presented as a sheet on row tap
/// from `InboxSectionView`. See `spec/services/workout-inbox.md` (the row
/// actions table) — this is the "tap a row" surface that's been in the spec
/// since v1 but was deferred.
///
/// Why a dedicated read-only view (vs. reusing `WorkoutDetailView`)?
/// `WorkoutDetailView` is bound to a `planStore`-resident plan and exposes
/// edit affordances. The inbox preview shows a workout that has NOT been
/// promoted yet — there is no plan row in the local DB to edit. Wiring a
/// transient `WorkoutPlan` through `WorkoutDetailView` would mean either
/// inserting/deleting around the sheet (state churn) or refactoring the
/// detail view to accept an in-memory plan. A purpose-built read-only
/// renderer is cheaper.
///
/// The three footer actions are owned by the parent — this view just
/// invokes the closures and dismisses; the parent does the queue/server
/// reconciliation. Same handlers as the swipe + context-menu surfaces in
/// `InboxSectionView`.
struct InboxPreviewSheet: View {
    let workout: InboxWorkout
    let createdAtServer: Date
    let sourceTokenId: String?
    let onDiscard: () -> Void
    let onAddToPlans: () -> Void
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                    headerCard
                    ForEach(Array(workout.exercises.enumerated()), id: \.offset) { _, exercise in
                        exerciseCard(exercise)
                    }
                }
                .padding(LiftMarkTheme.spacingMD)
            }
            .background(LiftMarkTheme.secondaryBackground.ignoresSafeArea())
            .navigationTitle(workout.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("inbox-preview-close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionFooter
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            HStack(spacing: LiftMarkTheme.spacingSM) {
                Label(
                    "\(workout.exercises.count) exercise\(workout.exercises.count == 1 ? "" : "s")",
                    systemImage: "figure.strengthtraining.traditional"
                )
                .font(.subheadline)
                Spacer()
                Label("\(totalSetCount) set\(totalSetCount == 1 ? "" : "s")", systemImage: "list.number")
                    .font(.subheadline)
            }
            .foregroundStyle(LiftMarkTheme.secondaryLabel)

            if let tags = workout.tags, !tags.isEmpty {
                FlowingTagRow(tags: tags)
            }

            if let unit = workout.defaultWeightUnit {
                Text("Default unit: \(unit)")
                    .font(.caption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }

            if let description = workout.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(LiftMarkTheme.label)
                    .padding(.top, 4)
            }

            Text(receivedFootnote)
                .font(.caption)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .padding(.top, 2)
        }
        .padding(LiftMarkTheme.spacingMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiftMarkTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
    }

    private var totalSetCount: Int {
        workout.exercises.reduce(0) { $0 + $1.sets.count }
    }

    private var receivedFootnote: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: createdAtServer, relativeTo: Date())
        if let sourceTokenId, sourceTokenId != "session" {
            let prefix = String(sourceTokenId.prefix(8))
            return "Received \(when) · token \(prefix)…"
        }
        return "Received \(when)"
    }

    // MARK: - Exercise card

    @ViewBuilder
    private func exerciseCard(_ exercise: InboxExercise) -> some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            // Group badge (superset / section) — renders EmptyView when not grouped.
            groupBadge(for: exercise)

            HStack(alignment: .firstTextBaseline, spacing: LiftMarkTheme.spacingSM) {
                Text(exercise.exerciseName)
                    .font(.headline)
                Spacer()
                Text("\(exercise.sets.count) set\(exercise.sets.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }

            if let equipment = exercise.equipmentType, !equipment.isEmpty {
                Text(equipment)
                    .font(.caption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }

            if let notes = exercise.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }

            if !exercise.sets.isEmpty {
                Divider()
                ForEach(Array(exercise.sets.enumerated()), id: \.offset) { idx, set in
                    setRow(index: idx + 1, set: set, defaultUnit: workout.defaultWeightUnit)
                }
            }
        }
        .padding(LiftMarkTheme.spacingMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiftMarkTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
    }

    @ViewBuilder
    private func groupBadge(for exercise: InboxExercise) -> some View {
        switch exercise.groupType {
        case "superset":
            Text("SUPERSET")
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(.purple)
                .background(Color.purple.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case "section":
            Text((exercise.groupName ?? "Section").uppercased())
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(LiftMarkTheme.primary)
                .background(LiftMarkTheme.primary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        default:
            EmptyView()
        }
    }

    // MARK: - Set row

    private func setRow(index: Int, set: InboxSet, defaultUnit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LiftMarkTheme.spacingSM) {
            Text("\(index)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .frame(minWidth: 18, alignment: .leading)
            Text(setDescription(set, defaultUnit: defaultUnit))
                .font(.callout)
                .foregroundStyle(LiftMarkTheme.label)
            Spacer(minLength: 4)
            modifierChips(set)
        }
        .padding(.vertical, 2)
    }

    private func setDescription(_ set: InboxSet, defaultUnit: String?) -> String {
        // Time-only sets render as duration; weighted sets render as "wt unit × reps".
        if let time = set.targetTime, set.targetWeight == nil, set.targetReps == nil {
            return formatDuration(time)
        }
        var parts: [String] = []
        if let w = set.targetWeight {
            let unit = set.targetWeightUnit ?? defaultUnit ?? ""
            let weightStr = w == w.rounded() ? String(Int(w)) : String(w)
            parts.append(weightStr + (unit.isEmpty ? "" : " \(unit)"))
        }
        if let reps = set.targetReps {
            let repsLabel = (set.isAmrap ?? false) ? "AMRAP" : "\(reps) rep\(reps == 1 ? "" : "s")"
            parts.append(parts.isEmpty ? repsLabel : "× \(repsLabel)")
        } else if set.isAmrap ?? false {
            parts.append("× AMRAP")
        }
        if let time = set.targetTime {
            parts.append(formatDuration(time))
        }
        if let rpe = set.targetRpe {
            parts.append("RPE \(rpe)")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        return "\(seconds)s"
    }

    @ViewBuilder
    private func modifierChips(_ set: InboxSet) -> some View {
        HStack(spacing: 4) {
            if set.isDropset ?? false { chip("drop") }
            if set.isPerSide ?? false { chip("per-side") }
            if let rest = set.restSeconds, rest > 0 { chip("rest \(formatDuration(rest))") }
            if let tempo = set.tempo, !tempo.isEmpty { chip("tempo \(tempo)") }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(LiftMarkTheme.secondaryLabel)
            .background(LiftMarkTheme.secondaryBackground)
            .clipShape(Capsule())
    }

    // MARK: - Footer

    private var actionFooter: some View {
        VStack(spacing: LiftMarkTheme.spacingSM) {
            Divider()
            HStack(spacing: LiftMarkTheme.spacingSM) {
                Button(role: .destructive) {
                    onDiscard()
                    dismiss()
                } label: {
                    Label("Discard", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("inbox-preview-discard")

                Button {
                    onAddToPlans()
                    dismiss()
                } label: {
                    Label("Add", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("inbox-preview-add")

                Button {
                    onStart()
                    dismiss()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityIdentifier("inbox-preview-start")
            }
            .padding(.horizontal, LiftMarkTheme.spacingMD)
            .padding(.bottom, LiftMarkTheme.spacingSM)
            .padding(.top, 4)
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Tag row

/// Minimal flowing-tag display for the header. Wraps tags onto multiple
/// lines automatically. Lifted here (rather than into Theme) to keep the
/// scope tight — if more views want it, hoist later.
private struct FlowingTagRow: View {
    let tags: [String]

    var body: some View {
        // SwiftUI's HStack doesn't wrap; for a small set of short tags a
        // single line that may clip is acceptable in v1.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LiftMarkTheme.primary.opacity(0.12))
                        .foregroundStyle(LiftMarkTheme.primary)
                        .clipShape(Capsule())
                }
            }
        }
    }
}

import SwiftUI

// MARK: - Display Models

enum PlanDisplayItem: Identifiable {
    case single(exercise: PlannedExercise)
    case superset(parent: PlannedExercise, children: [PlannedExercise])

    var id: String {
        switch self {
        case .single(let exercise): return exercise.id
        case .superset(let parent, _): return parent.id
        }
    }
}

struct ExerciseDisplaySection {
    let name: String?
    let items: [PlanDisplayItem]
}

// MARK: - Display Builder

/// Pure grouping logic that turns a plan's flat exercise list into the
/// sectioned display items rendered by `WorkoutDetailView`.
enum PlanDisplayBuilder {
    /// Group exercises by section (warmup, cooldown, default) then build display items
    static func sections(for plan: WorkoutPlan) -> [ExerciseDisplaySection] {
        var sections: [ExerciseDisplaySection] = []
        var currentSectionName: String?
        var currentExercises: [PlannedExercise] = []

        for exercise in plan.exercises {
            let sectionName: String?
            if exercise.groupType == .section {
                sectionName = exercise.groupName
            } else if exercise.parentExerciseId != nil {
                // Children of sections/supersets stay in the current section
                sectionName = currentSectionName
            } else {
                sectionName = nil
            }

            if sectionName != currentSectionName {
                if !currentExercises.isEmpty {
                    sections.append(ExerciseDisplaySection(
                        name: currentSectionName,
                        items: displayItems(from: currentExercises)
                    ))
                }
                currentSectionName = sectionName
                currentExercises = []
            }
            currentExercises.append(exercise)
        }
        if !currentExercises.isEmpty {
            sections.append(ExerciseDisplaySection(
                name: currentSectionName,
                items: displayItems(from: currentExercises)
            ))
        }
        return sections
    }

    /// Build display items from a flat list of exercises, grouping supersets
    static func displayItems(from exercises: [PlannedExercise]) -> [PlanDisplayItem] {
        var items: [PlanDisplayItem] = []
        var processedIds = Set<String>()

        for exercise in exercises {
            if processedIds.contains(exercise.id) { continue }

            if exercise.groupType == .superset && exercise.sets.isEmpty {
                items.append(contentsOf: supersetItems(
                    parent: exercise, in: exercises, processedIds: &processedIds
                ))
            } else if exercise.parentExerciseId != nil {
                // Skip orphan children already handled
                continue
            } else if exercise.groupType == .section && exercise.sets.isEmpty {
                items.append(contentsOf: sectionItems(
                    header: exercise, in: exercises, processedIds: &processedIds
                ))
            } else {
                items.append(.single(exercise: exercise))
                processedIds.insert(exercise.id)
            }
        }
        return items
    }

    /// Superset parent — gather children into a `.superset` item. A
    /// single-member superset is not a real superset — render the lone child
    /// as a standalone exercise (no SUPERSET badge), matching the active
    /// workout view.
    private static func supersetItems(
        parent: PlannedExercise,
        in exercises: [PlannedExercise],
        processedIds: inout Set<String>
    ) -> [PlanDisplayItem] {
        var children: [PlannedExercise] = []
        for child in exercises where child.parentExerciseId == parent.id {
            children.append(child)
            processedIds.insert(child.id)
        }
        processedIds.insert(parent.id)
        if SupersetGrouping.isRealSuperset(childCount: children.count) {
            return [.superset(parent: parent, children: children)]
        }
        return children.map { .single(exercise: $0) }
    }

    /// Section header — gather children. A child that is itself a superset
    /// parent must recurse so grandchildren render inside PlanSupersetCard;
    /// otherwise the superset parent (no sets) shows as an empty single card
    /// and grandchildren are dropped.
    private static func sectionItems(
        header: PlannedExercise,
        in exercises: [PlannedExercise],
        processedIds: inout Set<String>
    ) -> [PlanDisplayItem] {
        var items: [PlanDisplayItem] = []
        processedIds.insert(header.id)
        for child in exercises {
            guard child.parentExerciseId == header.id else { continue }
            if child.groupType == .superset && child.sets.isEmpty {
                items.append(contentsOf: supersetItems(
                    parent: child, in: exercises, processedIds: &processedIds
                ))
            } else {
                items.append(.single(exercise: child))
                processedIds.insert(child.id)
            }
        }
        return items
    }
}

// MARK: - Section Color Helper

func workoutSectionColor(for name: String) -> Color {
    switch name.lowercased() {
    case "warmup", "warm-up", "warm up": return LiftMarkTheme.warmupAccent
    case "cooldown", "cool-down", "cool down": return LiftMarkTheme.cooldownAccent
    default: return LiftMarkTheme.primary
    }
}

// MARK: - Set Detail Formatting

func planSetDetailString(_ set: PlannedSet) -> String {
    let target = set.entries.first?.target
    var parts: [String] = []

    if let weight = target?.weight?.value, let unit = target?.weight?.unit {
        parts.append("\(planFormatWeight(weight)) \(unit.rawValue)")
    }

    if let reps = target?.reps {
        let amrapSuffix = set.isAmrap ? "+" : ""
        parts.append("× \(reps)\(amrapSuffix) reps")
    } else if set.isAmrap {
        parts.append("AMRAP")
    }

    if let time = target?.time {
        parts.append(planFormatTime(time))
    }

    var detail = parts.joined(separator: " ")

    // Inline modifiers
    if let rpe = target?.rpe {
        detail += " · RPE \(rpe)"
    }

    if let rest = set.restSeconds, rest > 0 {
        detail += " · Rest \(rest)s"
    }

    return detail
}

func planFormatWeight(_ weight: Double) -> String {
    weight.formattedWeight
}

func planFormatTime(_ seconds: Int) -> String {
    let minutes = seconds / 60
    let secs = seconds % 60
    return minutes > 0 ? String(format: "%d:%02d", minutes, secs) : "\(secs)s"
}

// MARK: - Stat Card

struct WorkoutStatCard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.lmTitle2)
                .fontWeight(.bold)
                .foregroundStyle(LiftMarkTheme.primary)
                .monospacedDigit()
            Text(label)
                .font(.lmCaption)
                .fontWeight(.medium)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LiftMarkTheme.spacingLG)
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
    }
}

// MARK: - Section Header

struct WorkoutSectionHeader: View {
    let name: String

    var body: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Rectangle()
                .fill(workoutSectionColor(for: name))
                .frame(height: 1)
            Text(name.uppercased())
                .font(.lmSubheadline)
                .fontWeight(.semibold)
                .foregroundStyle(workoutSectionColor(for: name))
                .tracking(1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Rectangle()
                .fill(workoutSectionColor(for: name))
                .frame(height: 1)
        }
        .padding(.vertical, LiftMarkTheme.spacingSM)
    }
}

// MARK: - Exercise Card

struct PlanExerciseCard: View {
    let exercise: PlannedExercise
    let sectionName: String?
    let exerciseIndex: Int
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
            // Exercise header
            HStack(alignment: .top, spacing: LiftMarkTheme.spacingMD) {
                // Numbered index
                Text("\(exerciseIndex)")
                    .font(.lmCallout)
                    .fontWeight(.bold)
                    .foregroundStyle(workoutSectionColor(for: sectionName ?? ""))
                    .frame(minWidth: 20)

                VStack(alignment: .leading, spacing: 2) {
                    // No SUPERSET badge here: a standalone card is only used for
                    // real (non-grouped) exercises and single-member supersets.
                    // A single-member superset is not a real superset (nothing to
                    // alternate with), so it renders as a plain exercise — matching
                    // the active workout view. Real supersets (2+ members) render
                    // via PlanSupersetCard, which carries the badge.

                    // Exercise name
                    Text(exercise.exerciseName)
                        .font(.lmCallout)
                        .fontWeight(.semibold)

                    // Equipment
                    if let equipment = exercise.equipmentType {
                        Text(equipment)
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    }

                    // Notes
                    if let notes = exercise.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            .italic()
                    }
                }

                Spacer()

                // Edit button
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .font(.lmBody)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                // Name-based so UI tests can target a specific exercise's edit
                // button (the id is a random UUID). Mirrors `youtube-link-<name>`
                // below.
                .accessibilityIdentifier("edit-plan-exercise-\(exercise.exerciseName)")
            }

            // Sets
            VStack(spacing: 0) {
                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { setIndex, set in
                    HStack(spacing: LiftMarkTheme.spacingMD) {
                        // Set badge (colored circle)
                        Text("\(set.orderIndex + 1)")
                            .font(.lmCaption)
                            .fontWeight(.bold)
                            .foregroundStyle(workoutSectionColor(for: sectionName ?? ""))
                            .frame(width: 28, height: 28)
                            .background(workoutSectionColor(for: sectionName ?? "").opacity(0.12))
                            .clipShape(Circle())

                        // Set details
                        Text(planSetDetailString(set))
                            .font(.lmBody)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)

                        Spacer()

                        // Modifier badges
                        if set.isDropset {
                            Text("Drop")
                                .font(.lmCaption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(LiftMarkTheme.destructive.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        if set.isPerSide {
                            Text("/side")
                                .font(.lmCaption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(LiftMarkTheme.primary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("set-\(set.id)")

                    if setIndex < exercise.sets.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.leading, 32)

            // YouTube search
            if let url = youtubeSearchURL(for: exercise.exerciseName) {
                Divider()
                Link(destination: url) {
                    HStack(spacing: LiftMarkTheme.spacingSM) {
                        Image(systemName: "play.rectangle")
                            .font(.lmCaption)
                        Text("Search \"\(exercise.exerciseName)\" on YouTube")
                            .font(.lmCaption)
                    }
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .accessibilityIdentifier("youtube-link-\(exercise.exerciseName)")
            }
        }
        .padding()
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exercise-\(exercise.id)")
    }

    private func youtubeSearchURL(for exerciseName: String) -> URL? {
        let query = exerciseName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? exerciseName
        return URL(string: "https://www.youtube.com/results?search_query=\(query)+form")
    }
}

// MARK: - Superset Card

struct PlanSupersetCard: View {
    let parent: PlannedExercise
    let children: [PlannedExercise]
    let sectionName: String?
    /// Plan-wide 1-based number for a member exercise, so nested cards share the
    /// same numbering scheme as standalone exercises.
    var exerciseIndex: (PlannedExercise) -> Int = { _ in 0 }
    /// Edit a single member exercise.
    var onEditChild: (PlannedExercise) -> Void = { _ in }
    /// Edit the superset grouping itself (the parent).
    var onEdit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
            // Superset header — the purple superset accent (used app-wide) tints
            // the group frame so it reads distinctly from the neutral exercise
            // cards nested inside it.
            HStack(spacing: LiftMarkTheme.spacingSM) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.lmCaption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.purple)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("SUPERSET · \(children.count) EXERCISES")
                        .font(.lmCaption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.purple)

                    Text(parent.exerciseName)
                        .font(.lmCallout)
                        .fontWeight(.semibold)
                }

                Spacer()

                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.lmBody)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("edit-plan-superset-\(parent.id)")
                    .accessibilityLabel("Edit superset \(parent.exerciseName)")
                }
            }

            // Each member renders with the standard PlanExerciseCard template, so
            // set numbering, notes, badges and styling stay identical to
            // standalone exercises. The nested cards just live inside the
            // superset frame — sets stay grouped per exercise (no interleaving).
            VStack(spacing: LiftMarkTheme.spacingSM) {
                ForEach(children, id: \.id) { child in
                    PlanExerciseCard(
                        exercise: child,
                        sectionName: sectionName,
                        exerciseIndex: exerciseIndex(child),
                        onEdit: { onEditChild(child) }
                    )
                    // Hairline border so each member card reads distinctly against
                    // the purple tint — their pale fill alone is too close to the
                    // tint's lightness in light mode.
                    .overlay(
                        RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD)
                            .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                    )
                }
            }
        }
        .padding()
        .background(Color.purple.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .overlay(
            RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD)
                .stroke(Color.purple.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("superset-card-\(parent.id)")
    }
}

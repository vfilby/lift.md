import SwiftUI

/// Reusable exercise display card used in workout detail, summary, and history views.
struct ExerciseCardView: View {
    let exercise: PlannedExercise
    let sectionLabel: String?
    let supersetIndex: Int?

    init(exercise: PlannedExercise, sectionLabel: String? = nil, supersetIndex: Int? = nil) {
        self.exercise = exercise
        self.sectionLabel = sectionLabel
        self.supersetIndex = supersetIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            // Section label (Warmup, Cooldown, etc.)
            if let sectionLabel {
                Text(sectionLabel)
                    .font(.caption.bold())
                    .textCase(.uppercase)
                    .foregroundStyle(sectionColor(for: sectionLabel))
            }

            // Superset badge
            if let supersetIndex {
                Text("Superset \(supersetIndex + 1)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(LiftMarkTheme.primary.opacity(0.15))
                    .foregroundStyle(LiftMarkTheme.primary)
                    .clipShape(Capsule())
                    .accessibilityIdentifier("superset-\(supersetIndex)")
            }

            // Exercise header
            HStack(alignment: .firstTextBaseline) {
                Text(exercise.exerciseName)
                    .font(.headline)

                if let equipment = exercise.equipmentType {
                    Text(equipment)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LiftMarkTheme.secondaryBackground)
                        .clipShape(Capsule())
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                }

                Spacer()
            }

            // Notes
            if let notes = exercise.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .italic()
            }

            // Sets
            ForEach(exercise.sets) { set in
                SetDisplayRow(set: set)
                    .accessibilityIdentifier("set-\(set.id)")
            }
        }
        .padding()
        .background(LiftMarkTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        .accessibilityIdentifier("exercise-\(exercise.id)")
    }

    private func sectionColor(for label: String) -> Color {
        switch label.lowercased() {
        case "warmup": return LiftMarkTheme.warmupAccent
        case "cooldown": return LiftMarkTheme.cooldownAccent
        default: return LiftMarkTheme.secondaryLabel
        }
    }
}

/// Displays a single planned set in a detail view context.
private struct SetDisplayRow: View {
    let set: PlannedSet

    var body: some View {
        let target = set.entries.first?.target

        HStack(spacing: LiftMarkTheme.spacingSM) {
            // Set number
            Text("Set \(set.orderIndex + 1)")
                .font(.subheadline)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .frame(width: 50, alignment: .leading)

            // Weight
            if let weight = target?.weight?.value, let unit = target?.weight?.unit {
                Text("\(formatWeight(weight)) \(unit.rawValue)")
                    .font(.subheadline.monospacedDigit())
            }

            // Reps
            if let reps = target?.reps {
                Text("x \(reps)\(set.isAmrap ? "+" : "")")
                    .font(.subheadline.monospacedDigit())
            } else if set.isAmrap {
                Text("AMRAP")
                    .font(.subheadline.monospacedDigit())
            }

            // Time
            if let time = target?.time {
                Text(formatTime(time))
                    .font(.subheadline.monospacedDigit())
            }

            Spacer()

            // Modifiers
            HStack(spacing: 4) {
                if let rpe = target?.rpe {
                    Text("RPE \(rpe)")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(LiftMarkTheme.warning.opacity(0.15))
                        .clipShape(Capsule())
                }

                if set.isDropset {
                    Text("Drop")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(LiftMarkTheme.destructive.opacity(0.15))
                        .clipShape(Capsule())
                }

                if set.isPerSide {
                    Text("/side")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(LiftMarkTheme.primary.opacity(0.15))
                        .clipShape(Capsule())
                }

                if let rest = set.restSeconds, rest > 0 {
                    Text("\(rest)s rest")
                        .font(.caption2)
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                }

                if let tempo = set.tempo {
                    Text(tempo)
                        .font(.caption2)
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                }
            }
        }
    }

    private func formatWeight(_ w: Double) -> String {
        w.formattedWeight
    }

    private func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return m > 0 ? "\(m):\(String(format: "%02d", s))" : "\(s)s"
    }
}

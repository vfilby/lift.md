import SwiftUI

/// Custom alignment to vertically center the indicator and skip button on the text fields.
extension VerticalAlignment {
    private enum TextFieldCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }
    static let textFieldCenter = VerticalAlignment(TextFieldCenter.self)
}

/// Individual set row in the active workout view.
/// Handles display for pending, current, completed, and skipped states.
struct SetRowView: View {
    // Non-private so the weight helpers in SetRowView+Weight.swift can read it.
    @Environment(SettingsStore.self) var settingsStore

    let set: SessionSet
    let setNumber: Int
    let isCurrent: Bool
    let exerciseName: String
    let equipmentType: String?
    let onComplete: (Double?, Int?, Int?) -> Void
    var onCompleteDropSet: ((_ entries: [(weight: Double?, weightUnit: WeightUnit?, reps: Int?)]) -> Void)?
    let onSkip: () -> Void
    let onSave: (Double?, Int?, Int?) -> Void
    var onUnlog: (() -> Void)?
    var onWeightChanged: ((String) -> Void)?

    // The input-field state below is non-private so the row-content helpers in
    // SetRowView+CurrentSet.swift, SetRowView+CompletedRow.swift, and
    // SetRowView+DropSet.swift (split out for SwiftLint's file/type-length
    // limits) can read and mutate it.
    @State var weightText: String = ""
    @State var repsText: String = ""
    @State var timeText: String = ""
    @State var isEditing = false
    /// User tapped "add weight" on a set that started without a weight
    /// (reps-only / bodyweight). Reveals the weight field inline so a weight
    /// can be logged without editing the exercise definition (GH #194).
    /// Non-private so the weight helpers in SetRowView+Weight.swift can set it.
    @State var isAddingWeight = false
    /// Additional drop entries (groupIndex > 0). Each pair is (weight, reps) text.
    @State var dropEntries: [(weight: String, reps: String)] = []

    var body: some View {
        Group {
            if isCurrent {
                currentSetContent
            } else {
                HStack(spacing: LiftMarkTheme.spacingSM) {
                    // Set number indicator
                    setIndicator

                    // Side label for per-side sets (Left/Right) — between indicator and data
                    if let side = set.side {
                        Text(side.capitalized)
                            .font(.lmCaption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(LiftMarkTheme.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LiftMarkTheme.primary.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    completedOrPendingContent
                }
            }
        }
        .padding(.vertical, LiftMarkTheme.spacingXS)
        .padding(.horizontal, LiftMarkTheme.spacingSM)
        .background(isCurrent ? LiftMarkTheme.primary.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM))
        .onAppear {
            let target = set.entries.first?.target
            let actual = set.entries.first?.actual
            if let weight = target?.weight?.value ?? actual?.weight?.value {
                weightText = formatWeight(weight)
                onWeightChanged?(weightText)
            }
            if let reps = target?.reps ?? actual?.reps {
                repsText = "\(reps)"
            }
            if let time = target?.time ?? actual?.time {
                timeText = DurationFormat.mmss(time)
            }
        }
    }

    /// Step size for +/- buttons. Coarser steps for long holds so users
    /// aren't tapping 12 times to add a minute.
    var timeStepSeconds: Int {
        let time = set.entries.first?.target?.time ?? set.entries.first?.actual?.time ?? 0
        return time >= 90 ? 30 : 5
    }

    // MARK: - Set Number Indicator

    @ViewBuilder
    var setIndicator: some View {
        ZStack {
            switch set.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LiftMarkTheme.success)
                    .font(.lmTitle3)
            case .skipped:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(LiftMarkTheme.warning)
                    .font(.lmTitle3)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(LiftMarkTheme.destructive)
                    .font(.lmTitle3)
            case .pending:
                if isCurrent {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(LiftMarkTheme.primary)
                        .font(.lmTitle3)
                } else {
                    Text("\(setNumber)")
                        .font(.lmCaption.bold())
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                }
            }
        }
        .frame(width: 28)
        .accessibilityLabel("Set \(setNumber), \(setStatusDescription)")
    }

    // MARK: - Helpers

    /// Plate math text for barbell exercises, computed from current weight input.
    var plateMathText: String? {
        let target = set.entries.first?.target
        guard target?.weight != nil,
              PlateCalculator.isBarbellExercise(exerciseName: exerciseName, equipmentType: equipmentType)
        else { return nil }

        guard let weight = Double(weightText), weight > 0 else { return nil }

        let unit = target?.weight?.unit.rawValue ?? "lbs"
        let breakdown = PlateCalculator.calculatePlates(totalWeight: weight, unit: unit)

        // Don't show if weight is less than bar
        guard breakdown.isAchievable || !breakdown.plates.isEmpty else { return nil }

        return PlateCalculator.formatCompletePlateSetup(breakdown)
    }

    var valuesChangedFromTarget: Bool {
        let target = set.entries.first?.target
        if let tw = target?.weight?.value {
            if Double(weightText) != tw { return true }
        }
        if let tr = target?.reps {
            if Int(repsText) != tr { return true }
        }
        return false
    }

    var targetHint: String? {
        let target = set.entries.first?.target
        var parts: [String] = []
        if let weight = target?.weight?.value {
            let unit = target?.weight?.unit.rawValue ?? ""
            parts.append("\(formatWeight(weight)) \(unit)")
        }
        if let reps = target?.reps {
            parts.append("× \(reps)")
        }
        guard !parts.isEmpty else { return nil }
        return "Target: \(parts.joined(separator: " "))"
    }

    /// Step increment for weight stepper buttons. The user's configured step tier
    /// (stored as its lbs value: 2.5 = fine, 5 = coarse) maps to a unit-appropriate
    /// value: lbs uses the tier directly; kg uses 1.25 (fine) or 2.5 (coarse).
    var weightStepIncrement: Double {
        let unit = effectiveWeightUnit
        let tier = settingsStore.settings?.defaultWeightStepLbs ?? 2.5
        if unit == .kg {
            return tier >= 5.0 ? 2.5 : 1.25
        }
        return tier
    }

    /// Adjusts the main weight field by the given delta, clamped to 0.
    func adjustWeight(by delta: Double) {
        let current = Double(weightText) ?? 0
        let newWeight = max(0, current + delta)
        weightText = formatWeight(newWeight)
        onWeightChanged?(weightText)
    }

    /// Adjusts the main reps field by the given delta, clamped to 0.
    func adjustReps(by delta: Int) {
        let current = Int(repsText) ?? 0
        repsText = "\(max(0, current + delta))"
    }

    /// Adjusts the main time field by the given delta, clamped to 0.
    func adjustTime(by delta: Int) {
        let current = DurationFormat.parse(timeText) ?? 0
        timeText = DurationFormat.mmss(max(0, current + delta))
    }

    func formatWeight(_ weight: Double) -> String {
        weight.formattedWeight
    }
}

private extension SetRowView {
    var setStatusDescription: String {
        switch set.status {
        case .completed: return "completed"
        case .skipped: return "skipped"
        case .failed: return "failed"
        case .pending: return isCurrent ? "current" : "pending"
        }
    }
}

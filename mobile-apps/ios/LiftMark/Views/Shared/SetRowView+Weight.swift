import SwiftUI

/// Weight-field helpers for `SetRowView`, split out so the main view stays
/// within SwiftLint's file/type-length limits. Backs the "add weight on a
/// reps-only set" affordance (GH #194).
extension SetRowView {
    /// Whether this set already carries a weight (target or actual).
    /// `self.` qualifies `set` so the body isn't parsed as a `set` accessor.
    var hasWeight: Bool {
        self.set.entries.first?.target?.weight != nil
            || self.set.entries.first?.actual?.weight != nil
    }

    /// Whether the weight field should be shown: the set has a weight, or the
    /// user tapped "add weight" on a reps-only/bodyweight set.
    var showsWeightField: Bool { hasWeight || isAddingWeight }

    /// The unit to log against. Falls back to the user's default so a weight
    /// added to a previously unitless (reps-only) set is stored sensibly.
    var effectiveWeightUnit: WeightUnit {
        self.set.entries.first?.target?.weight?.unit
            ?? self.set.entries.first?.actual?.weight?.unit
            ?? settingsStore.settings?.defaultWeightUnit
            ?? .lbs
    }

    var weightUnitLabel: String {
        " (\(effectiveWeightUnit.rawValue))"
    }

    /// Compact "add weight" control shown on reps-only/bodyweight sets that
    /// reveals the weight field when tapped.
    var addWeightButton: some View {
        Button {
            isAddingWeight = true
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "plus.circle")
                    .font(.lmCaption)
                Text("Weight")
                    .font(.lmCaption2)
            }
            .foregroundStyle(LiftMarkTheme.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("set-add-weight-button")
        .accessibilityLabel("Add weight")
        .accessibilityHint("Reveals a weight field for this set")
    }
}

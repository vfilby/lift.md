import SwiftUI

/// Drop-set entry rows (additional drops, groupIndex > 0) for `SetRowView`,
/// split out so the main view stays within SwiftLint's file/type-length limits.
extension SetRowView {
    // MARK: - Drop Entry Row

    @ViewBuilder
    func dropEntryRow(index: Int) -> some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            // Drop arrow indicator
            Image(systemName: "arrow.turn.down.right")
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.destructive)
                .frame(width: 28)

            Text("Drop \(index + 1)")
                .font(.lmCaption2)
                .fontWeight(.semibold)
                .foregroundStyle(LiftMarkTheme.destructive)

            if set.entries.first?.target?.weight != nil {
                dropWeightControls(index: index)

                Text("\u{00D7}")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }

            dropRepsControls(index: index)

            Spacer()

            // Delete drop button
            Button {
                dropEntries.remove(at: index)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.lmBody)
                    .foregroundStyle(LiftMarkTheme.destructive.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove drop \(index + 1)")
        }
        .padding(.leading, LiftMarkTheme.spacingSM)
    }

    // MARK: - Drop Entry Inputs

    private func dropWeightControls(index: Int) -> some View {
        HStack(spacing: 2) {
            Button { adjustDropWeight(index: index, by: -weightStepIncrement) } label: {
                Image(systemName: "minus.circle")
                    .font(.lmBody)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decrease drop \(index + 1) weight by \(formatWeight(weightStepIncrement))")

            TextField("--", text: Binding(
                get: { dropEntries[index].weight },
                set: { dropEntries[index].weight = $0 }
            ))
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .font(.lmBody.monospacedDigit())
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)

            Button { adjustDropWeight(index: index, by: weightStepIncrement) } label: {
                Image(systemName: "plus.circle")
                    .font(.lmBody)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Increase drop \(index + 1) weight by \(formatWeight(weightStepIncrement))")
        }
    }

    private func dropRepsControls(index: Int) -> some View {
        HStack(spacing: 2) {
            Button { adjustDropReps(index: index, by: -1) } label: {
                Image(systemName: "minus.circle")
                    .font(.lmCallout)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decrease drop \(index + 1) reps by 1")

            TextField("--", text: Binding(
                get: { dropEntries[index].reps },
                set: { dropEntries[index].reps = $0 }
            ))
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .font(.lmBody.monospacedDigit())
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .frame(width: 50)

            Button { adjustDropReps(index: index, by: 1) } label: {
                Image(systemName: "plus.circle")
                    .font(.lmCallout)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Increase drop \(index + 1) reps by 1")
        }
    }

    // MARK: - Drop Entry Adjustment

    /// Adjusts a drop entry's reps field by the given delta, clamped to 0.
    private func adjustDropReps(index: Int, by delta: Int) {
        guard index >= 0 && index < dropEntries.count else { return }
        let current = Int(dropEntries[index].reps) ?? 0
        dropEntries[index].reps = "\(max(0, current + delta))"
    }

    /// Adjusts a drop entry's weight field by the given delta, clamped to 0.
    private func adjustDropWeight(index: Int, by delta: Double) {
        guard index >= 0 && index < dropEntries.count else { return }
        let current = Double(dropEntries[index].weight) ?? 0
        let newWeight = max(0, current + delta)
        dropEntries[index].weight = formatWeight(newWeight)
    }
}

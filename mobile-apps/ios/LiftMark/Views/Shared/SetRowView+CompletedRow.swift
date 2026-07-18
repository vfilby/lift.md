import SwiftUI

/// Completed/pending/skipped row content and the inline edit form for
/// `SetRowView`, split out so the main view stays within SwiftLint's
/// file/type-length limits.
extension SetRowView {
    // MARK: - Completed / Pending Set

    @ViewBuilder
    var completedOrPendingContent: some View {
        if isEditing && (set.status == .completed || set.status == .skipped) {
            // Inline edit form
            inlineEditContent
        } else {
            Button {
                if set.status == .completed || set.status == .skipped {
                    // Don't allow inline edit for multi-entry drop sets (too complex)
                    let actualEntries = set.entries.filter { $0.actual != nil }
                    guard !(set.isDropset && actualEntries.count > 1) else { return }

                    isEditing.toggle()
                    // Initialize edit fields with current values
                    let target = set.entries.first?.target
                    let actual = set.entries.first?.actual
                    if let weight = actual?.weight?.value ?? target?.weight?.value {
                        weightText = formatWeight(weight)
                    }
                    if let reps = actual?.reps ?? target?.reps {
                        repsText = "\(reps)"
                    }
                    if let time = actual?.time ?? target?.time {
                        timeText = formatTimeText(time)
                    }
                }
            } label: {
                if set.status == .completed && set.isDropset {
                    completedDropSetContent
                } else {
                    HStack(spacing: LiftMarkTheme.spacingSM) {
                        if set.status == .completed {
                            normalCompletedContent
                        } else if set.status == .skipped {
                            // Show target values + "-- Skipped"
                            let target = set.entries.first?.target
                            if let weight = target?.weight?.value, let unit = target?.weight?.unit {
                                Text("\(formatWeight(weight)) \(unit.rawValue)")
                                    .font(.lmSubheadline.monospacedDigit())
                                    .foregroundStyle(LiftMarkTheme.warning)
                            }
                            if let reps = target?.reps {
                                Text("\u{00D7} \(reps)")
                                    .font(.lmSubheadline.monospacedDigit())
                                    .foregroundStyle(LiftMarkTheme.warning)
                            }
                            Text("-- Skipped")
                                .font(.lmSubheadline)
                                .foregroundStyle(LiftMarkTheme.warning)

                            Spacer()

                            modifierBadges
                        } else {
                            // Pending - show targets
                            let target = set.entries.first?.target
                            if let weight = target?.weight?.value, let unit = target?.weight?.unit {
                                Text("\(formatWeight(weight)) \(unit.rawValue)")
                                    .font(.lmSubheadline.monospacedDigit())
                                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                            }
                            if let reps = target?.reps {
                                Text("\u{00D7} \(reps)")
                                    .font(.lmSubheadline.monospacedDigit())
                                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                            }
                            if let time = target?.time {
                                Text(formatTime(time))
                                    .font(.lmSubheadline.monospacedDigit())
                                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                            }

                            Spacer()

                            modifierBadges
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Inline Edit (completed/skipped sets)

    @ViewBuilder
    private var inlineEditContent: some View {
        HStack(alignment: .textFieldCenter, spacing: LiftMarkTheme.spacingSM) {
            if showsWeightField {
                VStack(alignment: .center, spacing: 2) {
                    Text("Weight\(weightUnitLabel)")
                        .font(.lmCaption2)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    TextField("--", text: $weightText)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .font(.lmBody.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
                }

                // Show × separator only for non-timed sets (weighted reps)
                if set.entries.first?.target?.time == nil {
                    Text("×")
                        .font(.lmCaption)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
                }
            } else {
                // Reps-only / bodyweight set logged without a weight: let the
                // user add one while editing (GH #194).
                addWeightButton
                    .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
            }

            // Reps field — only for non-timed sets
            if set.entries.first?.target?.time == nil {
                VStack(alignment: .center, spacing: 2) {
                    Text("Reps")
                        .font(.lmCaption2)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    TextField("--", text: $repsText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .font(.lmBody.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
                }
            }

            // Time input — editable for timed sets in inline edit
            if set.entries.first?.actual?.time != nil || set.entries.first?.target?.time != nil {
                VStack(alignment: .center, spacing: 2) {
                    Text(timeFieldLabel)
                        .font(.lmCaption2)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    TextField("--", text: $timeText)
                        #if os(iOS)
                        .keyboardType(useMinuteTimeFormat ? .numbersAndPunctuation : .numberPad)
                        #endif
                        .font(.lmBody.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: timeFieldWidth)
                        .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
                }
            }

            Spacer()

            // Overflow menu — destructive set actions (skip / clear log) live
            // here rather than as bare buttons to keep the edit row uncluttered.
            Menu {
                Button {
                    onSkip()
                    isEditing = false
                } label: {
                    Label("Mark as Skipped", systemImage: "forward.end")
                }
                if let onUnlog {
                    Button(role: .destructive) {
                        onUnlog()
                        isEditing = false
                    } label: {
                        Label("Clear Log", systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.lmBody)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle()
                            .stroke(LiftMarkTheme.tertiaryLabel, lineWidth: 1)
                    )
            }
            .accessibilityLabel("More set actions")
            .accessibilityHint("Mark as skipped or clear the log for this set")
            .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }

            // Update button
            Button {
                onSave(Double(weightText), Int(repsText), parseTimeText(timeText))
                isEditing = false
            } label: {
                Image(systemName: "checkmark")
                    .font(.lmBody.bold())
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(LiftMarkTheme.primary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save changes")
            .accessibilityHint("Updates this set with the edited values")
            .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }

            // Cancel button
            Button {
                isEditing = false
            } label: {
                Image(systemName: "xmark")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle()
                            .stroke(LiftMarkTheme.tertiaryLabel, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel editing")
            .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
        }
    }

    // MARK: - Completed Drop Set Display

    /// Compact display for completed drop sets: "225x10 -> 185x6 -> 135x4"
    @ViewBuilder
    private var completedDropSetContent: some View {
        let actualEntries = set.entries.filter { $0.actual != nil }
        if actualEntries.count > 1 {
            HStack(spacing: 4) {
                ForEach(Array(actualEntries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.lmCaption2)
                            .foregroundStyle(LiftMarkTheme.success.opacity(0.6))
                    }
                    HStack(spacing: 2) {
                        if let weight = entry.actual?.weight?.value {
                            Text(formatWeight(weight))
                                .font(.lmSubheadline.monospacedDigit())
                                .foregroundStyle(LiftMarkTheme.success)
                        }
                        if let reps = entry.actual?.reps {
                            Text("\u{00D7}\(reps)")
                                .font(.lmSubheadline.monospacedDigit())
                                .foregroundStyle(LiftMarkTheme.success)
                        }
                    }
                }

                Spacer()

                modifierBadges
            }
        } else {
            // Single entry or no entries — fall back to normal display
            normalCompletedContent
        }
    }

    /// Standard single-entry completed content (extracted from completedOrPendingContent)
    @ViewBuilder
    private var normalCompletedContent: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            let actual = set.entries.first?.actual
            if let weight = actual?.weight?.value, let unit = actual?.weight?.unit {
                Text("\(formatWeight(weight)) \(unit.rawValue)")
                    .font(.lmSubheadline.monospacedDigit())
                    .foregroundStyle(LiftMarkTheme.success)
            }
            if let reps = actual?.reps {
                Text("\u{00D7} \(reps)")
                    .font(.lmSubheadline.monospacedDigit())
                    .foregroundStyle(LiftMarkTheme.success)
            }
            if let time = actual?.time {
                Text(formatTime(time))
                    .font(.lmSubheadline.monospacedDigit())
                    .foregroundStyle(LiftMarkTheme.success)
            }

            Spacer()

            modifierBadges
        }
    }

    // MARK: - Modifier Badges

    @ViewBuilder
    private var modifierBadges: some View {
        HStack(spacing: 4) {
            if set.isDropset {
                modifierBadge("Drop", color: LiftMarkTheme.destructive)
            }
            if set.isAmrap {
                modifierBadge("AMRAP", color: LiftMarkTheme.primary)
            }
            // /side badge for non-expanded per-side sets — expanded Left/Right shown inline before data
            if set.isPerSide && set.side == nil {
                modifierBadge("/side", color: LiftMarkTheme.primary)
            }
        }
    }

    private func modifierBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.lmCaption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

}

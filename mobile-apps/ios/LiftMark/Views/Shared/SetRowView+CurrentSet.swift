import SwiftUI

/// The editable "current set" row content for `SetRowView`, split out so the
/// main view stays within SwiftLint's file/type-length limits.
extension SetRowView {
    // MARK: - Current Set (Editable)

    @ViewBuilder
    var currentSetContent: some View {
        VStack(spacing: LiftMarkTheme.spacingSM) {
            // Plate math info — barbell exercises only (above weight × reps)
            if let plateMathText = plateMathText {
                HStack(spacing: 6) {
                    Image(systemName: "scalemass")
                        .font(.lmCaption)
                        .accessibilityHidden(true)
                    Text(plateMathText)
                        .font(.lmCallout)
                }
                .foregroundStyle(Color.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .overlay(
                    Rectangle()
                        .frame(width: 3)
                        .foregroundStyle(Color.blue.opacity(0.4)),
                    alignment: .leading
                )
                .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusXS))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Plate loading: \(plateMathText)")
            }

            // Top row: indicator + inputs + skip
            HStack(alignment: .textFieldCenter, spacing: LiftMarkTheme.spacingSM) {
                setIndicator
                    .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }

                // Side label for per-side sets (Left/Right)
                if let side = set.side {
                    Text(side.capitalized)
                        .font(.lmCaption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(LiftMarkTheme.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(LiftMarkTheme.primary.opacity(0.1))
                        .clipShape(Capsule())
                        .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
                }

                // Weight input — shown for weighted exercises, or when the user
                // taps "add weight" on a reps-only/bodyweight set (GH #194).
                if showsWeightField {
                    VStack(alignment: .center, spacing: 2) {
                        Text("Weight\(weightUnitLabel)")
                            .font(.lmCaption2)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        HStack(spacing: 2) {
                            Button { adjustWeight(by: -weightStepIncrement) } label: {
                                Image(systemName: "minus.circle")
                                    .font(.lmBody)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Decrease weight by \(formatWeight(weightStepIncrement))")

                            TextField("--", text: $weightText)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .font(.lmTitle3.monospacedDigit())
                                .multilineTextAlignment(.center)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                                .onChange(of: weightText) { _, newValue in
                                    onWeightChanged?(newValue)
                                }

                            Button { adjustWeight(by: weightStepIncrement) } label: {
                                Image(systemName: "plus.circle")
                                    .font(.lmBody)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Increase weight by \(formatWeight(weightStepIncrement))")
                        }
                        .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
                    }

                    // Show × separator only when reps follow (not for weighted-timed sets)
                    if set.entries.first?.target?.time == nil {
                        Text("×")
                            .font(.lmCallout)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
                    }
                } else {
                    // Reps-only / bodyweight set: offer to add a weight inline.
                    addWeightButton
                        .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
                }

                // Time input — for all timed exercises (including weighted-timed)
                if set.entries.first?.target?.time != nil {
                    VStack(alignment: .center, spacing: 2) {
                        Text(timeFieldLabel)
                            .font(.lmCaption2)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        HStack(spacing: 2) {
                            Button { adjustTime(by: -timeStepSeconds) } label: {
                                Image(systemName: "minus.circle")
                                    .font(.lmCallout)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Decrease time by \(timeStepSeconds) seconds")

                            TextField("--", text: $timeText)
                                #if os(iOS)
                                .keyboardType(useMinuteTimeFormat ? .numbersAndPunctuation : .numberPad)
                                #endif
                                .font(.lmTitle3.monospacedDigit())
                                .multilineTextAlignment(.center)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: timeFieldWidth)

                            Button { adjustTime(by: timeStepSeconds) } label: {
                                Image(systemName: "plus.circle")
                                    .font(.lmCallout)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Increase time by \(timeStepSeconds) seconds")
                        }
                        .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
                    }
                }

                // Reps input — only for non-timed exercises
                if set.entries.first?.target?.time == nil {
                    VStack(alignment: .center, spacing: 2) {
                        Text("Reps")
                            .font(.lmCaption2)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        HStack(spacing: 2) {
                            Button { adjustReps(by: -1) } label: {
                                Image(systemName: "minus.circle")
                                    .font(.lmCallout)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Decrease reps by 1")

                            TextField("--", text: $repsText)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .font(.lmTitle3.monospacedDigit())
                                .multilineTextAlignment(.center)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)

                            Button { adjustReps(by: 1) } label: {
                                Image(systemName: "plus.circle")
                                    .font(.lmCallout)
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Increase reps by 1")
                        }
                        .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
                    }
                }

                Spacer()

                // Skip button
                Button {
                    onSkip()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.lmBody)
                        .foregroundStyle(LiftMarkTheme.warning)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("set-skip-button")
                .accessibilityLabel("Skip set \(setNumber)")
                .accessibilityHint("Marks this set as skipped")
                .alignmentGuide(.textFieldCenter) { dims in dims[VerticalAlignment.center] }
            }

            // Drop set entries (additional drops, groupIndex > 0)
            if set.isDropset && !dropEntries.isEmpty {
                ForEach(Array(dropEntries.enumerated()), id: \.offset) { index, _ in
                    dropEntryRow(index: index)
                }
            }

            // "+ Drop" button for drop sets
            if set.isDropset {
                Button {
                    // Auto-decrement weight by 5 lbs from previous entry
                    let prevWeightStr = dropEntries.last?.weight ?? weightText
                    let prevWeight = Double(prevWeightStr) ?? 0
                    let droppedWeight = max(0, prevWeight - 5)
                    let newWeight = droppedWeight.truncatingRemainder(dividingBy: 1) == 0
                        ? "\(Int(droppedWeight))" : String(format: "%.1f", droppedWeight)

                    // Pre-fill reps with remaining count (target - sum of entered reps)
                    let targetReps = set.entries.first?.target?.reps ?? 0
                    let primaryReps = Int(repsText) ?? 0
                    let dropRepsSum = dropEntries.compactMap { Int($0.reps) }.reduce(0, +)
                    let remaining = max(0, targetReps - primaryReps - dropRepsSum)
                    let newReps = remaining > 0 ? "\(remaining)" : ""

                    dropEntries.append((weight: newWeight, reps: newReps))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.lmSubheadline.bold())
                        Text("Add Drop")
                            .font(.lmSubheadline.bold())
                    }
                    .foregroundStyle(LiftMarkTheme.destructive)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(LiftMarkTheme.destructive.opacity(0.1))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(LiftMarkTheme.destructive.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("add-drop-button")
                .accessibilityLabel("Add drop")
                .accessibilityHint("Adds another weight reduction entry to this drop set")
            }

            // Middle row: target hint — always reserve space, show when values differ from target
            if let target = targetHint {
                Text(target)
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                    .opacity(valuesChangedFromTarget ? 1 : 0)
            }

            // Bottom row: complete button — hide for timed sets (completed via ExerciseTimerView Done)
            if set.entries.first?.target?.time == nil {
                Button {
                    if set.isDropset && !dropEntries.isEmpty, let callback = onCompleteDropSet {
                        // Build all entries: primary + drops
                        let weightUnit = set.entries.first?.target?.weight?.unit
                        var allEntries: [(weight: Double?, weightUnit: WeightUnit?, reps: Int?)] = [
                            (weight: Double(weightText), weightUnit: weightUnit, reps: Int(repsText))
                        ]
                        for drop in dropEntries {
                            allEntries.append(
                                (weight: Double(drop.weight), weightUnit: weightUnit, reps: Int(drop.reps)))
                        }
                        callback(allEntries)
                    } else {
                        onComplete(Double(weightText), Int(repsText), parseTimeText(timeText))
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.lmFootnote.bold())
                        Text("Complete Set")
                            .font(.lmFootnote.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Capsule())
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(LiftMarkTheme.success)
                .accessibilityIdentifier("set-complete-button")
                .accessibilityLabel("Complete set \(setNumber)")
                .accessibilityHint("Records this set with the entered weight and reps")
            }
        }
    }

}

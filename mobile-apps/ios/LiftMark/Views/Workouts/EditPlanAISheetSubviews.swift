import SwiftUI

// MARK: - Transcript message

/// One transcript row: user text right-aligned, assistant summary + diff
/// left-aligned, errors in the destructive tint. See
/// `spec/screens/workout-detail.md` ("AI Edit Sheet").
struct PlanEditMessageView: View {
    let message: PlanEditMessage
    /// True for the newest assistant message; only that diff carries the
    /// `ai-edit-diff` identifier.
    let isLatest: Bool

    var body: some View {
        switch message.content {
        case .user(let text):
            HStack {
                Spacer(minLength: LiftMarkTheme.spacingXL)
                Text(text)
                    .font(.lmBody)
                    .foregroundStyle(.white)
                    .padding(.horizontal, LiftMarkTheme.spacingMD)
                    .padding(.vertical, LiftMarkTheme.spacingSM)
                    .background(LiftMarkTheme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
            }
        case .assistant(let summary, let diff, let warnings):
            HStack {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
                    Text(summary)
                        .font(.lmBody)
                        .foregroundStyle(LiftMarkTheme.label)
                    PlanDiffView(diff: diff, isLatest: isLatest)
                    if !warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.lmCaption2)
                                    .foregroundStyle(LiftMarkTheme.warning)
                            }
                        }
                    }
                }
                .padding(LiftMarkTheme.spacingMD)
                .background(LiftMarkTheme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                Spacer(minLength: LiftMarkTheme.spacingXL)
            }
        case .error(let error):
            HStack(alignment: .top, spacing: LiftMarkTheme.spacingSM) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LiftMarkTheme.destructive)
                Text(error.userFacingMessage)
                    .font(.lmSubheadline)
                    .foregroundStyle(LiftMarkTheme.destructive)
                    .accessibilityIdentifier("ai-edit-error")
                Spacer()
            }
            .padding(LiftMarkTheme.spacingMD)
            .background(LiftMarkTheme.destructive.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
        }
    }
}

// MARK: - Diff

/// Exercise-level diff: one row per added/removed/changed exercise, header
/// changes listed first, unchanged exercises collapsed to one line.
struct PlanDiffView: View {
    let diff: PlanDiff
    var isLatest = true

    private var rows: [PlanDiffRowPresentation] {
        diff.changedEntries.compactMap(PlanDiffRowPresentation.init(entry:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
            if diff.isEmpty {
                Text(PlanEditLabels.noChanges)
                    .font(.lmSubheadline)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            } else {
                ForEach(diff.headerChanges, id: \.self) { change in
                    Label(change, systemImage: "doc.text")
                        .font(.lmSubheadline)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                }
                ForEach(rows, id: \.slug) { row in
                    PlanDiffRowView(row: row)
                }
                if diff.unchangedCount > 0 {
                    Text(PlanEditLabels.unchangedSummary(count: diff.unchangedCount))
                        .font(.lmCaption)
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isLatest ? "ai-edit-diff" : "ai-edit-diff-previous")
    }
}

struct PlanDiffRowView: View {
    let row: PlanDiffRowPresentation

    private var tint: Color {
        switch row.kind {
        case .added: return LiftMarkTheme.success
        case .removed: return LiftMarkTheme.destructive
        case .changed: return LiftMarkTheme.warning
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: LiftMarkTheme.spacingSM) {
            Text(row.kind.marker)
                .font(.lmMono)
                .fontWeight(.bold)
                .foregroundStyle(tint)
                .frame(width: 14, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: LiftMarkTheme.spacingXS) {
                    Text(row.name)
                        .font(.lmSubheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(row.kind == .removed ? LiftMarkTheme.secondaryLabel : LiftMarkTheme.label)
                        .strikethrough(row.kind == .removed)
                    if let parent = row.parent {
                        Text("in \(parent)")
                            .font(.lmCaption2)
                            .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                    }
                }
                if row.kind == .changed {
                    setLines(row.previousLines, color: LiftMarkTheme.secondaryLabel, strike: true)
                }
                setLines(row.lines, color: LiftMarkTheme.secondaryLabel, strike: row.kind == .removed)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    @ViewBuilder
    private func setLines(_ lines: [String], color: Color, strike: Bool) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.lmCaption)
                        .foregroundStyle(color)
                        .strikethrough(strike)
                }
            }
        }
    }
}

// MARK: - Quick-action chips

struct PlanEditChipsRow: View {
    let isEnabled: Bool
    let onTap: (PlanEditQuickAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LiftMarkTheme.spacingSM) {
                ForEach(PlanEditQuickAction.all) { action in
                    Button {
                        onTap(action)
                    } label: {
                        Text(action.title)
                            .font(.lmSubheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, LiftMarkTheme.spacingMD)
                            .padding(.vertical, LiftMarkTheme.spacingSM)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(LiftMarkTheme.primary)
                    .disabled(!isEnabled)
                    .accessibilityIdentifier(action.accessibilityIdentifier)
                }
            }
            .padding(.horizontal, LiftMarkTheme.spacingMD)
        }
    }
}

// MARK: - Composer

struct PlanEditComposer: View {
    @Binding var text: String
    let isEnabled: Bool
    let isThinking: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    var focus: FocusState<Bool>.Binding

    private var canSend: Bool {
        isEnabled && !isThinking && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: LiftMarkTheme.spacingSM) {
            TextField(PlanEditLabels.inputPlaceholder, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .font(.lmBody)
                .focused(focus)
                .disabled(!isEnabled || isThinking)
                .padding(.horizontal, LiftMarkTheme.spacingMD)
                .padding(.vertical, LiftMarkTheme.spacingSM)
                .background(LiftMarkTheme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusSM))
                .submitLabel(.send)
                .accessibilityIdentifier("ai-edit-input")

            if isThinking {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.lmTitle2)
                        .foregroundStyle(LiftMarkTheme.destructive)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("ai-edit-cancel")
            } else {
                Button {
                    onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.lmTitle2)
                        .foregroundStyle(canSend ? LiftMarkTheme.primary : LiftMarkTheme.tertiaryLabel)
                        .frame(width: 36, height: 36)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("ai-edit-send")
            }
        }
        .padding(.horizontal, LiftMarkTheme.spacingMD)
        .padding(.vertical, LiftMarkTheme.spacingSM)
        .background(LiftMarkTheme.background)
    }
}

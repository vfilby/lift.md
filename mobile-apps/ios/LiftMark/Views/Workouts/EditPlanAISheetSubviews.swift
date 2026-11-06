import SwiftUI

// MARK: - Transcript message

/// One transcript row: user text right-aligned, assistant summary + inline
/// diff left-aligned, errors in the destructive tint. Discarded and undone
/// turns are dimmed and captioned so the user can see why they did not carry
/// into later edits (GH #464). Holding the diff opens the full preview. See
/// `spec/screens/workout-detail.md` ("AI Edit Sheet").
struct PlanEditMessageView: View {
    let message: PlanEditMessage
    /// True for the newest assistant turn; only that diff carries the
    /// `ai-edit-diff` identifier.
    let isLatestDiff: Bool

    @State private var showFullPreview = false

    var body: some View {
        content
            .opacity(message.isDiscarded ? 0.6 : 1)
            .sensoryFeedback(.impact(weight: .medium), trigger: showFullPreview) { _, isNowPresented in
                isNowPresented
            }
            .sheet(isPresented: $showFullPreview) {
                PlanEditFullPreviewSheet(preview: PlanEditPreview(message: message))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch message.content {
        case .user(let text):
            HStack {
                Spacer(minLength: LiftMarkTheme.spacingXL)
                VStack(alignment: .trailing, spacing: LiftMarkTheme.spacingXS) {
                    Text(text)
                        .font(.lmBody)
                        .foregroundStyle(.white)
                        .padding(.horizontal, LiftMarkTheme.spacingMD)
                        .padding(.vertical, LiftMarkTheme.spacingSM)
                        .background(LiftMarkTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                    discardedCaption
                }
            }
        case .assistant(let summary, let diff, let warnings, _):
            HStack {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingSM) {
                    Text(summary)
                        .font(.lmBody)
                        .foregroundStyle(LiftMarkTheme.label)
                    PlanEditInlineDiffView(diff: PlanEditInlineDiff(diff: diff), isLatest: isLatestDiff) {
                        showFullPreview = true
                    }
                    if !warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.lmCaption2)
                                    .foregroundStyle(LiftMarkTheme.warning)
                            }
                        }
                    }
                    discardedCaption
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

    @ViewBuilder
    private var discardedCaption: some View {
        if message.isDiscarded {
            Label(PlanEditLabels.discardedTurn, systemImage: "arrow.uturn.backward")
                .font(.lmCaption2)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                .accessibilityIdentifier("ai-edit-message-discarded")
        }
    }
}

// MARK: - Inline diff

/// The compact diff inside an assistant bubble: header changes first, one
/// row per added/removed/changed exercise, unchanged exercises collapsed to
/// one caption. Press and hold anywhere on it for the full preview; VoiceOver
/// gets the same as a custom action.
struct PlanEditInlineDiffView: View {
    let diff: PlanEditInlineDiff
    var isLatest = true
    let onExpand: () -> Void

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
                ForEach(diff.rows) { row in
                    PlanEditPreviewRowView(row: row, style: .inline)
                }
                if diff.unchangedCount > 0 {
                    Text(PlanEditLabels.unchangedSummary(count: diff.unchangedCount))
                        .font(.lmCaption)
                        .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                }
            }
            Label(PlanEditLabels.holdForFullPreview, systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.lmCaption2)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onLongPressGesture { onExpand() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: PlanEditLabels.showFullPreview) { onExpand() }
        .accessibilityIdentifier(isLatest ? "ai-edit-diff" : "ai-edit-diff-previous")
    }
}

// MARK: - Proposal bar

/// Discard / Apply while a proposal is unapplied; Undo after an Apply;
/// nothing otherwise.
struct PlanEditProposalBar: View {
    let session: PlanEditSession

    var body: some View {
        if session.pendingProposal != nil {
            HStack(spacing: LiftMarkTheme.spacingSM) {
                Button {
                    session.discard()
                } label: {
                    Text("Discard")
                        .font(.lmSubheadline)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LiftMarkTheme.spacingSM)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(LiftMarkTheme.primary)
                .accessibilityIdentifier("ai-edit-discard")

                Button {
                    session.apply()
                } label: {
                    Text("Apply")
                        .font(.lmSubheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LiftMarkTheme.spacingSM)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(LiftMarkTheme.primary)
                .disabled(session.proposalIsEmpty)
                .accessibilityIdentifier("ai-edit-apply")
            }
            .padding(.horizontal, LiftMarkTheme.spacingMD)
            .padding(.top, LiftMarkTheme.spacingSM)
        } else if session.canUndo {
            Button {
                session.undo()
            } label: {
                Label("Undo last apply", systemImage: "arrow.uturn.backward")
                    .font(.lmSubheadline)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LiftMarkTheme.spacingSM)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(LiftMarkTheme.primary)
            .accessibilityIdentifier("ai-edit-undo")
            .padding(.horizontal, LiftMarkTheme.spacingMD)
            .padding(.top, LiftMarkTheme.spacingSM)
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
                .lineLimit(1...3)
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

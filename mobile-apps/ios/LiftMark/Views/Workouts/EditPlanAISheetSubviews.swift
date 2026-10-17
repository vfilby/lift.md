import SwiftUI

// MARK: - Status strip

/// The strip between the preview and the composer: what just happened
/// (thinking / error / latest summary / opening hint) over a caption with the
/// engine and quota labels. See `spec/screens/workout-detail.md`
/// ("AI Edit Sheet", status strip).
struct PlanEditStatusStrip: View {
    let session: PlanEditSession

    var body: some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
            statusContent
            caption
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LiftMarkTheme.spacingMD)
        .padding(.vertical, LiftMarkTheme.spacingSM)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-edit-status")
    }

    @ViewBuilder
    private var statusContent: some View {
        switch session.status {
        case .hint:
            Text(PlanEditLabels.hint)
                .font(.lmSubheadline)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
        case .thinking:
            HStack(spacing: LiftMarkTheme.spacingSM) {
                ProgressView()
                Text("Thinking…")
                    .font(.lmSubheadline)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ai-edit-thinking")
        case .error(let error):
            HStack(alignment: .top, spacing: LiftMarkTheme.spacingSM) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LiftMarkTheme.destructive)
                Text(error.userFacingMessage)
                    .font(.lmSubheadline)
                    .foregroundStyle(LiftMarkTheme.destructive)
                    .accessibilityIdentifier("ai-edit-error")
            }
        case .summary(let summary, let warnings, let isEmptyDiff):
            Text(summary)
                .font(.lmSubheadline)
                .foregroundStyle(LiftMarkTheme.label)
                .lineLimit(3)
            if isEmptyDiff {
                Text(PlanEditLabels.noChanges)
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
            }
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.lmCaption2)
                    .foregroundStyle(LiftMarkTheme.warning)
                    .lineLimit(2)
            }
        }
    }

    private var caption: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Image(systemName: "sparkles")
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.primary)
            Text(session.engine.displayName)
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .accessibilityIdentifier("ai-edit-engine-label")
            Spacer()
            if let quotaLabel = PlanEditLabels.quotaLabel(
                session.quota,
                isApproachingLimit: session.engine.isApproachingQuotaLimit
            ) {
                Text(quotaLabel)
                    .font(.lmCaption)
                    .foregroundStyle(
                        session.quota?.inGrace == true ? LiftMarkTheme.warning : LiftMarkTheme.secondaryLabel
                    )
                    .accessibilityIdentifier("ai-edit-quota-label")
            }
            if session.isQuotaExhausted, let showOptions = session.engine.limitIncreaseAction {
                Button(PlanEditLabels.showOptions) {
                    showOptions()
                }
                .font(.lmCaption)
                .fontWeight(.semibold)
                .accessibilityIdentifier("ai-edit-quota-options")
            }
        }
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

// MARK: - History

/// Read-only transcript behind the History toolbar button: one row per
/// turn, `ai-edit-message-{index}`. The preview is the surface for the
/// current proposal; this only shows what was said.
struct PlanEditHistorySheet: View {
    let messages: [PlanEditMessage]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        PlanEditHistoryRow(message: message)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("ai-edit-message-\(index)")
                    }
                }
                .padding(LiftMarkTheme.spacingMD)
            }
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Discarded/undone turns are dimmed and captioned so the user can see why
/// they did not carry into later edits (GH #464).
struct PlanEditHistoryRow: View {
    let message: PlanEditMessage

    var body: some View {
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
            .opacity(message.isDiscarded ? 0.6 : 1)
        case .assistant(let summary, let diff, _):
            HStack {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
                    Text(summary)
                        .font(.lmBody)
                        .foregroundStyle(LiftMarkTheme.label)
                    Text(PlanEditLabels.changeCount(diff))
                        .font(.lmCaption)
                        .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    discardedCaption
                }
                .padding(LiftMarkTheme.spacingMD)
                .background(LiftMarkTheme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: LiftMarkTheme.cornerRadiusMD))
                Spacer(minLength: LiftMarkTheme.spacingXL)
            }
            .opacity(message.isDiscarded ? 0.6 : 1)
        case .error(let error):
            Label(error.userFacingMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.lmSubheadline)
                .foregroundStyle(LiftMarkTheme.destructive)
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

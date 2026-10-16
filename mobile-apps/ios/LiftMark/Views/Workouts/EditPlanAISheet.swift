import SwiftUI

/// The Edit with AI sheet. Hosted on `WorkoutDetailView` with `.sheet`.
/// See `spec/screens/workout-detail.md` ("AI Edit Sheet") and
/// `spec/flows/ai-plan-editing.md`.
///
/// The view owns no editing state of its own: `PlanEditSession` holds the
/// transcript, proposal, quota, and availability, and persists through
/// `WorkoutPlanStore.updatePlanMarkdown` so the detail view behind the sheet
/// refreshes on Apply.
struct EditPlanAISheet: View {
    let planId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutPlanStore.self) private var planStore
    @Environment(AuthenticationStore.self) private var authStore
    @Environment(FeatureFlagsStore.self) private var featureFlags
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(GymStore.self) private var gymStore

    @State private var session: PlanEditSession?
    @State private var draft = ""
    @State private var showDiscardConfirm = false
    @FocusState private var inputFocused: Bool

    private var hasUnappliedProposal: Bool {
        session?.pendingProposal != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerCaption
                Divider()
                if let session {
                    transcript(session)
                    Divider()
                    proposalBar(session)
                    composer(session)
                } else {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            .navigationTitle("Edit with AI")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        requestClose()
                    }
                    .accessibilityIdentifier("ai-edit-close")
                }
            }
            .alert(PlanEditLabels.discardTitle, isPresented: $showDiscardConfirm) {
                Button(PlanEditLabels.discardCancel, role: .cancel) {}
                Button(PlanEditLabels.discardConfirm, role: .destructive) {
                    session?.discard()
                    dismiss()
                }
            }
        }
        .accessibilityIdentifier("ai-edit-sheet")
        .interactiveDismissDisabled(hasUnappliedProposal)
        .task { await startSession() }
        .onDisappear { session?.cancel() }
    }

    // MARK: - Header

    private var headerCaption: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            Image(systemName: "sparkles")
                .foregroundStyle(LiftMarkTheme.primary)
            Text(session?.engine.displayName ?? PlanEditLabels.choosingEngine)
                .font(.lmCaption)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                .accessibilityIdentifier("ai-edit-engine-label")
            Spacer()
            if let session, let quotaLabel = PlanEditLabels.quotaLabel(
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
            if let session, session.isQuotaExhausted, let showOptions = session.engine.limitIncreaseAction {
                Button(PlanEditLabels.showOptions) {
                    showOptions()
                }
                .font(.lmCaption)
                .fontWeight(.semibold)
                .accessibilityIdentifier("ai-edit-quota-options")
            }
        }
        .padding(.horizontal, LiftMarkTheme.spacingMD)
        .padding(.vertical, LiftMarkTheme.spacingSM)
    }

    // MARK: - Transcript

    private func transcript(_ session: PlanEditSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                    if session.messages.isEmpty {
                        emptyTranscript(session)
                    }
                    ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, message in
                        PlanEditMessageView(
                            message: message,
                            isLatest: index == session.messages.indices.last
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("ai-edit-message-\(index)")
                        .id(message.id)
                    }
                    if session.isThinking {
                        thinkingRow
                    }
                }
                .padding(LiftMarkTheme.spacingMD)
            }
            .onChange(of: session.messages.count) {
                if let last = session.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func emptyTranscript(_ session: PlanEditSession) -> some View {
        VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
            Text("Describe how you'd like to change this plan, or start with a suggestion.")
                .font(.lmSubheadline)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
            PlanEditChipsRow(isEnabled: session.canSend) { action in
                draft = ""
                Task { await session.send(action.instruction) }
            }
            .padding(.horizontal, -LiftMarkTheme.spacingMD)
            Text(PlanEditLabels.privacyFooter(engineName: session.engine.displayName))
                .font(.lmCaption2)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                .accessibilityIdentifier("ai-edit-privacy-footer")
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            ProgressView()
            Text("Thinking…")
                .font(.lmSubheadline)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
        }
        .accessibilityIdentifier("ai-edit-thinking")
    }

    // MARK: - Proposal bar

    @ViewBuilder
    private func proposalBar(_ session: PlanEditSession) -> some View {
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

    // MARK: - Composer

    private func composer(_ session: PlanEditSession) -> some View {
        PlanEditComposer(
            text: $draft,
            isEnabled: session.canSend || session.isThinking,
            isThinking: session.isThinking,
            onSend: { send(session) },
            onCancel: { session.cancel() },
            focus: $inputFocused
        )
        .onSubmit { send(session) }
    }

    // MARK: - Actions

    private func send(_ session: PlanEditSession) {
        let instruction = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, session.canSend else { return }
        draft = ""
        inputFocused = false
        Task { await session.send(instruction) }
    }

    private func requestClose() {
        if hasUnappliedProposal {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    /// Pick the engine, assemble the context, and open the session. Runs once
    /// per presentation; a plan without markdown cannot be edited and the sheet
    /// simply never leaves its loading state (the entry button is gated on
    /// `sourceMarkdown`, so this is unreachable in practice).
    private func startSession() async {
        guard session == nil,
              let plan = planStore.getPlan(id: planId),
              let markdown = plan.sourceMarkdown else { return }

        let selector = PlanEditEngineSelector(
            factories: .live(authStore: authStore, apiClient: authStore.api)
        )
        let engine = await selector.select(
            override: featureFlags.engineOverride,
            isSignedIn: authStore.isAuthenticated
        )
        let context = PlanEditContext.gather(
            units: settingsStore.settings?.defaultWeightUnit ?? .lbs,
            defaultGymId: gymStore.gyms.first(where: { $0.isDefault && !$0.isDeleted })?.id
        )
        let newSession = PlanEditSession(
            planId: planId,
            originalMarkdown: markdown,
            engine: engine,
            context: context,
            planStore: planStore
        )
        session = newSession
        await newSession.refreshAvailability()
    }
}

// MARK: - Session helpers

extension PlanEditSession {
    /// True once the engine has reported its daily limit as reached, either
    /// up front via `availability()` or from a failed turn.
    var isQuotaExhausted: Bool {
        if case .quotaExhausted = availability { return true }
        return messages.contains { message in
            if case .error(.quotaExhausted) = message.content { return true }
            return false
        }
    }
}

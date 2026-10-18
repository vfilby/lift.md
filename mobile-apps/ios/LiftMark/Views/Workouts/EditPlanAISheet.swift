import SwiftUI

/// The Edit with AI sheet. Hosted on `WorkoutDetailView` with `.sheet`.
/// See `spec/screens/workout-detail.md` ("AI Edit Sheet") and
/// `spec/flows/ai-plan-editing.md`.
///
/// Layout: a header caption (engine, quota), the transcript (each assistant
/// turn carries a compact inline diff; hold it for the full preview), then
/// the edit controls: proposal bar, quick-action chips, privacy caption, and
/// composer. The view owns no editing state of its own: `PlanEditSession`
/// holds the transcript, proposal, quota, and availability, and persists
/// through `WorkoutPlanStore.updatePlanMarkdown` so the detail view behind
/// the sheet refreshes on Apply.
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

    /// Scroll anchor for the thinking row, which has no message id.
    private static let thinkingAnchor = "ai-edit-thinking"

    private var hasUnappliedProposal: Bool {
        session?.pendingProposal != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    VStack(spacing: 0) {
                        headerCaption(session)
                        Divider()
                        transcript(session)
                        Divider()
                        editControls(session)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func headerCaption(_ session: PlanEditSession) -> some View {
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
        .padding(.horizontal, LiftMarkTheme.spacingMD)
        .padding(.vertical, LiftMarkTheme.spacingSM)
    }

    // MARK: - Transcript

    private func transcript(_ session: PlanEditSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LiftMarkTheme.spacingMD) {
                    if session.messages.isEmpty {
                        Text(PlanEditLabels.hint)
                            .font(.lmSubheadline)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let latestDiff = session.messages.latestAssistantIndex
                    ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, message in
                        PlanEditMessageView(message: message, isLatestDiff: index == latestDiff)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("ai-edit-message-\(index)")
                            .id(message.id)
                    }
                    if session.isThinking {
                        thinkingRow
                            .id(Self.thinkingAnchor)
                    }
                }
                .padding(LiftMarkTheme.spacingMD)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.messages.count) {
                scrollToEnd(proxy, session)
            }
            .onChange(of: session.isThinking) {
                scrollToEnd(proxy, session)
            }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: LiftMarkTheme.spacingSM) {
            ProgressView()
            Text("Thinking…")
                .font(.lmSubheadline)
                .foregroundStyle(LiftMarkTheme.secondaryLabel)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ai-edit-thinking")
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ session: PlanEditSession) {
        let target: AnyHashable? = session.isThinking ? Self.thinkingAnchor : session.messages.last?.id
        guard let target else { return }
        withAnimation { proxy.scrollTo(target, anchor: .bottom) }
    }

    // MARK: - Edit controls

    private func editControls(_ session: PlanEditSession) -> some View {
        VStack(spacing: 0) {
            PlanEditProposalBar(session: session)
            PlanEditChipsRow(isEnabled: session.canSend) { action in
                draft = ""
                inputFocused = false
                Task { await session.send(action.instruction) }
            }
            .padding(.top, LiftMarkTheme.spacingSM)
            Text(PlanEditLabels.privacyFooter(engineName: session.engine.displayName))
                .font(.lmCaption2)
                .foregroundStyle(LiftMarkTheme.tertiaryLabel)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LiftMarkTheme.spacingMD)
                .padding(.top, LiftMarkTheme.spacingXS)
                .accessibilityIdentifier("ai-edit-privacy-footer")
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
        .background(LiftMarkTheme.background)
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

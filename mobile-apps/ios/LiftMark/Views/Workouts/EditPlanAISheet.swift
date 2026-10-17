import SwiftUI

/// The Edit with AI sheet. Hosted on `WorkoutDetailView` with `.sheet`.
/// See `spec/screens/workout-detail.md` ("AI Edit Sheet") and
/// `spec/flows/ai-plan-editing.md`.
///
/// Layout: a live preview of the working plan fills the upper region; the
/// edit area (status strip, proposal bar, quick-action chips, composer) is a
/// fixed lower region that never collapses and is at least a third of the
/// sheet (GH #461). The view owns no editing state of its own:
/// `PlanEditSession` holds the transcript, proposal, quota, and availability,
/// and persists through `WorkoutPlanStore.updatePlanMarkdown` so the detail
/// view behind the sheet refreshes on Apply.
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
    @State private var showHistory = false
    @FocusState private var inputFocused: Bool

    private var hasUnappliedProposal: Bool {
        session?.pendingProposal != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            PlanEditPreviewView(preview: preview(session))
                            Divider()
                            editArea(session)
                                .frame(minHeight: geometry.size.height / 3, alignment: .bottom)
                        }
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
                ToolbarItem(placement: .primaryAction) {
                    if let session, !session.messages.isEmpty {
                        Button {
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .accessibilityLabel("History")
                        .accessibilityIdentifier("ai-edit-history")
                    }
                }
            }
            .alert(PlanEditLabels.discardTitle, isPresented: $showDiscardConfirm) {
                Button(PlanEditLabels.discardCancel, role: .cancel) {}
                Button(PlanEditLabels.discardConfirm, role: .destructive) {
                    session?.discard()
                    dismiss()
                }
            }
            .sheet(isPresented: $showHistory) {
                PlanEditHistorySheet(messages: session?.messages ?? [])
            }
        }
        .accessibilityIdentifier("ai-edit-sheet")
        .interactiveDismissDisabled(hasUnappliedProposal)
        .task { await startSession() }
        .onDisappear { session?.cancel() }
    }

    // MARK: - Preview

    private func preview(_ session: PlanEditSession) -> PlanEditPreview? {
        guard let plan = session.workingPlan else { return nil }
        return PlanEditPreview(plan: plan, diff: session.pendingProposal?.diff)
    }

    // MARK: - Edit area

    private func editArea(_ session: PlanEditSession) -> some View {
        VStack(spacing: 0) {
            PlanEditStatusStrip(session: session)
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

    /// What the status strip shows right now.
    var status: PlanEditStatus {
        PlanEditStatus.current(messages: messages, isThinking: isThinking)
    }
}

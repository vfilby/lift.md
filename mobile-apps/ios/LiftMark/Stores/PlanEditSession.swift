import Foundation

// MARK: - Plan store seam

/// The slice of `WorkoutPlanStore` the session needs, so tests can fake
/// persistence without a database.
@MainActor
protocol PlanEditPlanStoring: AnyObject {
    func getPlan(id: String) -> WorkoutPlan?
    func updatePlanMarkdown(id: String, newMarkdown: String)
}

extension WorkoutPlanStore: PlanEditPlanStoring {}

// MARK: - Transcript

/// One transcript row in the Edit with AI sheet.
struct PlanEditMessage: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case user(String)
        /// `markdown` is the proposed plan the diff describes; the full
        /// preview re-parses it when the inline diff is held.
        case assistant(summary: String, diff: PlanDiff, warnings: [String], markdown: String)
        case error(PlanEditError)
    }

    let id: UUID
    let content: Content
    /// True once the proposal this turn belonged to was discarded or undone.
    /// Kept in the transcript for History, excluded from the engine's
    /// `history` (GH #464).
    var isDiscarded = false

    init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }

    static func user(_ text: String) -> PlanEditMessage {
        PlanEditMessage(content: .user(text))
    }

    static func assistant(summary: String, diff: PlanDiff, warnings: [String], markdown: String) -> PlanEditMessage {
        PlanEditMessage(content: .assistant(summary: summary, diff: diff, warnings: warnings, markdown: markdown))
    }

    static func error(_ error: PlanEditError) -> PlanEditMessage {
        PlanEditMessage(content: .error(error))
    }

    /// The turn this message contributes to the engine's `history`, if any.
    /// Nil for errors and for discarded turns.
    var turn: PlanEditTurn? {
        guard !isDiscarded else { return nil }
        switch content {
        case .user(let text): return PlanEditTurn(role: .user, content: text)
        case .assistant(let summary, _, _, _): return PlanEditTurn(role: .assistant, content: summary)
        case .error: return nil
        }
    }
}

/// The latest unapplied result; drives the Apply/Discard bar.
struct PlanEditProposal: Equatable, Sendable {
    let markdown: String
    let diff: PlanDiff
}

// MARK: - Session

/// Owns one Edit with AI sheet's state. See `spec/services/ai-plan-editing.md`
/// ("Session").
///
/// The model never writes to the database: `apply()` goes through
/// `updatePlanMarkdown`, the same path as the manual markdown editor.
@MainActor
@Observable
final class PlanEditSession {
    /// Maximum conversation turns sent with each request.
    static let historyTurnLimit = PlanEditPrompt.historyTurnLimit

    let planId: String
    /// The plan's markdown when the sheet opened.
    let originalMarkdown: String
    let engine: any PlanEditEngine
    let context: PlanEditContext

    /// What the next instruction edits. Starts as `originalMarkdown`; becomes
    /// the proposal after each successful turn so edits chain.
    private(set) var workingMarkdown: String {
        didSet { workingPlan = Self.parse(workingMarkdown) }
    }
    /// `workingMarkdown` parsed, for the live preview; nil when it does not
    /// parse (the preview then shows "Preview unavailable").
    private(set) var workingPlan: WorkoutPlan?
    /// Markdown last persisted via `apply()`; nil until the first Apply.
    private(set) var appliedMarkdown: String?
    private(set) var messages: [PlanEditMessage] = []
    private(set) var pendingProposal: PlanEditProposal?
    /// Nil until `refreshAvailability()` has run.
    private(set) var availability: PlanEditEngineAvailability?
    /// Last quota reported by the engine (cloud only).
    private(set) var quota: PlanEditQuota?
    /// True while an `edit` call is in flight; input is disabled.
    private(set) var isThinking = false
    /// Set after `quotaExhausted` / `subscriptionRequired`; the input stays
    /// disabled until the sheet is reopened.
    private(set) var isInputLocked = false

    private let planStore: any PlanEditPlanStoring
    /// What `undo()` restores: the markdown persisted before the most recent
    /// Apply. One level only.
    private var undoMarkdown: String?
    /// Messages before this index belong to applied proposals (or were already
    /// discarded); from it onward is the current pending chain.
    private var committedMessageCount = 0
    /// `committedMessageCount` before the most recent Apply, so `undo()` can
    /// discard that Apply's turns.
    private var undoCommittedMessageCount: Int?
    private var inFlight: Task<PlanEditResult, Error>?

    init(
        planId: String,
        originalMarkdown: String,
        engine: any PlanEditEngine,
        context: PlanEditContext,
        planStore: any PlanEditPlanStoring
    ) {
        self.planId = planId
        self.originalMarkdown = originalMarkdown
        self.workingMarkdown = originalMarkdown
        self.workingPlan = Self.parse(originalMarkdown)
        self.engine = engine
        self.context = context
        self.planStore = planStore
    }

    // MARK: - Derived state

    var canUndo: Bool { undoMarkdown != nil }

    /// True when the engine can be used right now: available, not locked, and
    /// not already thinking.
    var canSend: Bool {
        !isThinking && !isInputLocked && (availability?.isAvailable ?? true)
    }

    /// True when the latest proposal would not change the plan.
    var proposalIsEmpty: Bool {
        pendingProposal?.diff.isEmpty ?? true
    }

    // MARK: - Operations

    /// Query the engine's availability for the header. When the engine is
    /// unavailable the reason is also recorded as an error message so the
    /// sheet opens in the unavailable state.
    func refreshAvailability() async {
        let result = await engine.availability()
        availability = result
        switch result {
        case .available:
            break
        case .quotaExhausted(let resetAt):
            isInputLocked = true
            messages.append(.error(.quotaExhausted(resetAt: resetAt)))
        case .unavailable(let reason):
            messages.append(.error(.engineUnavailable(reason)))
        }
    }

    /// Append the user message, call the engine with `workingMarkdown` and the
    /// last 6 turns, then record either a proposal or an error. Failed turns
    /// never change `workingMarkdown`.
    func send(_ instruction: String) async {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking, !isInputLocked else { return }

        let history = Array(messages.compactMap(\.turn).suffix(Self.historyTurnLimit))
        messages.append(.user(trimmed))

        let request = PlanEditRequest(
            planMarkdown: workingMarkdown,
            instruction: trimmed,
            history: history,
            context: context
        )

        isThinking = true
        defer {
            isThinking = false
            inFlight = nil
        }

        do {
            try PlanEditPrompt.checkSizeLimits(request)
            let engine = self.engine
            let task = Task { try await engine.edit(request) }
            inFlight = task
            let result = try await task.value
            if task.isCancelled { throw PlanEditError.cancelled }
            accept(result)
        } catch {
            record(error)
        }
    }

    /// Persist the proposal via `updatePlanMarkdown`. The sheet stays open.
    /// The pending chain's turns become committed history.
    func apply() {
        guard let proposal = pendingProposal else { return }
        undoMarkdown = appliedMarkdown ?? originalMarkdown
        undoCommittedMessageCount = committedMessageCount
        planStore.updatePlanMarkdown(id: planId, newMarkdown: proposal.markdown)
        appliedMarkdown = proposal.markdown
        workingMarkdown = proposal.markdown
        pendingProposal = nil
        committedMessageCount = messages.count
    }

    /// Re-apply the markdown persisted before the most recent Apply. One
    /// level; the next instruction edits the restored markdown. The undone
    /// Apply's turns, and anything sent since, are discarded (GH #464).
    func undo() {
        guard let previous = undoMarkdown else { return }
        planStore.updatePlanMarkdown(id: planId, newMarkdown: previous)
        appliedMarkdown = previous
        workingMarkdown = previous
        pendingProposal = nil
        undoMarkdown = nil
        discardMessages(from: undoCommittedMessageCount ?? committedMessageCount)
        undoCommittedMessageCount = nil
    }

    /// Drop the proposal; the next instruction edits the last applied (or
    /// original) markdown. The discarded chain's turns leave the engine
    /// history so the model does not re-apply them (GH #464).
    func discard() {
        pendingProposal = nil
        workingMarkdown = appliedMarkdown ?? originalMarkdown
        discardMessages(from: committedMessageCount)
    }

    /// Abort the in-flight call. `send` records "Cancelled." as an error.
    func cancel() {
        inFlight?.cancel()
    }

    // MARK: - Private

    private static func parse(_ markdown: String) -> WorkoutPlan? {
        MarkdownParser.parseWorkout(markdown).data
    }

    /// Mark `messages[start...]` discarded and move the commit point past them.
    private func discardMessages(from start: Int) {
        for index in messages.indices where index >= start {
            messages[index].isDiscarded = true
        }
        committedMessageCount = messages.count
    }

    /// The diff shown for a proposal is always relative to the last applied
    /// (or original) markdown, not the previous proposal, so chained edits
    /// highlight everything that differs from what is persisted.
    private func accept(_ result: PlanEditResult) {
        let before = Self.parse(appliedMarkdown ?? originalMarkdown)
        let after = Self.parse(result.planMarkdown)
        let diff: PlanDiff
        if let before, let after {
            diff = PlanDiffBuilder.diff(before: before, after: after)
        } else {
            diff = .empty
        }

        if let quota = result.quota {
            self.quota = quota
        }
        pendingProposal = PlanEditProposal(markdown: result.planMarkdown, diff: diff)
        workingMarkdown = result.planMarkdown
        messages.append(.assistant(
            summary: result.summary, diff: diff, warnings: result.warnings, markdown: result.planMarkdown
        ))
    }

    private func record(_ error: Error) {
        let planEditError: PlanEditError
        if let known = error as? PlanEditError {
            planEditError = known
        } else if error is CancellationError {
            planEditError = .cancelled
        } else {
            planEditError = .model(error.localizedDescription)
        }
        if planEditError.locksInput {
            isInputLocked = true
        }
        messages.append(.error(planEditError))
    }
}

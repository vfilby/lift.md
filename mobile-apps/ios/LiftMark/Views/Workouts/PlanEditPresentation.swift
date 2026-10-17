import Foundation

// MARK: - Gating

/// Decides which row the Workout Detail Edit/Reprocess block renders for AI
/// editing. See `spec/services/ai-plan-editing.md` ("Gating") and
/// `spec/screens/workout-detail.md`.
enum AIEditGate {
    enum Decision: Equatable {
        /// Flag off or no `sourceMarkdown`: nothing is rendered.
        case hidden
        /// `edit-plan-ai-button`.
        case button
        /// `edit-plan-ai-upsell`.
        case upsell
    }

    static func decision(
        flagOn: Bool,
        hasMarkdown: Bool,
        tier: AuthenticatedUser.Tier?,
        stubActive: Bool
    ) -> Decision {
        guard flagOn, hasMarkdown else { return .hidden }
        if stubActive { return .button }
        switch tier {
        case .pro, .trial: return .button
        case .free, .none: return .upsell
        }
    }

    static func shouldShowButton(
        flagOn: Bool,
        hasMarkdown: Bool,
        tier: AuthenticatedUser.Tier?,
        stubActive: Bool
    ) -> Bool {
        decision(flagOn: flagOn, hasMarkdown: hasMarkdown, tier: tier, stubActive: stubActive) == .button
    }
}

// MARK: - Labels

/// Formats the engine/quota caption in the Edit with AI status strip. See
/// `spec/flows/ai-plan-editing.md` ("Engine-specific notes"). Engine names
/// always come from `PlanEditEngine.displayName`; this type only shapes the
/// quota numbers it is handed.
enum PlanEditLabels {
    static let nearingAppleLimit = "Nearing Apple's daily limit"
    static let showOptions = "Show options"
    static let choosingEngine = "Choosing an engine…"
    static let noChanges = "No changes were made"
    static let discardTitle = "Discard the unapplied edit?"
    static let discardConfirm = "Discard"
    static let discardCancel = "Keep editing"
    static let inputPlaceholder = "Describe a change…"
    static let hint = "Describe how you'd like to change this plan, or start with a suggestion."
    static let previewUnavailable = "Preview unavailable"
    static let discardedTurn = "Discarded"

    /// Server-side grace ceiling: `ceil(limit * 1.1)` (service spec, "Quota").
    static func graceCeiling(limit: Int) -> Int {
        Int((Double(limit) * 1.1).rounded(.up))
    }

    /// "N of M left today" normally; "Over today's limit · N extra left" while
    /// in grace. Nil when there is no quota to show.
    static func quotaLabel(_ quota: PlanEditQuota?) -> String? {
        guard let quota else { return nil }
        if quota.inGrace {
            let extra = max(0, graceCeiling(limit: quota.limit) - quota.limit + quota.remaining)
            return "Over today's limit \u{00B7} \(extra) extra left"
        }
        return "\(max(0, quota.remaining)) of \(quota.limit) left today"
    }

    /// The status caption's quota part: the provider's approaching-limit
    /// warning wins over the numeric label.
    static func quotaLabel(_ quota: PlanEditQuota?, isApproachingLimit: Bool) -> String? {
        if isApproachingLimit { return nearingAppleLimit }
        return quotaLabel(quota)
    }

    /// One-line caption under the quick-action chips; names the active engine.
    static func privacyFooter(engineName: String) -> String {
        "Your plan and instruction are sent to \(engineName) and not stored."
    }

    /// History row caption: "No changes" / "1 change" / "N changes".
    static func changeCount(_ diff: PlanDiff) -> String {
        let count = diff.changedEntries.count + diff.headerChanges.count
        switch count {
        case 0: return "No changes"
        case 1: return "1 change"
        default: return "\(count) changes"
        }
    }
}

// MARK: - Quick-action chips

/// The chips above the composer. Slugs are part of the accessibility-ID
/// contract (`ai-edit-chip-{slug}`).
struct PlanEditQuickAction: Identifiable, Equatable, Sendable {
    let slug: String
    let title: String
    /// The instruction sent when the chip is tapped.
    let instruction: String

    var id: String { slug }
    var accessibilityIdentifier: String { "ai-edit-chip-\(slug)" }

    static let all: [PlanEditQuickAction] = [
        PlanEditQuickAction(slug: "make-it-shorter", title: "Make it shorter", instruction: "Make it shorter"),
        PlanEditQuickAction(
            slug: "swap-barbell-for-dumbbells",
            title: "Swap barbell for dumbbells",
            instruction: "Swap barbell for dumbbells"
        ),
        PlanEditQuickAction(slug: "add-a-warm-up", title: "Add a warm-up", instruction: "Add a warm-up"),
        PlanEditQuickAction(slug: "progress-loads", title: "Progress loads 2.5%", instruction: "Progress loads 2.5%"),
        PlanEditQuickAction(slug: "thirty-minutes", title: "I only have 30 min", instruction: "I only have 30 min"),
    ]
}

// MARK: - Status strip

/// What the status strip between the preview and the edit area shows: one
/// of thinking, the latest error, the latest summary, or the opening hint.
/// See `spec/screens/workout-detail.md` ("AI Edit Sheet", status strip).
enum PlanEditStatus: Equatable {
    /// No turn yet: "Describe how you'd like to change this plan…".
    case hint
    case thinking
    case error(PlanEditError)
    /// The latest assistant summary; `isEmptyDiff` adds the "No changes were
    /// made" line and disables Apply.
    case summary(String, warnings: [String], isEmptyDiff: Bool)

    /// A discarded last turn shows the hint again: its summary no longer
    /// describes the preview.
    static func current(messages: [PlanEditMessage], isThinking: Bool) -> PlanEditStatus {
        if isThinking { return .thinking }
        guard let last = messages.last, !last.isDiscarded else { return .hint }
        switch last.content {
        case .error(let error):
            return .error(error)
        case .assistant(let summary, let diff, let warnings):
            return .summary(summary, warnings: warnings, isEmptyDiff: diff.isEmpty)
        case .user:
            return .hint
        }
    }
}

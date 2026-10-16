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

// MARK: - Header labels

/// Formats the engine/quota caption in the Edit with AI header. See
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

    /// The header caption's quota part: the provider's approaching-limit
    /// warning wins over the numeric label.
    static func quotaLabel(_ quota: PlanEditQuota?, isApproachingLimit: Bool) -> String? {
        if isApproachingLimit { return nearingAppleLimit }
        return quotaLabel(quota)
    }

    /// Caption shown once with an empty transcript; names the active engine.
    static func privacyFooter(engineName: String) -> String {
        "Your plan, instruction, and equipment are sent to \(engineName) for this edit and are not stored."
    }

    /// "N exercises unchanged" / "1 exercise unchanged".
    static func unchangedSummary(count: Int) -> String {
        count == 1 ? "1 exercise unchanged" : "\(count) exercises unchanged"
    }
}

// MARK: - Quick-action chips

/// The chips shown on an empty transcript. Slugs are part of the
/// accessibility-ID contract (`ai-edit-chip-{slug}`).
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

// MARK: - Diff rows

/// Presentation of one `PlanDiffEntry` row: its accessibility slug, marker
/// glyph, and the lines shown under the exercise name.
struct PlanDiffRowPresentation: Equatable {
    enum Kind: String {
        case added
        case removed
        case changed

        var marker: String {
            switch self {
            case .added: return "+"
            case .removed: return "\u{2212}"
            case .changed: return "~"
            }
        }
    }

    let kind: Kind
    let name: String
    let parent: String?
    /// Set lines for added/removed; the *after* lines for changed.
    let lines: [String]
    /// The *before* lines for changed rows, empty otherwise.
    let previousLines: [String]

    var slug: String { "\(kind.rawValue)-\(Self.slugify(name))" }
    var accessibilityIdentifier: String { "ai-edit-diff-row-\(slug)" }

    init?(entry: PlanDiffEntry) {
        switch entry {
        case .added(let exercise):
            kind = .added
            name = exercise.name
            parent = exercise.parent
            lines = exercise.setLines
            previousLines = []
        case .removed(let exercise):
            kind = .removed
            name = exercise.name
            parent = exercise.parent
            lines = exercise.setLines
            previousLines = []
        case .changed(let before, let after):
            kind = .changed
            name = after.name
            parent = after.parent
            lines = after.setLines
            previousLines = before.setLines
        case .unchanged:
            return nil
        }
    }

    /// Lower-cased, non-alphanumerics collapsed to single hyphens, trimmed:
    /// "Face Pull" → "face-pull".
    static func slugify(_ name: String) -> String {
        var out = ""
        var pendingHyphen = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        return out
    }
}

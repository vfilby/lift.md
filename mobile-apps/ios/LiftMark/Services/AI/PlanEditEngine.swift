import Foundation

// MARK: - Engine kinds and availability

/// The interchangeable back ends behind AI plan editing. See
/// `spec/services/ai-plan-editing.md` ("Engines").
enum PlanEditEngineKind: String, CaseIterable, Codable, Sendable {
    /// FoundationModels `PrivateCloudComputeLanguageModel` (iOS 27+).
    case applePrivateCloud
    /// FoundationModels `SystemLanguageModel` (iOS 26+).
    case appleOnDevice
    /// `POST /v1/ai/plan/edit` → Amazon Bedrock via the getlift.md API.
    case liftMarkCloud
    /// Deterministic test double, launch-argument only (`--ai-engine-stub`).
    case stub
}

enum PlanEditEngineAvailability: Equatable, Sendable {
    case available
    case quotaExhausted(resetAt: Date?)
    /// Human-readable, shown verbatim in the sheet.
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Opens the provider's own "get more quota" UI (Apple's
/// `LimitIncreaseSuggestion.show()`). Exposed as a plain closure so the sheet
/// never imports FoundationModels.
typealias PlanEditLimitIncreaseAction = @MainActor @Sendable () -> Void

/// One AI editing back end. Stateless per `edit` call; the session owns
/// transcript and proposal state.
protocol PlanEditEngine: Sendable {
    var kind: PlanEditEngineKind { get }
    /// "Apple Private Cloud Compute", "Apple on-device", "LiftMark cloud".
    var displayName: String { get }
    func availability() async -> PlanEditEngineAvailability
    func edit(_ request: PlanEditRequest) async throws -> PlanEditResult

    /// True when the provider reports usage is nearing its daily limit
    /// (Apple PCC `quotaUsage.status == .belowLimit(isApproachingLimit: true)`).
    /// The sheet shows "Nearing Apple's daily limit". Default `false`.
    var isApproachingQuotaLimit: Bool { get }

    /// When the provider offers a way to raise the limit after it is reached
    /// (Apple PCC `limitIncreaseSuggestion`), a closure that presents it. The
    /// sheet renders a "Show options" button while this is non-nil. Default
    /// `nil`.
    var limitIncreaseAction: PlanEditLimitIncreaseAction? { get }
}

extension PlanEditEngine {
    var isApproachingQuotaLimit: Bool { false }
    var limitIncreaseAction: PlanEditLimitIncreaseAction? { nil }
}

// MARK: - Request / result

struct PlanEditTurn: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

struct PlanEditContext: Codable, Equatable, Sendable {
    var units: WeightUnit
    /// Default gym's equipment names, may be empty.
    var equipment: [String]
    /// Compact history block from `WorkoutHistoryService`, may be nil.
    var recentSessions: String?

    init(units: WeightUnit, equipment: [String] = [], recentSessions: String? = nil) {
        self.units = units
        self.equipment = equipment
        self.recentSessions = recentSessions
    }
}

struct PlanEditRequest: Equatable, Sendable {
    /// The current working markdown (see `PlanEditSession`).
    let planMarkdown: String
    let instruction: String
    /// At most the last 6 turns, oldest first.
    let history: [PlanEditTurn]
    let context: PlanEditContext
}

struct PlanEditQuota: Codable, Equatable, Sendable {
    let limit: Int
    /// May be negative while in grace.
    let remaining: Int
    let resetAt: Date
    let inGrace: Bool
}

struct PlanEditResult: Equatable, Sendable {
    /// Parses successfully with `MarkdownParser`.
    let planMarkdown: String
    let summary: String
    /// Parser warnings for the new markdown.
    let warnings: [String]
    let engine: PlanEditEngineKind
    /// Cloud engine only.
    let quota: PlanEditQuota?
}

// MARK: - Errors

enum PlanEditError: Error, Equatable, Sendable {
    case engineUnavailable(String)
    case quotaExhausted(resetAt: Date?)
    /// Input would not fit the engine's context budget.
    case planTooLarge
    /// After the repair turn.
    case outputDidNotParse([String])
    case subscriptionRequired
    case notSignedIn
    case network
    /// Provider error, message is safe to show.
    case model(String)
    case cancelled

    /// Copy from the "Errors (user-facing copy)" table in the service spec.
    var userFacingMessage: String {
        switch self {
        case .engineUnavailable(let reason):
            return reason
        case .quotaExhausted(let resetAt):
            if let resetAt {
                let time = resetAt.formatted(date: .omitted, time: .shortened)
                return "Daily AI limit reached. Resets at \(time)."
            }
            return "Daily AI limit reached."
        case .planTooLarge:
            return "This plan is too long for the selected AI engine."
        case .outputDidNotParse:
            return "The AI's edit couldn't be read as a valid plan. Try rephrasing."
        case .subscriptionRequired:
            return "AI editing is part of LiftMark Pro."
        case .notSignedIn:
            return "Sign in to use LiftMark cloud."
        case .network:
            return "Couldn't reach LiftMark. Check your connection."
        case .model(let message):
            return message
        case .cancelled:
            return "Cancelled."
        }
    }

    /// Errors after which the sheet keeps the input disabled until it is
    /// reopened (see `spec/flows/ai-plan-editing.md` step 7).
    var locksInput: Bool {
        switch self {
        case .quotaExhausted, .subscriptionRequired: return true
        default: return false
        }
    }
}

// MARK: - Context assembly

extension PlanEditContext {
    /// Server-side cap on the compact history block (`context.recent_sessions`).
    static let recentSessionsByteLimit = 8_192

    /// Assemble the context for a plan edit from device state: the default
    /// gym's available equipment and the compact recent-session block the
    /// workout generator already produces. Any piece that fails to load is
    /// simply omitted — context is advisory, never a reason to block an edit.
    @MainActor
    static func gather(units: WeightUnit, defaultGymId: String?) -> PlanEditContext {
        var equipment: [String] = []
        if let defaultGymId {
            let store = EquipmentStore()
            store.loadEquipment(forGym: defaultGymId)
            equipment = store.equipment.filter(\.isAvailable).map(\.name)
        }

        var recent = (try? WorkoutHistoryService().generateWorkoutHistoryContext(recentCount: 5)) ?? ""
        recent = recent.trimmingCharacters(in: .whitespacesAndNewlines)
        if recent.utf8.count > recentSessionsByteLimit {
            // Drop whole lines from the end until the block fits; the newest
            // sessions come first, so the tail is the least useful part.
            var lines = recent.split(separator: "\n", omittingEmptySubsequences: false)
            while !lines.isEmpty, lines.joined(separator: "\n").utf8.count > recentSessionsByteLimit {
                lines.removeLast()
            }
            recent = lines.joined(separator: "\n")
        }

        return PlanEditContext(
            units: units,
            equipment: equipment,
            recentSessions: recent.isEmpty ? nil : recent
        )
    }
}

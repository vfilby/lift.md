import Foundation
import FoundationModels

/// `applePrivateCloud`: FoundationModels `PrivateCloudComputeLanguageModel`
/// (iOS 27+). One session per `edit` call; the repair turn reuses that session
/// so the model sees its own prior output. Uses the full prompt,
/// `ContextOptions(reasoningLevel: .light)` and a 4000-token output budget.
/// See `spec/services/ai-plan-editing.md` ("ApplePrivateCloudEngine").
///
/// Constructible on iOS 26 so the selector can always build it; every entry
/// point reports "requires iOS 27" there instead of crashing.
struct ApplePrivateCloudEngine: PlanEditEngine {
    static let maximumResponseTokens = 4000
    static let requiresNewerOSReason = "Apple Private Cloud Compute requires iOS 27."

    let kind: PlanEditEngineKind = .applePrivateCloud
    let displayName = "Apple Private Cloud Compute"

    func availability() async -> PlanEditEngineAvailability {
        guard #available(iOS 27, *) else {
            return .unavailable(reason: Self.requiresNewerOSReason)
        }
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            return .unavailable(reason: Self.reason(for: reason))
        }
        let quota = model.quotaUsage
        if quota.isLimitReached {
            return .quotaExhausted(resetAt: quota.resetDate)
        }
        return .available
    }

    /// True when Apple reports usage is nearing the daily limit, so the sheet
    /// can show "Nearing Apple's daily limit".
    var isApproachingQuotaLimit: Bool {
        guard #available(iOS 27, *) else { return false }
        if case .belowLimit(let below) = PrivateCloudComputeLanguageModel().quotaUsage.status {
            return below.isApproachingLimit
        }
        return false
    }

    /// Presents Apple's limit-increase options when Apple offers them. The
    /// sheet renders "Show options" while this is non-nil.
    var limitIncreaseAction: PlanEditLimitIncreaseAction? {
        guard #available(iOS 27, *),
              let suggestion = PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion else {
            return nil
        }
        return { suggestion.show() }
    }

    func edit(_ request: PlanEditRequest) async throws -> PlanEditResult {
        guard #available(iOS 27, *) else {
            throw PlanEditError.engineUnavailable(Self.requiresNewerOSReason)
        }
        try PlanEditPrompt.checkSizeLimits(request)

        switch await availability() {
        case .available:
            break
        case .quotaExhausted(let resetAt):
            throw PlanEditError.quotaExhausted(resetAt: resetAt)
        case .unavailable(let reason):
            throw PlanEditError.engineUnavailable(reason)
        }

        let prompt = PlanEditPrompt.userMessage(for: request)
        do {
            let session = LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                instructions: PlanEditPrompt.systemPrompt
            )
            let options = GenerationOptions(maximumResponseTokens: Self.maximumResponseTokens)
            let contextOptions = ContextOptions(reasoningLevel: .light)
            let first = try await session.respond(
                to: prompt,
                generating: PlanEditResponse.self,
                options: options,
                contextOptions: contextOptions
            )
            let validated = try await PlanEditValidation.validate(first.content.draft) { repairPrompt in
                try await session.respond(
                    to: repairPrompt,
                    generating: PlanEditResponse.self,
                    options: options,
                    contextOptions: contextOptions
                ).content.draft
            }
            return PlanEditResult(
                planMarkdown: validated.planMarkdown,
                summary: validated.summary,
                warnings: validated.warnings,
                engine: .applePrivateCloud,
                quota: nil
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Mapping

    @available(iOS 27, *)
    private static func reason(for reason: PrivateCloudComputeLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn't support Apple Private Cloud Compute."
        case .systemNotReady:
            return "Apple Private Cloud Compute isn't ready yet. Check that Apple Intelligence is on and try again."
        @unknown default:
            return "Apple Private Cloud Compute is unavailable."
        }
    }

    /// PCC-specific failures first (network, quota, service), then the shared
    /// FoundationModels mapping.
    private static func mapError(_ error: Error) -> PlanEditError {
        if #available(iOS 27, *), let pccError = error as? PrivateCloudComputeLanguageModel.Error {
            switch pccError {
            case .networkFailure:
                return .network
            case .quotaLimitReached(let quota):
                return .quotaExhausted(resetAt: quota.resetDate)
            case .serviceUnavailable(let unavailable):
                return .engineUnavailable(unavailable.debugDescription)
            @unknown default:
                return .model(pccError.errorDescription ?? pccError.localizedDescription)
            }
        }
        return ApplePlanEditSupport.mapError(error)
    }
}

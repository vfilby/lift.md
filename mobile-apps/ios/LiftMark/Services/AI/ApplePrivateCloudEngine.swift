import Foundation

// The Private Cloud Compute model ships in the iOS 27 SDK (FoundationModels
// module version 2.x). Builds made with an older SDK (CI runners still on
// Xcode 26) get a stand-in engine that always reports itself unavailable, so
// the rest of the feature compiles and the selector falls through to the
// LiftMark cloud engine exactly as it does on devices that can't run PCC.
#if canImport(FoundationModels, _version: 2.0)
import FoundationModels

// MARK: - Structured output

/// The structured answer the PCC engine asks for. Mirrors the cloud engine's
/// `submit_plan_edit` tool schema (`{ plan_markdown, summary }`). The on-device
/// engine deliberately does not use it (see `AppleOnDeviceEngine`).
@Generable(description: "A revised lift.md workout plan and a short summary of the change.")
struct PlanEditResponse {
    @Guide(description: "The complete revised plan in lift.md markdown, every line, not just the change. No fences.")
    var planMarkdown: String

    @Guide(description: "One short paragraph describing what changed and any assumption made. Do not restate the plan.")
    var summary: String

    var draft: PlanEditDraft {
        PlanEditDraft(planMarkdown: planMarkdown, summary: summary)
    }
}

// MARK: - Engine

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
        // The most recent plan the model produced, kept for the failure log.
        var lastRawOutput: String?
        do {
            let session = LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                instructions: PlanEditPrompt.systemPrompt
            )
            let first = try await Self.draft(from: session, prompt: prompt)
            lastRawOutput = first.planMarkdown
            let validated = try await PlanEditValidation.validate(first) { repairPrompt in
                let second = try await Self.draft(from: session, prompt: repairPrompt)
                lastRawOutput = second.planMarkdown
                return second
            }
            return PlanEditResult(
                planMarkdown: validated.planMarkdown,
                summary: validated.summary,
                warnings: validated.warnings,
                engine: .applePrivateCloud,
                quota: nil
            )
        } catch {
            let mapped = Self.mapError(error)
            if let lastRawOutput {
                ApplePlanEditSupport.logRawOutput(lastRawOutput, engine: .applePrivateCloud, reason: "\(mapped)")
            }
            ApplePlanEditSupport.logRawOutputIfPresent(in: error, engine: .applePrivateCloud)
            throw mapped
        }
    }

    /// One guided-generation turn: `PlanEditResponse` with the 4000-token
    /// output budget and light reasoning.
    @available(iOS 27, *)
    private static func draft(from session: LanguageModelSession, prompt: String) async throws -> PlanEditDraft {
        try await session.respond(
            to: prompt,
            generating: PlanEditResponse.self,
            options: GenerationOptions(maximumResponseTokens: maximumResponseTokens),
            contextOptions: ContextOptions(reasoningLevel: .light)
        ).content.draft
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

#else

/// Stand-in used when the app is compiled against an SDK older than iOS 27.
/// Same public surface as the real engine; every entry point reports that the
/// build lacks PCC support.
struct ApplePrivateCloudEngine: PlanEditEngine {
    static let requiresNewerSDKReason = "Apple Private Cloud Compute needs a build made with the iOS 27 SDK."

    let kind: PlanEditEngineKind = .applePrivateCloud
    let displayName = "Apple Private Cloud Compute"

    func availability() async -> PlanEditEngineAvailability {
        .unavailable(reason: Self.requiresNewerSDKReason)
    }

    func edit(_ request: PlanEditRequest) async throws -> PlanEditResult {
        throw PlanEditError.engineUnavailable(Self.requiresNewerSDKReason)
    }
}

#endif

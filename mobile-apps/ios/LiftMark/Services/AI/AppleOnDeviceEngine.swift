import Foundation
import FoundationModels

// MARK: - Structured output

/// The structured answer every Apple engine asks for. Mirrors the cloud
/// engine's `submit_plan_edit` tool schema (`{ plan_markdown, summary }`).
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

// MARK: - Shared Apple helpers

/// Pieces both Apple engines share: availability reason strings, FoundationModels
/// error mapping, and a rough token estimate for OS versions without
/// `tokenCount(for:)`. Everything here is pure so it stays testable even though
/// the engines themselves can only run on a device with Apple Intelligence.
enum ApplePlanEditSupport {
    /// Rough fallback when the SDK can't count tokens (pre-iOS 26.4): about
    /// four UTF-8 bytes per token for English prose and LMWF.
    static func estimatedTokenCount(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    static func reason(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to use Apple's on-device model."
        case .modelNotReady:
            return "Apple's on-device model is still downloading. Try again shortly."
        @unknown default:
            return "Apple's on-device model is unavailable."
        }
    }

    /// Map a FoundationModels failure to `PlanEditError`. Order matters: the
    /// iOS 27 `LanguageModelError` cases are checked first, then the iOS 26
    /// `GenerationError` cases they replaced, then the session-level errors.
    static func mapError(_ error: Error) -> PlanEditError {
        if error is CancellationError { return .cancelled }
        if let planEditError = error as? PlanEditError { return planEditError }
        if #available(iOS 27, *), let modelError = error as? LanguageModelError {
            return map(modelError)
        }
        if let generationError = error as? LanguageModelSession.GenerationError {
            return map(generationError)
        }
        return .model(describe(error))
    }

    @available(iOS 27, *)
    private static func map(_ error: LanguageModelError) -> PlanEditError {
        switch error {
        case .contextSizeExceeded:
            return .planTooLarge
        case .rateLimited(let limited):
            return .quotaExhausted(resetAt: limited.resetDate)
        default:
            return .model(describe(error))
        }
    }

    private static func map(_ error: LanguageModelSession.GenerationError) -> PlanEditError {
        switch error {
        case .exceededContextWindowSize:
            return .planTooLarge
        case .rateLimited:
            return .quotaExhausted(resetAt: nil)
        case .assetsUnavailable:
            return .engineUnavailable(describe(error))
        default:
            return .model(describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

// MARK: - Engine

/// `appleOnDevice`: FoundationModels `SystemLanguageModel` (iOS 26+). Uses the
/// compact prompt, checks the token budget before calling, and reserves 1200
/// output tokens. Never auto-selected in this phase; reachable only through the
/// developer override. See `spec/services/ai-plan-editing.md`.
struct AppleOnDeviceEngine: PlanEditEngine {
    static let reservedOutputTokens = 1200

    let kind: PlanEditEngineKind = .appleOnDevice
    let displayName = "Apple on-device"

    func availability() async -> PlanEditEngineAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: ApplePlanEditSupport.reason(for: reason))
        }
    }

    func edit(_ request: PlanEditRequest) async throws -> PlanEditResult {
        try PlanEditPrompt.checkSizeLimits(request)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw PlanEditError.engineUnavailable(await availabilityReason())
        }

        let instructions = PlanEditPrompt.compactSystemPrompt
        let prompt = PlanEditPrompt.userMessage(for: request)

        do {
            let needed = try await Self.inputTokenCount(model: model, instructions: instructions, prompt: prompt)
                + Self.reservedOutputTokens
            guard needed <= model.contextSize else { throw PlanEditError.planTooLarge }

            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(maximumResponseTokens: Self.reservedOutputTokens)
            let first = try await session.respond(to: prompt, generating: PlanEditResponse.self, options: options)
            let validated = try await PlanEditValidation.validate(first.content.draft) { repairPrompt in
                try await session.respond(to: repairPrompt, generating: PlanEditResponse.self, options: options)
                    .content.draft
            }
            return PlanEditResult(
                planMarkdown: validated.planMarkdown,
                summary: validated.summary,
                warnings: validated.warnings,
                engine: .appleOnDevice,
                quota: nil
            )
        } catch {
            throw ApplePlanEditSupport.mapError(error)
        }
    }

    // MARK: - Private

    private func availabilityReason() async -> String {
        if case .unavailable(let reason) = await availability() { return reason }
        return "Apple's on-device model is unavailable."
    }

    private static func inputTokenCount(
        model: SystemLanguageModel,
        instructions: String,
        prompt: String
    ) async throws -> Int {
        if #available(iOS 26.4, *) {
            return try await model.tokenCount(for: Instructions(instructions)) + model.tokenCount(for: prompt)
        }
        return ApplePlanEditSupport.estimatedTokenCount(instructions) + ApplePlanEditSupport.estimatedTokenCount(prompt)
    }
}

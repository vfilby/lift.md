import Foundation
import FoundationModels

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
        #if canImport(FoundationModels, _version: 2.0)
        if #available(iOS 27, *), let modelError = error as? LanguageModelError {
            return map(modelError)
        }
        #endif
        if let generationError = error as? LanguageModelSession.GenerationError {
            return map(generationError)
        }
        return .model(describe(error))
    }

    #if canImport(FoundationModels, _version: 2.0)
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
    #endif

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

    // MARK: Failure diagnostics

    /// Record the model's raw output in the device-local debug log so a parse
    /// failure can be diagnosed from Settings → Debug Logs. Debug entries are
    /// stored on the device only and never uploaded (service spec, "Failure
    /// diagnostics").
    static func logRawOutput(_ raw: String, engine: PlanEditEngineKind, reason: String) {
        Logger.shared.debug(
            .app,
            "ai plan edit failed (\(engine.rawValue)): \(reason)",
            metadata: ["engine": engine.rawValue, "raw_output": raw]
        )
    }

    /// If a FoundationModels error carries the content the model produced
    /// (iOS 27 `GeneratedContent.ParsingError` from guided generation), log it
    /// the same way. No-op for every other error.
    static func logRawOutputIfPresent(in error: Error, engine: PlanEditEngineKind) {
        #if canImport(FoundationModels, _version: 2.0)
        if #available(iOS 27, *), let parsing = error as? GeneratedContent.ParsingError {
            logRawOutput(parsing.rawContent, engine: engine, reason: parsing.debugDescription)
        }
        #endif
    }
}

// MARK: - Engine

/// `appleOnDevice`: FoundationModels `SystemLanguageModel` (iOS 26+). Uses the
/// compact prompt and a **plain-text** response (the plan followed by one
/// `SUMMARY:` line) instead of guided generation: the ~3B on-device model
/// cannot keep a multi-line plan intact inside a JSON string, which is what
/// produced "Failed to parse generated content" (GH #462, #463). The output
/// budget is whatever the context window leaves after the input, capped at
/// 4000 tokens. Never auto-selected in this phase; reachable only through the
/// developer override. See `spec/services/ai-plan-editing.md`.
struct AppleOnDeviceEngine: PlanEditEngine {
    let kind: PlanEditEngineKind = .appleOnDevice
    let displayName = "Apple on-device"

    /// Editing the user's own plan is a content transformation in Apple's
    /// sense (rewrite/summarise), which is what the permissive configuration
    /// exists for; it lowers the chance that exercise names or notes in a
    /// user's plan trip the general-purpose guardrails.
    static var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    func availability() async -> PlanEditEngineAvailability {
        switch Self.model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: ApplePlanEditSupport.reason(for: reason))
        }
    }

    func edit(_ request: PlanEditRequest) async throws -> PlanEditResult {
        try PlanEditPrompt.checkSizeLimits(request)
        let model = Self.model
        guard case .available = model.availability else {
            throw PlanEditError.engineUnavailable(await availabilityReason())
        }

        let instructions = PlanEditPrompt.compactSystemPrompt
        let prompt = PlanEditPrompt.userMessage(for: request)
        // The most recent text the model produced, kept for the failure log.
        var lastRawOutput: String?

        do {
            let inputTokens = try await Self.inputTokenCount(model: model, instructions: instructions, prompt: prompt)
            guard let budget = PlanEditOutputBudget.compute(contextSize: model.contextSize, inputTokens: inputTokens)
            else {
                throw PlanEditError.planTooLarge
            }

            let session = LanguageModelSession(model: model, instructions: instructions)
            let options = GenerationOptions(maximumResponseTokens: budget)
            let first = try await session.respond(to: prompt, options: options).content
            lastRawOutput = first
            let validated = try await PlanEditValidation.validate(
                PlanEditPlainTextOutput.parse(first),
                format: .plainText
            ) { repairPrompt in
                let second = try await session.respond(to: repairPrompt, options: options).content
                lastRawOutput = second
                return PlanEditPlainTextOutput.parse(second)
            }
            return PlanEditResult(
                planMarkdown: validated.planMarkdown,
                summary: validated.summary,
                warnings: validated.warnings,
                engine: .appleOnDevice,
                quota: nil
            )
        } catch {
            let mapped = ApplePlanEditSupport.mapError(error)
            if let lastRawOutput {
                ApplePlanEditSupport.logRawOutput(lastRawOutput, engine: .appleOnDevice, reason: "\(mapped)")
            }
            ApplePlanEditSupport.logRawOutputIfPresent(in: error, engine: .appleOnDevice)
            throw mapped
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

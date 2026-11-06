import Foundation

/// Deterministic test double, active only when the app is launched with
/// `--ai-engine-stub`. See `spec/services/ai-plan-editing.md` ("StubPlanEditEngine").
///
/// - Appends `## Face Pull` with three `- x 15` sets and returns the summary
///   "Added Face Pull (stub)."
/// - An instruction containing `fail` throws `.model("Stub failure")`.
/// - An instruction containing `quota` throws `.quotaExhausted(resetAt: nil)`.
struct StubPlanEditEngine: PlanEditEngine {
    static let launchArgument = "--ai-engine-stub"

    let kind: PlanEditEngineKind = .stub
    let displayName = "Stub engine"

    func availability() async -> PlanEditEngineAvailability {
        .available
    }

    func edit(_ request: PlanEditRequest) async throws -> PlanEditResult {
        let instruction = request.instruction.lowercased()
        if instruction.contains("fail") {
            throw PlanEditError.model("Stub failure")
        }
        if instruction.contains("quota") {
            throw PlanEditError.quotaExhausted(resetAt: nil)
        }

        let base = request.planMarkdown.trimmingTrailingWhitespace()
        let markdown = base + "\n\n## Face Pull\n- x 15\n- x 15\n- x 15\n"
        let parsed = MarkdownParser.parseWorkout(markdown)
        guard parsed.success else {
            throw PlanEditError.outputDidNotParse(parsed.errors)
        }
        return PlanEditResult(
            planMarkdown: markdown,
            summary: "Added Face Pull (stub).",
            warnings: parsed.warnings,
            engine: .stub,
            quota: nil
        )
    }
}

extension String {
    /// Drops trailing whitespace and newlines only.
    func trimmingTrailingWhitespace() -> String {
        var scalars = Substring(self)
        while let last = scalars.last, last.isWhitespace || last.isNewline {
            scalars.removeLast()
        }
        return String(scalars)
    }
}

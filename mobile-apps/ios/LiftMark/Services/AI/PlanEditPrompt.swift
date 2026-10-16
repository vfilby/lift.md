import Foundation

// MARK: - Prompt contract

/// Builds the prompt every engine sends and loads the canonical instruction
/// text. The system prompts are verbatim copies of `spec/data/*.md`
/// (`PlanEditPromptTests` fails if they drift). See
/// `spec/services/ai-plan-editing.md` ("Shared behaviour").
enum PlanEditPrompt {

    // MARK: Size limits (client-side, before any engine call)

    static let planMarkdownByteLimit = 32 * 1024
    static let instructionByteLimit = 2 * 1024
    static let historyByteLimit = 8 * 1024
    static let historyTurnLimit = 6

    /// Throws `.planTooLarge` when any input exceeds its byte limit.
    static func checkSizeLimits(_ request: PlanEditRequest) throws {
        guard request.planMarkdown.utf8.count <= planMarkdownByteLimit,
              request.instruction.utf8.count <= instructionByteLimit,
              request.history.reduce(0, { $0 + $1.content.utf8.count }) <= historyByteLimit
        else {
            throw PlanEditError.planTooLarge
        }
    }

    // MARK: Bundled instruction files

    /// Full instructions (Apple Private Cloud Compute; the server ships its own copy).
    static let systemPrompt: String = loadBundledPrompt(named: "ai-plan-edit-system-prompt")

    /// Compact instructions (Apple on-device only).
    static let compactSystemPrompt: String = loadBundledPrompt(named: "ai-plan-edit-system-prompt-compact")

    private static func loadBundledPrompt(named name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            Logger.shared.error(.app, "Missing bundled AI prompt: \(name).md")
            return ""
        }
        return text
    }

    // MARK: User message

    /// The user message layout. Blocks are omitted when empty; the plan and
    /// instruction blocks are always present.
    ///
    /// ```
    /// # USER CONTEXT
    /// Units: lbs
    /// Equipment: barbell, dumbbells, cable
    /// Recent sessions:
    /// <compact block>
    ///
    /// # CURRENT PLAN
    /// <planMarkdown verbatim>
    ///
    /// # CONVERSATION
    /// user: <turn>
    /// assistant: <turn>
    ///
    /// # INSTRUCTION
    /// <instruction>
    /// ```
    static func userMessage(for request: PlanEditRequest) -> String {
        var blocks: [String] = []

        var contextLines = ["Units: \(request.context.units.rawValue)"]
        if !request.context.equipment.isEmpty {
            contextLines.append("Equipment: \(request.context.equipment.joined(separator: ", "))")
        }
        if let recent = request.context.recentSessions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !recent.isEmpty {
            contextLines.append("Recent sessions:")
            contextLines.append(recent)
        }
        blocks.append("# USER CONTEXT\n" + contextLines.joined(separator: "\n"))

        blocks.append("# CURRENT PLAN\n" + request.planMarkdown)

        if !request.history.isEmpty {
            let turns = request.history.map { "\($0.role.rawValue): \($0.content)" }
            blocks.append("# CONVERSATION\n" + turns.joined(separator: "\n"))
        }

        blocks.append("# INSTRUCTION\n" + request.instruction)

        return blocks.joined(separator: "\n\n")
    }

    /// The single repair turn sent when the first output does not parse.
    static func repairMessage(previousOutput: String, errors: [String]) -> String {
        let errorLines = errors.map { "- \($0)" }.joined(separator: "\n")
        return """
        The plan you returned did not parse as lift.md. Parser errors:
        \(errorLines)

        Your previous plan_markdown:
        \(previousOutput)

        Return the corrected, complete plan as plan_markdown (no code fences) and keep the summary.
        """
    }

    // MARK: Output hygiene

    /// If the whole string is wrapped in one outer ``` fence (optionally with a
    /// language tag), return the content inside it; otherwise return the input
    /// unchanged. Engines never scrape fences out of the middle of a document.
    static func stripOuterCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count >= 6 else { return text }

        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return text }
        guard lines[0].hasPrefix("```"), lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" else {
            return text
        }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }
}

// MARK: - Validate once, repair once

/// Engine-agnostic shape of one model answer.
struct PlanEditDraft: Equatable, Sendable {
    var planMarkdown: String
    var summary: String
}

/// A draft that has passed the LMWF parser.
struct PlanEditValidatedOutput: Equatable, Sendable {
    let planMarkdown: String
    let summary: String
    let warnings: [String]
}

/// Shared "validate, repair once, then fail" step (service spec, Shared
/// behaviour item 4). Parser warnings never trigger a repair.
enum PlanEditValidation {
    /// - Parameter repair: Sends the repair prompt on the *same* model session
    ///   so the model sees its own prior output, and returns the second draft.
    static func validate(
        _ draft: PlanEditDraft,
        repair: (String) async throws -> PlanEditDraft
    ) async throws -> PlanEditValidatedOutput {
        let first = PlanEditPrompt.stripOuterCodeFence(draft.planMarkdown)
        let firstResult = MarkdownParser.parseWorkout(first)
        if firstResult.success {
            return PlanEditValidatedOutput(planMarkdown: first, summary: draft.summary, warnings: firstResult.warnings)
        }

        let repairPrompt = PlanEditPrompt.repairMessage(previousOutput: first, errors: firstResult.errors)
        let second = try await repair(repairPrompt)
        let secondMarkdown = PlanEditPrompt.stripOuterCodeFence(second.planMarkdown)
        let secondResult = MarkdownParser.parseWorkout(secondMarkdown)
        guard secondResult.success else {
            throw PlanEditError.outputDidNotParse(secondResult.errors)
        }
        return PlanEditValidatedOutput(
            planMarkdown: secondMarkdown,
            summary: second.summary,
            warnings: secondResult.warnings
        )
    }
}

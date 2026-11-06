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
              (request.originalMarkdown?.utf8.count ?? 0) <= planMarkdownByteLimit,
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
    /// # ORIGINAL PLAN
    /// <originalMarkdown verbatim, only when it differs from planMarkdown>
    ///
    /// # CURRENT PLAN
    /// <planMarkdown verbatim>
    ///
    /// # PLAN WARNINGS
    /// - <parser warning for planMarkdown>
    ///
    /// # CONVERSATION
    /// user: <turn>
    /// assistant: <turn>
    ///
    /// # INSTRUCTION
    /// <instruction>
    /// ```
    ///
    /// - Parameter includeOriginal: False for the on-device engine, whose
    ///   context window cannot hold two copies of a plan.
    static func userMessage(for request: PlanEditRequest, includeOriginal: Bool = true) -> String {
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

        if includeOriginal, let original = originalBlockMarkdown(for: request) {
            blocks.append("# ORIGINAL PLAN\n" + original)
        }

        blocks.append("# CURRENT PLAN\n" + request.planMarkdown)

        let warnings = MarkdownParser.parseWorkout(request.planMarkdown).warnings
        if !warnings.isEmpty {
            blocks.append("# PLAN WARNINGS\n" + warnings.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !request.history.isEmpty {
            let turns = request.history.map { "\($0.role.rawValue): \($0.content)" }
            blocks.append("# CONVERSATION\n" + turns.joined(separator: "\n"))
        }

        blocks.append("# INSTRUCTION\n" + request.instruction)

        return blocks.joined(separator: "\n\n")
    }

    /// `originalMarkdown` when it is worth sending: non-blank and different
    /// from the current plan after trimming.
    private static func originalBlockMarkdown(for request: PlanEditRequest) -> String? {
        guard let original = request.originalMarkdown else { return nil }
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != request.planMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return original
    }

    /// The single repair turn sent when the first output does not parse. The
    /// closing instruction names whichever output contract the engine uses.
    static func repairMessage(
        previousOutput: String,
        errors: [String],
        format: PlanEditOutputFormat = .structured
    ) -> String {
        let errorLines = errors.map { "- \($0)" }.joined(separator: "\n")
        let ask: String
        switch format {
        case .structured:
            ask = "Return the corrected, complete plan as plan_markdown (no code fences) and keep the summary."
        case .plainText:
            ask = "Return the corrected, complete plan as plain markdown (no code fences), "
                + "then one final line starting with `SUMMARY:`."
        }
        return """
        The plan you returned did not parse as lift.md. Parser errors:
        \(errorLines)

        Your previous plan:
        \(previousOutput)

        \(ask)
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

// MARK: - Output contracts

/// How an engine asks the model for its answer. Decides the wording of the
/// repair turn; parsing the answer is the engine's job.
enum PlanEditOutputFormat: Sendable {
    /// `{ plan_markdown, summary }` via guided generation (Apple PCC) or tool
    /// use (Bedrock).
    case structured
    /// The plan as plain markdown followed by one `SUMMARY:` line (Apple
    /// on-device, whose small model cannot keep a multi-line plan intact inside
    /// a JSON string).
    case plainText
}

/// Parser for the plain-text contract (service spec, "AppleOnDeviceEngine"):
///
/// ```
/// <complete plan in lift.md markdown>
/// SUMMARY: <one sentence>
/// ```
enum PlanEditPlainTextOutput {
    static let summaryPrefix = "SUMMARY:"
    /// Used when the model omits the summary line or leaves it empty.
    static let defaultSummary = "Edited on device."

    /// Split the model's text on the *last* `SUMMARY:` line (case-insensitive,
    /// leading whitespace allowed). Everything before it is the plan; an earlier
    /// `SUMMARY:` line inside the plan stays in the plan. One outer code fence
    /// is stripped from the whole text and again from the plan, so a fence
    /// around everything or around just the plan both work.
    static func parse(_ text: String) -> PlanEditDraft {
        let unfenced = PlanEditPrompt.stripOuterCodeFence(text)
        let lines = unfenced.split(separator: "\n", omittingEmptySubsequences: false)

        var planLines = lines[...]
        var summary = defaultSummary
        if let index = lines.lastIndex(where: { isSummaryLine($0) }) {
            let line = lines[index].drop(while: { $0 == " " || $0 == "\t" })
            let rest = line.dropFirst(summaryPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { summary = rest }
            planLines = lines[..<index]
        }

        let joined = planLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = PlanEditPrompt.stripOuterCodeFence(joined).trimmingCharacters(in: .whitespacesAndNewlines)
        return PlanEditDraft(planMarkdown: plan, summary: summary)
    }

    private static func isSummaryLine(_ line: Substring) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).uppercased().hasPrefix(summaryPrefix)
    }
}

/// Output-token budget for the on-device model (service spec, "Dynamic output
/// budget"). Pure so the arithmetic is unit-testable without a model.
enum PlanEditOutputBudget {
    /// Tokens the chat template adds around instructions and prompt.
    static let templateSlackTokens = 64
    /// Never ask for more than this, whatever the context allows.
    static let maximumResponseTokens = 4000
    /// Below this many available tokens a full plan rewrite cannot fit.
    static let minimumResponseTokens = 600

    /// `maximumResponseTokens` for one call, or `nil` when the input leaves too
    /// little room for a complete plan (`.planTooLarge`).
    static func compute(contextSize: Int, inputTokens: Int) -> Int? {
        let available = contextSize - inputTokens - templateSlackTokens
        guard available >= minimumResponseTokens else { return nil }
        return min(available, maximumResponseTokens)
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
    /// - Parameters:
    ///   - format: Which output contract the repair turn should ask for.
    ///   - repair: Sends the repair prompt on the *same* model session so the
    ///     model sees its own prior output, and returns the second draft.
    static func validate(
        _ draft: PlanEditDraft,
        format: PlanEditOutputFormat = .structured,
        repair: (String) async throws -> PlanEditDraft
    ) async throws -> PlanEditValidatedOutput {
        let first = PlanEditPrompt.stripOuterCodeFence(draft.planMarkdown)
        let firstResult = MarkdownParser.parseWorkout(first)
        if firstResult.success {
            return PlanEditValidatedOutput(planMarkdown: first, summary: draft.summary, warnings: firstResult.warnings)
        }

        let repairPrompt = PlanEditPrompt.repairMessage(
            previousOutput: first,
            errors: firstResult.errors,
            format: format
        )
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

import XCTest
@testable import LiftMark

/// Prompt contract shared by every engine. See spec/services/ai-plan-editing.md
/// ("Shared behaviour").
final class PlanEditPromptTests: XCTestCase {

    // MARK: - User message layout

    func testUserMessageLayoutWithEveryBlock() {
        let request = PlanEditRequest(
            planMarkdown: "# Push Day\n\n## Bench Press\n- 135 x 5",
            instruction: "swap bench for dumbbell press",
            history: [
                PlanEditTurn(role: .user, content: "make it shorter"),
                PlanEditTurn(role: .assistant, content: "Dropped the last set."),
            ],
            context: PlanEditContext(
                units: .lbs,
                equipment: ["barbell", "dumbbells", "cable"],
                recentSessions: "2026-10-01 Push Day: Bench 185x5x3"
            )
        )

        let expected = """
        # USER CONTEXT
        Units: lbs
        Equipment: barbell, dumbbells, cable
        Recent sessions:
        2026-10-01 Push Day: Bench 185x5x3

        # CURRENT PLAN
        # Push Day

        ## Bench Press
        - 135 x 5

        # CONVERSATION
        user: make it shorter
        assistant: Dropped the last set.

        # INSTRUCTION
        swap bench for dumbbell press
        """
        XCTAssertEqual(PlanEditPrompt.userMessage(for: request), expected)
    }

    func testUserMessageOmitsEmptyBlocks() {
        let request = PlanEditRequest(
            planMarkdown: "# Legs\n\n## Squat\n- 100 x 5",
            instruction: "add a warm-up",
            history: [],
            context: PlanEditContext(units: .kg, equipment: [], recentSessions: "   ")
        )

        let expected = """
        # USER CONTEXT
        Units: kg

        # CURRENT PLAN
        # Legs

        ## Squat
        - 100 x 5

        # INSTRUCTION
        add a warm-up
        """
        XCTAssertEqual(PlanEditPrompt.userMessage(for: request), expected)
    }

    // MARK: - Original plan and warnings (GH #469)

    func testUserMessageCarriesOriginalPlanAndCurrentPlanWarnings() throws {
        // A stray `@rpe` modifier on its own line is a parser warning.
        let current = "# Push Day\n\n## Bench Press\n- 135 x 5\n@rpe: 8"
        let warnings = MarkdownParser.parseWorkout(current).warnings
        try XCTSkipIf(warnings.isEmpty, "fixture no longer produces a parser warning")

        let request = PlanEditRequest(
            planMarkdown: current,
            originalMarkdown: "# Push Day\n\n## Bench Press\n- 135 x 5\n\n## Bird Dog\n- x 10",
            instruction: "put the bird dogs back",
            history: [],
            context: PlanEditContext(units: .lbs)
        )

        let expected = """
        # USER CONTEXT
        Units: lbs

        # ORIGINAL PLAN
        # Push Day

        ## Bench Press
        - 135 x 5

        ## Bird Dog
        - x 10

        # CURRENT PLAN
        # Push Day

        ## Bench Press
        - 135 x 5
        @rpe: 8

        # PLAN WARNINGS
        \(warnings.map { "- \($0)" }.joined(separator: "\n"))

        # INSTRUCTION
        put the bird dogs back
        """
        XCTAssertEqual(PlanEditPrompt.userMessage(for: request), expected)

        let onDevice = PlanEditPrompt.userMessage(for: request, includeOriginal: false)
        XCTAssertFalse(onDevice.contains("# ORIGINAL PLAN"), "on-device omits the second copy of the plan")
        XCTAssertTrue(onDevice.contains("# PLAN WARNINGS"), "on-device still sees the warnings")
    }

    func testOriginalPlanOmittedWhenItMatchesTheCurrentPlanOrIsBlank() {
        for original in [PlanEditFixtures.pushDay, "\n" + PlanEditFixtures.pushDay + "\n\n", "  "] {
            let request = PlanEditRequest(
                planMarkdown: PlanEditFixtures.pushDay,
                originalMarkdown: original,
                instruction: "x",
                history: [],
                context: PlanEditContext(units: .lbs)
            )
            let message = PlanEditPrompt.userMessage(for: request)
            XCTAssertFalse(message.contains("# ORIGINAL PLAN"))
            XCTAssertFalse(message.contains("# PLAN WARNINGS"), "a clean plan has no warnings block")
        }
    }

    func testSystemPromptsTellTheModelToRestoreWhereThingsCameFrom() {
        let full = PlanEditPrompt.systemPrompt
        XCTAssertTrue(full.contains("restore that exercise exactly as it appears in `ORIGINAL PLAN`"))
        XCTAssertTrue(full.contains("The `PLAN WARNINGS` block"))
        XCTAssertTrue(full.contains("A superset must keep at least two exercises"))
        let compact = PlanEditPrompt.compactSystemPrompt
        XCTAssertTrue(compact.contains("put the exercise back exactly where it was before"))
        XCTAssertTrue(compact.contains("PLAN WARNINGS"))
    }

    // MARK: - Size limits

    func testSizeLimitsAcceptTypicalRequest() {
        XCTAssertNoThrow(try PlanEditPrompt.checkSizeLimits(PlanEditFixtures.request()))
    }

    func testPlanOverLimitThrowsPlanTooLarge() {
        let huge = String(repeating: "- 135 x 5\n", count: 4_000)   // ~40 KB
        XCTAssertThrowsError(try PlanEditPrompt.checkSizeLimits(PlanEditFixtures.request(plan: huge))) { error in
            XCTAssertEqual(error as? PlanEditError, .planTooLarge)
        }
    }

    func testOriginalPlanOverLimitThrowsPlanTooLarge() {
        let huge = String(repeating: "- 135 x 5\n", count: 4_000)   // ~40 KB
        let request = PlanEditRequest(
            planMarkdown: PlanEditFixtures.pushDay,
            originalMarkdown: huge,
            instruction: "x",
            history: [],
            context: PlanEditContext(units: .lbs)
        )
        XCTAssertThrowsError(try PlanEditPrompt.checkSizeLimits(request)) { error in
            XCTAssertEqual(error as? PlanEditError, .planTooLarge)
        }
    }

    func testInstructionOverLimitThrowsPlanTooLarge() {
        let long = String(repeating: "x", count: 2_049)
        XCTAssertThrowsError(try PlanEditPrompt.checkSizeLimits(PlanEditFixtures.request(instruction: long))) { error in
            XCTAssertEqual(error as? PlanEditError, .planTooLarge)
        }
    }

    func testHistoryOverLimitThrowsPlanTooLarge() {
        let turn = PlanEditTurn(role: .user, content: String(repeating: "y", count: 3_000))
        let request = PlanEditFixtures.request(history: [turn, turn, turn])
        XCTAssertThrowsError(try PlanEditPrompt.checkSizeLimits(request)) { error in
            XCTAssertEqual(error as? PlanEditError, .planTooLarge)
        }
    }

    // MARK: - Repair message

    func testRepairMessageAsksForTheEngineOutputFormat() {
        let errors = ["Line 3: unknown set"]
        let structured = PlanEditPrompt.repairMessage(previousOutput: "# P", errors: errors)
        XCTAssertTrue(structured.contains("- Line 3: unknown set"))
        XCTAssertTrue(structured.contains("as plan_markdown"))
        XCTAssertFalse(structured.contains("SUMMARY:"))

        let plain = PlanEditPrompt.repairMessage(previousOutput: "# P", errors: errors, format: .plainText)
        XCTAssertTrue(plain.contains("- Line 3: unknown set"))
        XCTAssertTrue(plain.contains("# P"))
        XCTAssertTrue(plain.contains("`SUMMARY:`"))
        XCTAssertFalse(plain.contains("plan_markdown"))
    }

    // MARK: - Code fences

    func testStripOuterCodeFence() {
        XCTAssertEqual(PlanEditPrompt.stripOuterCodeFence("```markdown\n# Plan\n- 1 x 1\n```"), "# Plan\n- 1 x 1")
        XCTAssertEqual(PlanEditPrompt.stripOuterCodeFence("```\n# Plan\n```\n"), "# Plan")
        XCTAssertEqual(PlanEditPrompt.stripOuterCodeFence("# Plan\n- 1 x 1"), "# Plan\n- 1 x 1")
        // Inner fences are the document's business, not ours.
        let inner = "# Plan\n```\nnot a fence we strip\n```\n- 1 x 1"
        XCTAssertEqual(PlanEditPrompt.stripOuterCodeFence(inner), inner)
    }

    // MARK: - Bundled prompt files

    func testBundledPromptsMatchSpecData() throws {
        let specDir = try XCTUnwrap(Self.repoRoot()).appendingPathComponent("spec/data")
        let full = try String(
            contentsOf: specDir.appendingPathComponent("ai-plan-edit-system-prompt.md"),
            encoding: .utf8
        )
        let compact = try String(
            contentsOf: specDir.appendingPathComponent("ai-plan-edit-system-prompt-compact.md"),
            encoding: .utf8
        )

        XCTAssertFalse(PlanEditPrompt.systemPrompt.isEmpty, "full prompt must be bundled")
        XCTAssertFalse(PlanEditPrompt.compactSystemPrompt.isEmpty, "compact prompt must be bundled")
        XCTAssertEqual(PlanEditPrompt.systemPrompt, full, "bundled full prompt drifted from spec/data")
        XCTAssertEqual(PlanEditPrompt.compactSystemPrompt, compact, "bundled compact prompt drifted from spec/data")
    }

    // MARK: - Validate once, repair once

    func testValidationReturnsFirstDraftWhenItParses() async throws {
        var repairCalls = 0
        let output = try await PlanEditValidation.validate(
            PlanEditDraft(planMarkdown: "```\n" + PlanEditFixtures.pushDay + "\n```", summary: "fine")
        ) { _ in
            repairCalls += 1
            return PlanEditDraft(planMarkdown: "", summary: "")
        }
        XCTAssertEqual(repairCalls, 0)
        XCTAssertEqual(output.planMarkdown, PlanEditFixtures.pushDay, "outer fence is stripped before parsing")
        XCTAssertEqual(output.summary, "fine")
    }

    func testValidationRepairsOnce() async throws {
        var repairPrompts: [String] = []
        let output = try await PlanEditValidation.validate(
            PlanEditDraft(planMarkdown: "no header here\n- 135 x 5", summary: "first")
        ) { prompt in
            repairPrompts.append(prompt)
            return PlanEditDraft(planMarkdown: PlanEditFixtures.pushDay, summary: "repaired")
        }
        XCTAssertEqual(repairPrompts.count, 1)
        XCTAssertTrue(repairPrompts[0].contains("no header here"), "repair turn includes the previous output")
        XCTAssertTrue(repairPrompts[0].contains("Parser errors:"))
        XCTAssertEqual(output.summary, "repaired")
    }

    func testValidationFailsAfterSecondBadOutput() async {
        do {
            _ = try await PlanEditValidation.validate(
                PlanEditDraft(planMarkdown: "still broken", summary: "")
            ) { _ in
                PlanEditDraft(planMarkdown: "still broken again", summary: "")
            }
            XCTFail("expected outputDidNotParse")
        } catch let error as PlanEditError {
            guard case .outputDidNotParse(let errors) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertFalse(errors.isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testValidationKeepsWarningsWithoutRepair() async throws {
        // A stray `@rpe` modifier on its own line produces a warning, not an error.
        let withWarning = PlanEditFixtures.pushDay + "\n@rpe: 8\n"
        let parsed = MarkdownParser.parseWorkout(withWarning)
        try XCTSkipIf(parsed.warnings.isEmpty, "fixture no longer produces a parser warning")

        var repairCalls = 0
        let output = try await PlanEditValidation.validate(
            PlanEditDraft(planMarkdown: withWarning, summary: "")
        ) { _ in
            repairCalls += 1
            return PlanEditDraft(planMarkdown: "", summary: "")
        }
        XCTAssertEqual(repairCalls, 0, "warnings never trigger a repair")
        XCTAssertEqual(output.warnings, parsed.warnings)
    }

    // MARK: - Helpers

    /// Walk up from this source file to the repository root (the directory
    /// containing `spec/`).
    private static func repoRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("spec/data").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

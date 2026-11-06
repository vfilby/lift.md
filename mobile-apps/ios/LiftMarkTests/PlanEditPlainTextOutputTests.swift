import XCTest
@testable import LiftMark

/// Plain-text output contract and output budget used by the Apple on-device
/// engine. See spec/services/ai-plan-editing.md ("AppleOnDeviceEngine").
final class PlanEditPlainTextOutputTests: XCTestCase {

    private let plan = """
    # Push Day
    @units: lbs

    ## Bench Press
    - 135 x 5
    - 185 x 5
    """

    // MARK: - Parsing

    func testSplitsPlanAndSummary() {
        let draft = PlanEditPlainTextOutput.parse(plan + "\n\nSUMMARY: Dropped the top set.\n")
        XCTAssertEqual(draft.planMarkdown, plan)
        XCTAssertEqual(draft.summary, "Dropped the top set.")
    }

    func testMissingSummaryFallsBackToDefault() {
        let draft = PlanEditPlainTextOutput.parse(plan)
        XCTAssertEqual(draft.planMarkdown, plan)
        XCTAssertEqual(draft.summary, PlanEditPlainTextOutput.defaultSummary)
        XCTAssertEqual(PlanEditPlainTextOutput.defaultSummary, "Edited on device.")
    }

    func testEmptySummaryFallsBackToDefault() {
        let draft = PlanEditPlainTextOutput.parse(plan + "\nSUMMARY:   \n")
        XCTAssertEqual(draft.planMarkdown, plan)
        XCTAssertEqual(draft.summary, "Edited on device.")
    }

    func testFenceAroundEverythingIsStripped() {
        let draft = PlanEditPlainTextOutput.parse("```markdown\n" + plan + "\nSUMMARY: ok\n```")
        XCTAssertEqual(draft.planMarkdown, plan)
        XCTAssertEqual(draft.summary, "ok")
    }

    func testFenceAroundPlanOnlyIsStripped() {
        let draft = PlanEditPlainTextOutput.parse("```\n" + plan + "\n```\n\nSUMMARY: ok")
        XCTAssertEqual(draft.planMarkdown, plan)
        XCTAssertEqual(draft.summary, "ok")
    }

    func testTrailingWhitespaceIsTrimmed() {
        let draft = PlanEditPlainTextOutput.parse("\n\n" + plan + "   \n\n\n   SUMMARY: trimmed   \n\n")
        XCTAssertEqual(draft.planMarkdown, plan)
        XCTAssertEqual(draft.summary, "trimmed")
    }

    func testEarlierSummaryLineStaysInPlan() {
        let planWithNote = plan + "\nSUMMARY: this is a note the model wrote mid-plan\n\n## Fly\n- 30 x 12"
        let draft = PlanEditPlainTextOutput.parse(planWithNote + "\nSUMMARY: Added flys.")
        XCTAssertEqual(draft.planMarkdown, planWithNote, "only the last SUMMARY line is the summary")
        XCTAssertEqual(draft.summary, "Added flys.")
    }

    func testSummaryPrefixIsCaseInsensitiveAndMayBeIndented() {
        let draft = PlanEditPlainTextOutput.parse(plan + "\n  summary: lower case works")
        XCTAssertEqual(draft.planMarkdown, plan)
        XCTAssertEqual(draft.summary, "lower case works")
    }

    func testTextAfterSummaryLineIsIgnored() {
        let draft = PlanEditPlainTextOutput.parse(plan + "\nSUMMARY: one sentence.\nLet me know if you want more!")
        XCTAssertEqual(draft.planMarkdown, plan)
        XCTAssertEqual(draft.summary, "one sentence.")
    }

    func testParsedPlanPassesTheLMWFParser() {
        let draft = PlanEditPlainTextOutput.parse("```\n" + plan + "\n```\nSUMMARY: fine")
        XCTAssertTrue(MarkdownParser.parseWorkout(draft.planMarkdown).success)
    }

    // MARK: - Output budget

    func testBudgetIsWhatTheContextLeavesMinusSlack() {
        XCTAssertEqual(PlanEditOutputBudget.compute(contextSize: 4096, inputTokens: 1000), 4096 - 1000 - 64)
    }

    func testBudgetIsCappedAtFourThousand() {
        XCTAssertEqual(PlanEditOutputBudget.compute(contextSize: 8192, inputTokens: 700), 4000)
    }

    func testBudgetIsNilBelowSixHundredAvailable() {
        XCTAssertNil(PlanEditOutputBudget.compute(contextSize: 4096, inputTokens: 4096 - 64 - 599))
        XCTAssertEqual(PlanEditOutputBudget.compute(contextSize: 4096, inputTokens: 4096 - 64 - 600), 600)
    }

    func testBudgetIsNilWhenInputExceedsContext() {
        XCTAssertNil(PlanEditOutputBudget.compute(contextSize: 4096, inputTokens: 5000))
    }
}

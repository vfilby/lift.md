import XCTest
@testable import LiftMark

/// One sheet's state machine. See spec/services/ai-plan-editing.md ("Session").
@MainActor
final class PlanEditSessionTests: XCTestCase {

    private static let planId = "plan-1"
    private static let withFacePull = PlanEditFixtures.pushDay + "\n\n## Face Pull\n- x 15\n- x 15\n- x 15\n"
    private static let withDips = withFacePull + "\n## Dips\n- x 10\n"

    private var engine: FakePlanEditEngine!
    private var store: FakePlanEditPlanStore!
    private var session: PlanEditSession!

    override func setUp() async throws {
        try await super.setUp()
        engine = FakePlanEditEngine(kind: .liftMarkCloud, displayName: "Cloud")
        var plan = PlanEditFixtures.parse(PlanEditFixtures.pushDay)
        plan.id = Self.planId
        plan.sourceMarkdown = PlanEditFixtures.pushDay
        store = FakePlanEditPlanStore(plans: [plan])
        session = PlanEditSession(
            planId: Self.planId,
            originalMarkdown: PlanEditFixtures.pushDay,
            engine: engine,
            context: PlanEditContext(units: .lbs, equipment: ["barbell"]),
            planStore: store
        )
    }

    // MARK: - send

    func testSendSuccessRecordsProposalAndChainsWorkingMarkdown() async {
        engine.outcomes = [.success(markdown: Self.withFacePull, summary: "Added Face Pull.", warnings: ["w1"])]

        await session.send("add face pulls")

        XCTAssertEqual(session.workingMarkdown, Self.withFacePull)
        XCTAssertEqual(session.pendingProposal?.markdown, Self.withFacePull)
        XCTAssertFalse(session.proposalIsEmpty)
        XCTAssertNil(session.appliedMarkdown, "nothing persisted until Apply")
        XCTAssertTrue(store.updates.isEmpty)
        XCTAssertFalse(session.isThinking)

        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.messages[0].content, .user("add face pulls"))
        guard case .assistant(let summary, let diff, let warnings) = session.messages[1].content else {
            return XCTFail("expected assistant message, got \(session.messages[1])")
        }
        XCTAssertEqual(summary, "Added Face Pull.")
        XCTAssertEqual(warnings, ["w1"])
        XCTAssertEqual(diff.changedEntries.count, 1)
        guard case .added(let added)? = diff.changedEntries.first else {
            return XCTFail("expected an added entry")
        }
        XCTAssertEqual(added.name, "Face Pull")

        // The request edited the original markdown with no history.
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(engine.requests[0].planMarkdown, PlanEditFixtures.pushDay)
        XCTAssertEqual(engine.requests[0].history, [])
        XCTAssertEqual(engine.requests[0].context.equipment, ["barbell"])
    }

    func testSecondSendEditsTheProposalNotTheOriginal() async {
        engine.outcomes = [
            .success(markdown: Self.withFacePull),
            .success(markdown: Self.withDips),
        ]

        await session.send("add face pulls")
        await session.send("add dips")

        XCTAssertEqual(engine.requests[1].planMarkdown, Self.withFacePull, "edits chain off the proposal")
        XCTAssertEqual(engine.requests[1].history, [
            PlanEditTurn(role: .user, content: "add face pulls"),
            PlanEditTurn(role: .assistant, content: "ok"),
        ])
        XCTAssertEqual(session.workingMarkdown, Self.withDips)
        XCTAssertEqual(session.pendingProposal?.markdown, Self.withDips)
    }

    func testSendFailureLeavesWorkingMarkdownAndRecordsError() async {
        engine.outcomes = [.failure(.model("Stub failure"))]

        await session.send("fail")

        XCTAssertEqual(session.workingMarkdown, PlanEditFixtures.pushDay)
        XCTAssertNil(session.pendingProposal)
        XCTAssertEqual(session.messages.last?.content, .error(.model("Stub failure")))
        XCTAssertFalse(session.isInputLocked)
        XCTAssertTrue(session.canSend)
    }

    func testQuotaExhaustedLocksInput() async {
        engine.outcomes = [.failure(.quotaExhausted(resetAt: nil))]
        await session.send("quota")
        XCTAssertTrue(session.isInputLocked)
        XCTAssertFalse(session.canSend)

        await session.send("again")
        XCTAssertEqual(engine.requests.count, 1, "locked input never reaches the engine")
    }

    func testSubscriptionRequiredLocksInput() async {
        engine.outcomes = [.failure(.subscriptionRequired)]
        await session.send("x")
        XCTAssertTrue(session.isInputLocked)
    }

    func testErrorsAreExcludedFromHistory() async {
        engine.outcomes = [.failure(.network), .success(markdown: Self.withFacePull)]
        await session.send("first")
        await session.send("second")
        XCTAssertEqual(engine.requests[1].history, [PlanEditTurn(role: .user, content: "first")])
    }

    func testHistoryIsCappedAtSixTurns() async {
        for index in 1...5 {
            engine.outcomes.append(.success(markdown: PlanEditFixtures.pushDay, summary: "s\(index)"))
        }
        for index in 1...5 {
            await session.send("i\(index)")
        }
        // 5 user + 5 assistant turns exist; the 6th request carries the last 6.
        await session.send("i6")

        let history = engine.requests[5].history
        XCTAssertEqual(history.count, 6)
        XCTAssertEqual(history.first, PlanEditTurn(role: .user, content: "i3"))
        XCTAssertEqual(history.last, PlanEditTurn(role: .assistant, content: "s5"))
    }

    func testEmptyInstructionIsIgnored() async {
        await session.send("   ")
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertTrue(engine.requests.isEmpty)
    }

    func testOversizedPlanFailsBeforeEngineCall() async {
        let huge = String(repeating: "- 135 x 5\n", count: 4_000)
        session = PlanEditSession(
            planId: Self.planId,
            originalMarkdown: huge,
            engine: engine,
            context: PlanEditContext(units: .lbs),
            planStore: store
        )
        await session.send("trim")
        XCTAssertEqual(session.messages.last?.content, .error(.planTooLarge))
        XCTAssertTrue(engine.requests.isEmpty)
    }

    func testUnchangedResultProducesEmptyDiff() async {
        engine.outcomes = [.success(markdown: PlanEditFixtures.pushDay + "\n")]
        await session.send("do nothing")
        XCTAssertNotNil(session.pendingProposal)
        XCTAssertTrue(session.proposalIsEmpty, "sheet shows 'No changes were made' and disables Apply")
    }

    func testQuotaIsCachedFromResults() async {
        let quota = PlanEditQuota(limit: 20, remaining: 19, resetAt: Date(timeIntervalSince1970: 0), inGrace: false)
        engine.outcomes = [.success(markdown: Self.withFacePull, quota: quota), .success(markdown: Self.withDips)]
        await session.send("a")
        XCTAssertEqual(session.quota, quota)
        await session.send("b")
        XCTAssertEqual(session.quota, quota, "a result without quota keeps the last known value")
    }

    // MARK: - apply / undo / discard

    func testApplyPersistsThroughPlanStore() async {
        engine.outcomes = [.success(markdown: Self.withFacePull)]
        await session.send("add face pulls")

        session.apply()

        XCTAssertEqual(store.updates.count, 1)
        XCTAssertEqual(store.updates[0].id, Self.planId)
        XCTAssertEqual(store.updates[0].markdown, Self.withFacePull)
        XCTAssertEqual(store.getPlan(id: Self.planId)?.sourceMarkdown, Self.withFacePull)
        XCTAssertEqual(session.appliedMarkdown, Self.withFacePull)
        XCTAssertNil(session.pendingProposal)
        XCTAssertEqual(session.workingMarkdown, Self.withFacePull, "keep chatting edits the applied plan")
        XCTAssertTrue(session.canUndo)
    }

    func testApplyWithoutProposalIsNoOp() {
        session.apply()
        XCTAssertTrue(store.updates.isEmpty)
        XCTAssertFalse(session.canUndo)
    }

    func testUndoRestoresPreviouslyPersistedMarkdown() async {
        engine.outcomes = [.success(markdown: Self.withFacePull), .success(markdown: Self.withDips)]
        await session.send("a")
        session.apply()
        await session.send("b")
        session.apply()
        XCTAssertEqual(store.updates.map(\.markdown), [Self.withFacePull, Self.withDips])

        session.undo()

        XCTAssertEqual(store.updates.last?.markdown, Self.withFacePull, "one level: back to the previous Apply")
        XCTAssertEqual(session.appliedMarkdown, Self.withFacePull)
        XCTAssertEqual(session.workingMarkdown, Self.withFacePull)
        XCTAssertFalse(session.canUndo, "undo is one level deep")

        session.undo()
        XCTAssertEqual(store.updates.count, 3, "second undo is a no-op")
    }

    func testUndoAfterFirstApplyRestoresOriginal() async {
        engine.outcomes = [.success(markdown: Self.withFacePull)]
        await session.send("a")
        session.apply()
        session.undo()
        XCTAssertEqual(store.updates.last?.markdown, PlanEditFixtures.pushDay)
        XCTAssertEqual(session.appliedMarkdown, PlanEditFixtures.pushDay)
    }

    func testDiscardResetsToOriginalWhenNothingApplied() async {
        engine.outcomes = [.success(markdown: Self.withFacePull)]
        await session.send("a")

        session.discard()

        XCTAssertNil(session.pendingProposal)
        XCTAssertEqual(session.workingMarkdown, PlanEditFixtures.pushDay)
        XCTAssertTrue(store.updates.isEmpty)
    }

    func testDiscardResetsToLastAppliedMarkdown() async {
        engine.outcomes = [.success(markdown: Self.withFacePull), .success(markdown: Self.withDips)]
        await session.send("a")
        session.apply()
        await session.send("b")

        session.discard()

        XCTAssertEqual(session.workingMarkdown, Self.withFacePull)
        XCTAssertNil(session.pendingProposal)
    }

    // MARK: - cancel

    func testCancelAbortsInFlightCallAndRecordsCancelled() async {
        engine.holdUntilCancelled = true

        let sending = Task { await session.send("slow") }
        // Let the send reach the engine before cancelling.
        while engine.requests.isEmpty {
            await Task.yield()
        }
        XCTAssertTrue(session.isThinking)

        session.cancel()
        await sending.value

        XCTAssertFalse(session.isThinking)
        XCTAssertEqual(session.messages.last?.content, .error(.cancelled))
        XCTAssertEqual(session.workingMarkdown, PlanEditFixtures.pushDay)
        XCTAssertNil(session.pendingProposal)
        XCTAssertTrue(session.canSend, "cancel does not lock the input")
    }

    // MARK: - availability

    func testRefreshAvailabilityRecordsUnavailableReason() async {
        engine.availabilityResult = .unavailable(reason: "Sign in to use LiftMark cloud")
        await session.refreshAvailability()
        XCTAssertEqual(session.availability, .unavailable(reason: "Sign in to use LiftMark cloud"))
        XCTAssertEqual(session.messages.last?.content, .error(.engineUnavailable("Sign in to use LiftMark cloud")))
        XCTAssertFalse(session.canSend)
    }

    func testRefreshAvailabilityQuotaExhaustedLocksInput() async {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        engine.availabilityResult = .quotaExhausted(resetAt: reset)
        await session.refreshAvailability()
        XCTAssertTrue(session.isInputLocked)
        XCTAssertEqual(session.messages.last?.content, .error(.quotaExhausted(resetAt: reset)))
    }

    func testRefreshAvailabilityAvailableAddsNoMessage() async {
        await session.refreshAvailability()
        XCTAssertEqual(session.availability, .available)
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertTrue(session.canSend)
    }
}

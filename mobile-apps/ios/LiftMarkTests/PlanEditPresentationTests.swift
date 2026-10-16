import XCTest
@testable import LiftMark

/// View-logic helpers behind the Edit with AI entry row and sheet header:
/// the tier gate, the engine/quota caption, the quick-action chips, and the
/// diff row slugs. See `spec/services/ai-plan-editing.md` ("Gating") and
/// `spec/flows/ai-plan-editing.md` ("Engine-specific notes").
final class PlanEditPresentationTests: XCTestCase {

    // MARK: - Gate

    func testGateHiddenWhenFlagOff() {
        XCTAssertEqual(
            AIEditGate.decision(flagOn: false, hasMarkdown: true, tier: .pro, stubActive: true),
            .hidden
        )
    }

    func testGateHiddenWithoutMarkdown() {
        XCTAssertEqual(
            AIEditGate.decision(flagOn: true, hasMarkdown: false, tier: .pro, stubActive: false),
            .hidden
        )
    }

    func testGateShowsButtonForProAndTrial() {
        XCTAssertEqual(AIEditGate.decision(flagOn: true, hasMarkdown: true, tier: .pro, stubActive: false), .button)
        XCTAssertEqual(AIEditGate.decision(flagOn: true, hasMarkdown: true, tier: .trial, stubActive: false), .button)
        XCTAssertTrue(AIEditGate.shouldShowButton(flagOn: true, hasMarkdown: true, tier: .pro, stubActive: false))
    }

    func testGateShowsUpsellForFreeAndSignedOut() {
        XCTAssertEqual(AIEditGate.decision(flagOn: true, hasMarkdown: true, tier: .free, stubActive: false), .upsell)
        XCTAssertEqual(AIEditGate.decision(flagOn: true, hasMarkdown: true, tier: nil, stubActive: false), .upsell)
        XCTAssertFalse(AIEditGate.shouldShowButton(flagOn: true, hasMarkdown: true, tier: nil, stubActive: false))
    }

    func testGateStubSatisfiesTierRegardlessOfAuth() {
        XCTAssertEqual(AIEditGate.decision(flagOn: true, hasMarkdown: true, tier: nil, stubActive: true), .button)
        XCTAssertEqual(AIEditGate.decision(flagOn: true, hasMarkdown: true, tier: .free, stubActive: true), .button)
    }

    // MARK: - Quota label

    private func quota(limit: Int = 20, remaining: Int, inGrace: Bool = false) -> PlanEditQuota {
        PlanEditQuota(limit: limit, remaining: remaining, resetAt: Date(), inGrace: inGrace)
    }

    func testQuotaLabelNilWithoutQuota() {
        XCTAssertNil(PlanEditLabels.quotaLabel(nil))
        XCTAssertNil(PlanEditLabels.quotaLabel(nil, isApproachingLimit: false))
    }

    func testQuotaLabelNormal() {
        XCTAssertEqual(PlanEditLabels.quotaLabel(quota(remaining: 17)), "17 of 20 left today")
        XCTAssertEqual(PlanEditLabels.quotaLabel(quota(remaining: 0)), "0 of 20 left today")
    }

    func testQuotaLabelInGraceCountsExtraAgainstCeiling() {
        // limit 20 → ceiling 22; count 21 → remaining -1 → 1 extra left.
        XCTAssertEqual(
            PlanEditLabels.quotaLabel(quota(remaining: -1, inGrace: true)),
            "Over today's limit \u{00B7} 1 extra left"
        )
        XCTAssertEqual(
            PlanEditLabels.quotaLabel(quota(remaining: -2, inGrace: true)),
            "Over today's limit \u{00B7} 0 extra left"
        )
        XCTAssertEqual(PlanEditLabels.graceCeiling(limit: 20), 22)
        XCTAssertEqual(PlanEditLabels.graceCeiling(limit: 10), 11)
    }

    func testApproachingLimitWinsOverNumbers() {
        XCTAssertEqual(
            PlanEditLabels.quotaLabel(quota(remaining: 3), isApproachingLimit: true),
            "Nearing Apple's daily limit"
        )
        XCTAssertEqual(PlanEditLabels.quotaLabel(nil, isApproachingLimit: true), "Nearing Apple's daily limit")
    }

    func testPrivacyFooterNamesEngine() {
        XCTAssertTrue(PlanEditLabels.privacyFooter(engineName: "LiftMark cloud").contains("LiftMark cloud"))
    }

    func testUnchangedSummaryPluralises() {
        XCTAssertEqual(PlanEditLabels.unchangedSummary(count: 1), "1 exercise unchanged")
        XCTAssertEqual(PlanEditLabels.unchangedSummary(count: 4), "4 exercises unchanged")
    }

    // MARK: - Chips

    func testChipSlugsMatchAccessibilityContract() {
        XCTAssertEqual(
            PlanEditQuickAction.all.map(\.slug),
            ["make-it-shorter", "swap-barbell-for-dumbbells", "add-a-warm-up", "progress-loads", "thirty-minutes"]
        )
        XCTAssertEqual(
            PlanEditQuickAction.all.map(\.title),
            [
                "Make it shorter", "Swap barbell for dumbbells", "Add a warm-up",
                "Progress loads 2.5%", "I only have 30 min",
            ]
        )
        XCTAssertEqual(PlanEditQuickAction.all[0].accessibilityIdentifier, "ai-edit-chip-make-it-shorter")
        for chip in PlanEditQuickAction.all {
            XCTAssertFalse(chip.instruction.isEmpty)
        }
    }

    // MARK: - Diff rows

    private func exercise(_ name: String, parent: String? = nil, sets: [String] = ["- x 15"]) -> PlanDiffExercise {
        PlanDiffExercise(name: name, parent: parent, notes: nil, equipmentType: nil, setLines: sets)
    }

    func testSlugify() {
        XCTAssertEqual(PlanDiffRowPresentation.slugify("Face Pull"), "face-pull")
        XCTAssertEqual(PlanDiffRowPresentation.slugify("  DB Row (single-arm) "), "db-row-single-arm")
        XCTAssertEqual(PlanDiffRowPresentation.slugify("Romanian Deadlift @ 80%"), "romanian-deadlift-80")
    }

    func testRowPresentationPerKind() {
        let added = PlanDiffRowPresentation(entry: .added(exercise("Face Pull")))
        XCTAssertEqual(added?.accessibilityIdentifier, "ai-edit-diff-row-added-face-pull")
        XCTAssertEqual(added?.kind.marker, "+")
        XCTAssertEqual(added?.lines, ["- x 15"])

        let removed = PlanDiffRowPresentation(entry: .removed(exercise("Bench Press", sets: ["- 135 lbs x 5"])))
        XCTAssertEqual(removed?.slug, "removed-bench-press")
        XCTAssertEqual(removed?.kind.marker, "\u{2212}")

        let changed = PlanDiffRowPresentation(entry: .changed(
            before: exercise("Squat", parent: "A", sets: ["- 185 lbs x 5"]),
            after: exercise("Squat", parent: "A", sets: ["- 190 lbs x 5"])
        ))
        XCTAssertEqual(changed?.slug, "changed-squat")
        XCTAssertEqual(changed?.kind.marker, "~")
        XCTAssertEqual(changed?.parent, "A")
        XCTAssertEqual(changed?.previousLines, ["- 185 lbs x 5"])
        XCTAssertEqual(changed?.lines, ["- 190 lbs x 5"])

        XCTAssertNil(PlanDiffRowPresentation(entry: .unchanged(exercise("Squat"))))
    }

    // MARK: - Session quota state

    @MainActor
    func testIsQuotaExhaustedFromAvailabilityAndFromTurn() async {
        let engine = FakePlanEditEngine(availability: .quotaExhausted(resetAt: nil))
        let store = FakePlanEditPlanStore()
        let session = PlanEditSession(
            planId: "p", originalMarkdown: PlanEditFixtures.pushDay, engine: engine,
            context: PlanEditContext(units: .lbs), planStore: store
        )
        XCTAssertFalse(session.isQuotaExhausted)
        await session.refreshAvailability()
        XCTAssertTrue(session.isQuotaExhausted)

        let engine2 = FakePlanEditEngine()
        engine2.outcomes = [.failure(.quotaExhausted(resetAt: nil))]
        let session2 = PlanEditSession(
            planId: "p", originalMarkdown: PlanEditFixtures.pushDay, engine: engine2,
            context: PlanEditContext(units: .lbs), planStore: store
        )
        await session2.refreshAvailability()
        XCTAssertFalse(session2.isQuotaExhausted)
        await session2.send("anything")
        XCTAssertTrue(session2.isQuotaExhausted)
    }
}

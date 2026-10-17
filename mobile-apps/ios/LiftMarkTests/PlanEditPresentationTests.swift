import XCTest
@testable import LiftMark

/// View-logic helpers behind the Edit with AI entry row and sheet: the tier
/// gate, the engine/quota caption, the quick-action chips, the status strip,
/// and the live preview built from diff entries. See
/// `spec/services/ai-plan-editing.md` ("Gating", "Diff") and
/// `spec/screens/workout-detail.md` ("AI Edit Sheet").
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

    func testChangeCountCaption() {
        XCTAssertEqual(PlanEditLabels.changeCount(.empty), "No changes")
        let one = PlanDiff(entries: [.added(exercise("Face Pull"))], headerChanges: [])
        XCTAssertEqual(PlanEditLabels.changeCount(one), "1 change")
        let three = PlanDiff(
            entries: [.added(exercise("A")), .removed(exercise("B")), .unchanged(exercise("C"))],
            headerChanges: ["Renamed"]
        )
        XCTAssertEqual(PlanEditLabels.changeCount(three), "3 changes")
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

    // MARK: - Preview rows

    private func exercise(
        _ name: String,
        parent: String? = nil,
        parentKind: PlanDiffExercise.ParentKind? = nil,
        section: String? = nil,
        sets: [String] = ["- x 15"]
    ) -> PlanDiffExercise {
        PlanDiffExercise(
            name: name, parent: parent, parentKind: parentKind, section: section,
            notes: nil, equipmentType: nil, setLines: sets
        )
    }

    func testSlugify() {
        XCTAssertEqual(PlanEditPreviewRow.slugify("Face Pull"), "face-pull")
        XCTAssertEqual(PlanEditPreviewRow.slugify("  DB Row (single-arm) "), "db-row-single-arm")
        XCTAssertEqual(PlanEditPreviewRow.slugify("Romanian Deadlift @ 80%"), "romanian-deadlift-80")
    }

    func testRowPresentationPerKind() {
        let added = PlanEditPreviewRow(id: 0, entry: .added(exercise("Face Pull")))
        XCTAssertEqual(added.accessibilityIdentifier, "ai-edit-diff-row-added-face-pull")
        XCTAssertEqual(added.kind.marker, "+")
        XCTAssertEqual(added.lines, ["x 15"], "LMWF bullet is stripped for display")

        let removed = PlanEditPreviewRow(id: 1, entry: .removed(exercise("Bench Press", sets: ["- 135 lbs x 5"])))
        XCTAssertEqual(removed.accessibilityIdentifier, "ai-edit-diff-row-removed-bench-press")
        XCTAssertEqual(removed.kind.marker, "\u{2212}")
        XCTAssertEqual(removed.lines, ["135 lbs x 5"])

        let changed = PlanEditPreviewRow(id: 2, entry: .changed(
            before: exercise("Squat", parent: "A", sets: ["- 185 lbs x 5"]),
            after: exercise("Squat", parent: "A", sets: ["- 190 lbs x 5"])
        ))
        XCTAssertEqual(changed.accessibilityIdentifier, "ai-edit-diff-row-changed-squat")
        XCTAssertEqual(changed.kind.marker, "~")
        XCTAssertEqual(changed.previousLines, ["185 lbs x 5"])
        XCTAssertEqual(changed.lines, ["190 lbs x 5"])

        let unchanged = PlanEditPreviewRow(id: 3, entry: .unchanged(exercise("Squat")))
        XCTAssertEqual(unchanged.kind, .unchanged)
        XCTAssertNil(unchanged.kind.marker)
        XCTAssertEqual(unchanged.accessibilityIdentifier, "ai-edit-preview-row-squat")
    }

    // MARK: - Preview

    private func parse(_ markdown: String) -> WorkoutPlan {
        guard let plan = MarkdownParser.parseWorkout(markdown).data else {
            XCTFail("fixture did not parse")
            return WorkoutPlan(name: "?")
        }
        return plan
    }

    func testPreviewWithoutProposalShowsEveryExerciseUnchanged() {
        let plan = parse(PlanEditFixtures.pushDay)
        let preview = PlanEditPreview(plan: plan, diff: nil)

        XCTAssertFalse(preview.isDiff)
        XCTAssertEqual(preview.accessibilityIdentifier, "ai-edit-preview")
        XCTAssertEqual(preview.title, plan.name)
        XCTAssertTrue(preview.headerChanges.isEmpty)
        let rows = preview.sections.flatMap(\.items).compactMap { item -> PlanEditPreviewRow? in
            if case .exercise(let row) = item { return row }
            return nil
        }
        XCTAssertEqual(rows.count, plan.displayExerciseCount)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .unchanged })
        XCTAssertEqual(rows.map(\.name), plan.exercises.filter { !$0.isStructuralHeader }.map(\.exerciseName))
    }

    func testPreviewWithProposalIsTheDiffContainerAndKeepsRemovedRowsInPlace() {
        let before = parse("""
        # Day
        ## Bench Press
        - 135 x 5
        ## Row
        - 95 x 8
        ## Curl
        - 30 x 10
        """)
        let after = parse("""
        # Day
        ## Bench Press
        - 135 x 5
        ## Curl
        - 35 x 10
        ## Face Pull
        - x 15
        """)
        let diff = PlanDiffBuilder.diff(before: before, after: after)
        let preview = PlanEditPreview(plan: after, diff: diff)

        XCTAssertTrue(preview.isDiff)
        XCTAssertEqual(preview.accessibilityIdentifier, "ai-edit-diff")
        XCTAssertEqual(preview.sections.count, 1)
        XCTAssertNil(preview.sections[0].name)
        let rows = preview.sections[0].items.compactMap { item -> PlanEditPreviewRow? in
            if case .exercise(let row) = item { return row }
            return nil
        }
        XCTAssertEqual(rows.map(\.name), ["Bench Press", "Row", "Curl", "Face Pull"])
        XCTAssertEqual(rows.map(\.kind), [.unchanged, .removed, .changed, .added])
        XCTAssertEqual(rows.map(\.accessibilityIdentifier), [
            "ai-edit-preview-row-bench-press",
            "ai-edit-diff-row-removed-row",
            "ai-edit-diff-row-changed-curl",
            "ai-edit-diff-row-added-face-pull",
        ])
        XCTAssertEqual(rows.map(\.id), [0, 1, 2, 3], "ids are ordinals, so repeated names stay distinct")
    }

    func testPreviewGroupsSectionsAndSupersets() {
        let plan = parse("""
        # Full Body
        @units: lbs

        ## Warmup
        ### Band Pull-Apart
        - x 20

        ## Superset: Arms
        ### Curl
        - 30 x 10
        ### Pushdown
        - 40 x 12

        ## Main
        ### Superset: Press
        #### Bench Press
        - 135 x 5
        #### Row
        - 95 x 8
        ### Squat
        - 185 x 5

        ## Plank
        - 60s
        """)
        let preview = PlanEditPreview(plan: plan, diff: nil)

        XCTAssertEqual(preview.sections.map(\.name), ["Warmup", nil, "Main", nil])

        guard case .exercise(let warmup)? = preview.sections[0].items.first else {
            return XCTFail("warmup child should be a plain row")
        }
        XCTAssertEqual(warmup.name, "Band Pull-Apart")

        guard case .superset(_, let armsName, let armsRows)? = preview.sections[1].items.first else {
            return XCTFail("top-level superset should group its members")
        }
        XCTAssertEqual(armsName, "Superset: Arms")
        XCTAssertEqual(armsRows.map(\.name), ["Curl", "Pushdown"])

        XCTAssertEqual(preview.sections[2].items.count, 2)
        guard case .superset(_, let pressName, let pressRows)? = preview.sections[2].items.first,
              case .exercise(let squat)? = preview.sections[2].items.last else {
            return XCTFail("nested superset should sit inside its section")
        }
        XCTAssertEqual(pressName, "Superset: Press")
        XCTAssertEqual(pressRows.map(\.name), ["Bench Press", "Row"])
        XCTAssertEqual(squat.name, "Squat")

        guard case .exercise(let plank)? = preview.sections[3].items.first else {
            return XCTFail("trailing top-level exercise")
        }
        XCTAssertEqual(plank.name, "Plank")
        XCTAssertEqual(plank.lines, ["60s"])
    }

    func testPreviewCarriesHeaderChanges() {
        let before = parse("# Push\n## Bench Press\n- 135 x 5\n")
        let after = parse("# Push Day\n## Bench Press\n- 135 x 5\n")
        let diff = PlanDiffBuilder.diff(before: before, after: after)
        let preview = PlanEditPreview(plan: after, diff: diff)
        XCTAssertEqual(preview.title, "Push Day")
        XCTAssertEqual(preview.headerChanges, ["Renamed to \u{201C}Push Day\u{201D}"])
    }

    // MARK: - Status strip

    func testStatusPrefersThinkingThenLatestMessage() {
        XCTAssertEqual(PlanEditStatus.current(messages: [], isThinking: false), .hint)
        XCTAssertEqual(PlanEditStatus.current(messages: [.user("hi")], isThinking: true), .thinking)
        XCTAssertEqual(PlanEditStatus.current(messages: [.user("hi")], isThinking: false), .hint)

        let diff = PlanDiff(entries: [.added(exercise("Face Pull"))], headerChanges: [])
        let assistant = PlanEditMessage.assistant(summary: "Added Face Pull.", diff: diff, warnings: ["w"])
        XCTAssertEqual(
            PlanEditStatus.current(messages: [.user("hi"), assistant], isThinking: false),
            .summary("Added Face Pull.", warnings: ["w"], isEmptyDiff: false)
        )
        let noop = PlanEditMessage.assistant(summary: "Nothing to do.", diff: .empty, warnings: [])
        XCTAssertEqual(
            PlanEditStatus.current(messages: [assistant, .user("again"), noop], isThinking: false),
            .summary("Nothing to do.", warnings: [], isEmptyDiff: true)
        )
        XCTAssertEqual(
            PlanEditStatus.current(messages: [assistant, .error(.network)], isThinking: false),
            .error(.network)
        )
        XCTAssertEqual(
            PlanEditStatus.current(messages: [.error(.network)], isThinking: true),
            .thinking,
            "a new turn hides the previous error"
        )
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

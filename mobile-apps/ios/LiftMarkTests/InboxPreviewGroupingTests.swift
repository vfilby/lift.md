import XCTest
@testable import LiftMark

/// GH #443: the inbox preview sheet rendered the parser's zero-set section
/// container ("## Warm-Up") as its own "0 sets" exercise card next to its
/// children. The sheet now groups via `PlanDisplayBuilder`, so structural
/// headers become section dividers / superset group labels, never cards.
final class InboxPreviewGroupingTests: XCTestCase {

    private static let lmwf = """
    # Lift Day 1 - Upper Push
    @units: lbs

    ## Warm-Up

    ### Inchworm
    - x 4 @rest: 20s
    - x 4 @rest: 20s

    ### Arm Circles
    - x 10

    ## Bench Press
    - 135 x 5
    - 185 x 5

    ## Superset: Arms

    ### Tricep Pushdown
    - 50 x 12

    ### Curl
    - 30 x 12
    """

    private func makeSheet() throws -> InboxPreviewSheet {
        let result = MarkdownParser.parseWorkout(Self.lmwf)
        let plan = try XCTUnwrap(result.data, "fixture must parse: \(result.errors)")
        return InboxPreviewSheet(
            plan: plan, createdAtServer: Date(), sourceTokenId: nil,
            onDiscard: {}, onAddToPlans: {}, onStart: {}
        )
    }

    /// Every exercise card the sheet renders (single cards + superset children).
    private func renderedCards(_ sections: [ExerciseDisplaySection]) -> [PlannedExercise] {
        sections.flatMap { section in
            section.items.flatMap { item -> [PlannedExercise] in
                switch item {
                case .single(let exercise): return [exercise]
                case .superset(_, let children): return children
                }
            }
        }
    }

    func testSectionHeaderIsNotRenderedAsExerciseCard() throws {
        let sheet = try makeSheet()
        // Precondition: the parser does emit the zero-set "Warm-Up" container.
        XCTAssertTrue(sheet.plan.exercises.contains { $0.exerciseName == "Warm-Up" && $0.isStructuralHeader })

        let cards = renderedCards(sheet.exerciseSections)
        XCTAssertFalse(cards.contains { $0.isStructuralHeader }, "structural headers must not get a card")
        XCTAssertFalse(cards.contains { $0.sets.isEmpty }, "no 0-set cards")
        XCTAssertEqual(
            cards.map(\.exerciseName),
            ["Inchworm", "Arm Circles", "Bench Press", "Tricep Pushdown", "Curl"]
        )
        // Card count matches the header's exercise count.
        XCTAssertEqual(cards.count, sheet.plan.displayExerciseCount)
    }

    func testSectionHeaderRendersAsDividerOverItsChildren() throws {
        let sections = try makeSheet().exerciseSections
        let warmUp = try XCTUnwrap(sections.first)
        XCTAssertEqual(warmUp.name, "Warm-Up")
        XCTAssertEqual(renderedCards([warmUp]).map(\.exerciseName), ["Inchworm", "Arm Circles"])
        // Top-level exercises after the section are outside it.
        XCTAssertTrue(sections.dropFirst().allSatisfy { $0.name == nil })
    }

    func testSupersetParentRendersAsGroupNotCard() throws {
        let items = try makeSheet().exerciseSections.flatMap(\.items)
        let supersets = items.compactMap { item -> (PlannedExercise, [PlannedExercise])? in
            if case .superset(let parent, let children) = item { return (parent, children) }
            return nil
        }
        XCTAssertEqual(supersets.count, 1)
        XCTAssertEqual(supersets.first?.0.exerciseName, "Superset: Arms")
        XCTAssertEqual(supersets.first?.1.map(\.exerciseName), ["Tricep Pushdown", "Curl"])
    }
}

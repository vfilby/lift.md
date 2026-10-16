import Foundation
import XCTest
@testable import LiftMark

// MARK: - Fixtures

enum PlanEditFixtures {
    static let pushDay = """
    # Push Day
    @tags: strength, push
    @units: lbs

    ## Bench Press
    @rest: 180s
    - 135 x 5
    - 185 x 5
    - 225 x 5

    ## Overhead Press
    - 95 x 8
    - 95 x 8
    """

    static func parse(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) -> WorkoutPlan {
        let result = MarkdownParser.parseWorkout(markdown)
        guard let plan = result.data else {
            XCTFail("fixture failed to parse: \(result.errors)", file: file, line: line)
            return WorkoutPlan(name: "invalid")
        }
        return plan
    }

    static func request(
        plan: String = pushDay,
        instruction: String = "add a warm-up",
        history: [PlanEditTurn] = [],
        context: PlanEditContext = PlanEditContext(units: .lbs)
    ) -> PlanEditRequest {
        PlanEditRequest(planMarkdown: plan, instruction: instruction, history: history, context: context)
    }
}

// MARK: - Fake engine

/// Scripted `PlanEditEngine`. Each `edit` pops the next scripted outcome; when
/// the script is empty it echoes the plan back unchanged. `holdUntilCancelled`
/// parks the call so cancellation can be exercised.
final class FakePlanEditEngine: PlanEditEngine, @unchecked Sendable {
    enum Outcome {
        case success(markdown: String, summary: String = "ok", warnings: [String] = [], quota: PlanEditQuota? = nil)
        case failure(PlanEditError)
    }

    let kind: PlanEditEngineKind
    let displayName: String
    var availabilityResult: PlanEditEngineAvailability
    var outcomes: [Outcome] = []
    var holdUntilCancelled = false
    private(set) var requests: [PlanEditRequest] = []
    private(set) var availabilityCalls = 0

    init(
        kind: PlanEditEngineKind = .stub,
        displayName: String = "Fake",
        availability: PlanEditEngineAvailability = .available
    ) {
        self.kind = kind
        self.displayName = displayName
        self.availabilityResult = availability
    }

    func availability() async -> PlanEditEngineAvailability {
        availabilityCalls += 1
        return availabilityResult
    }

    func edit(_ request: PlanEditRequest) async throws -> PlanEditResult {
        requests.append(request)
        if holdUntilCancelled {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            throw CancellationError()
        }
        guard !outcomes.isEmpty else {
            return PlanEditResult(
                planMarkdown: request.planMarkdown,
                summary: "No change",
                warnings: [],
                engine: kind,
                quota: nil
            )
        }
        switch outcomes.removeFirst() {
        case .success(let markdown, let summary, let warnings, let quota):
            return PlanEditResult(
                planMarkdown: markdown, summary: summary, warnings: warnings, engine: kind, quota: quota
            )
        case .failure(let error):
            throw error
        }
    }
}

// MARK: - Fake plan store

@MainActor
final class FakePlanEditPlanStore: PlanEditPlanStoring {
    private(set) var plans: [String: WorkoutPlan] = [:]
    private(set) var updates: [(id: String, markdown: String)] = []

    init(plans: [WorkoutPlan] = []) {
        for plan in plans {
            self.plans[plan.id] = plan
        }
    }

    func getPlan(id: String) -> WorkoutPlan? {
        plans[id]
    }

    func updatePlanMarkdown(id: String, newMarkdown: String) {
        updates.append((id, newMarkdown))
        let result = MarkdownParser.parseWorkout(newMarkdown)
        guard result.success, let parsed = result.data, var plan = plans[id] else { return }
        plan.sourceMarkdown = newMarkdown
        plan.exercises = parsed.exercises
        plan.name = parsed.name
        plans[id] = plan
    }
}

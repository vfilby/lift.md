import FoundationModels
import XCTest
@testable import LiftMark

/// Runs the real Apple on-device engine. Local only and opt-in: skipped unless
/// `LIFTMARK_LIVE_AI=1` is in the test environment *and* the simulator (or
/// device) reports `SystemLanguageModel.default.availability == .available`,
/// which needs a Mac with Apple Intelligence enabled. CI runners never have
/// it. The opt-in exists because the default `make test-unit` destination is
/// the iOS 26.0 simulator, and the iOS 26.x simulator runtimes cannot run the
/// model on a macOS 27 host even though they report it available (guardrail
/// classifier and model-catalog assets fail to load), so the class would fail
/// there on every Mac with Apple Intelligence. Run it with an iOS 27 simulator:
///
///     TEST_RUNNER_LIFTMARK_LIVE_AI=1 xcodebuild test -scheme LiftMark -project LiftMark.xcodeproj \
///       -testPlan Full -only-testing:LiftMarkTests/AppleOnDeviceEngineLiveTests \
///       -destination 'platform=iOS Simulator,name=iPhone17Pro-iOS27,OS=27.0'
///
/// Small models are nondeterministic; a failure here is a prompt-quality
/// signal, not a build break. See spec/services/ai-plan-editing.md
/// ("Testing → iOS unit").
final class AppleOnDeviceEngineLiveTests: XCTestCase {
    static let optInEnvironmentKey = "LIFTMARK_LIVE_AI"

    static let plan = """
    # Full Body A
    @tags: strength, full-body
    @units: lbs

    ## Back Squat
    @rest: 180s
    - 135 x 5
    - 185 x 5
    - 225 x 5
    - 225 x 5

    ## Bench Press
    @rest: 150s
    - 135 x 8
    - 155 x 8
    - 175 x 6

    ## Barbell Row
    @rest: 120s
    - 135 x 8
    - 155 x 8
    - 155 x 8

    ## Overhead Press
    - 95 x 8
    - 95 x 8
    - 95 x 8

    ## Pull-Up
    - x 8
    - x 8
    - x AMRAP

    ## Plank
    - 60s
    - 60s
    - 45s
    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip("Set \(Self.optInEnvironmentKey)=1 to run the live on-device model tests")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple on-device model is not available in this simulator")
        }
    }

    func testMakeItShorter() async throws {
        try await edit("Make it shorter")
    }

    func testSwitchOutTheCoreExercise() async throws {
        try await edit("Switch out the core exercise")
    }

    func testSwapBarbellForDumbbells() async throws {
        try await edit("Swap barbell for dumbbells")
    }

    func testAddAWarmUp() async throws {
        try await edit("Add a warm-up")
    }

    // MARK: - Helpers

    private func edit(_ instruction: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let request = PlanEditRequest(
            planMarkdown: Self.plan,
            instruction: instruction,
            history: [],
            context: PlanEditContext(units: .lbs, equipment: ["barbell", "dumbbells", "cable", "pull-up bar"])
        )
        let result = try await AppleOnDeviceEngine().edit(request)

        let parsed = MarkdownParser.parseWorkout(result.planMarkdown)
        let failure = "\(instruction): \(parsed.errors)\n\(result.planMarkdown)"
        XCTAssertTrue(parsed.success, failure, file: file, line: line)
        XCTAssertFalse(parsed.data?.exercises.isEmpty ?? true, "\(instruction): no exercises", file: file, line: line)
        XCTAssertFalse(result.summary.isEmpty, "\(instruction): empty summary", file: file, line: line)
        XCTAssertEqual(result.engine, .appleOnDevice, file: file, line: line)
        print("[live on-device] \(instruction) -> \(result.summary)\n\(result.planMarkdown)")
    }
}

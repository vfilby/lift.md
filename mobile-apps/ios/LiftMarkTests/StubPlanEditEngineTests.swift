import XCTest
@testable import LiftMark

/// `StubPlanEditEngine` is the deterministic double UI tests drive with
/// `--ai-engine-stub`. See spec/services/ai-plan-editing.md ("StubPlanEditEngine").
final class StubPlanEditEngineTests: XCTestCase {

    private let engine = StubPlanEditEngine()

    func testAlwaysAvailable() async {
        let availability = await engine.availability()
        XCTAssertEqual(availability, .available)
    }

    func testAppendsFacePullWithThreeSets() async throws {
        let result = try await engine.edit(PlanEditFixtures.request(instruction: "add face pulls"))

        XCTAssertEqual(result.engine, .stub)
        XCTAssertEqual(result.summary, "Added Face Pull (stub).")
        XCTAssertNil(result.quota)
        XCTAssertTrue(result.planMarkdown.hasPrefix(PlanEditFixtures.pushDay))

        let plan = PlanEditFixtures.parse(result.planMarkdown)
        let facePull = plan.exercises.first { $0.exerciseName == "Face Pull" }
        XCTAssertNotNil(facePull)
        XCTAssertEqual(facePull?.sets.count, 3)
        XCTAssertEqual(facePull?.sets.map(\.targetReps), [15, 15, 15])
        XCTAssertEqual(plan.exercises.last?.exerciseName, "Face Pull", "Face Pull is appended at the end")
    }

    func testOutputIsDeterministic() async throws {
        let first = try await engine.edit(PlanEditFixtures.request())
        let second = try await engine.edit(PlanEditFixtures.request())
        XCTAssertEqual(first, second)
    }

    func testFailInstructionThrowsModelError() async {
        do {
            _ = try await engine.edit(PlanEditFixtures.request(instruction: "please FAIL this"))
            XCTFail("expected a thrown error")
        } catch let error as PlanEditError {
            XCTAssertEqual(error, .model("Stub failure"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testQuotaInstructionThrowsQuotaExhausted() async {
        do {
            _ = try await engine.edit(PlanEditFixtures.request(instruction: "quota check"))
            XCTFail("expected a thrown error")
        } catch let error as PlanEditError {
            XCTAssertEqual(error, .quotaExhausted(resetAt: nil))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testLaunchArgumentName() {
        XCTAssertEqual(StubPlanEditEngine.launchArgument, "--ai-engine-stub")
    }
}

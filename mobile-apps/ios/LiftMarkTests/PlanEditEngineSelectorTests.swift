import XCTest
@testable import LiftMark

/// Engine selection order. See spec/services/ai-plan-editing.md ("Engine selection").
final class PlanEditEngineSelectorTests: XCTestCase {

    private var stub: FakePlanEditEngine!
    private var privateCloud: FakePlanEditEngine!
    private var onDevice: FakePlanEditEngine!
    private var cloud: FakePlanEditEngine!

    override func setUp() {
        super.setUp()
        stub = FakePlanEditEngine(kind: .stub, displayName: "Stub")
        privateCloud = FakePlanEditEngine(kind: .applePrivateCloud, displayName: "PCC")
        onDevice = FakePlanEditEngine(kind: .appleOnDevice, displayName: "On-device")
        cloud = FakePlanEditEngine(kind: .liftMarkCloud, displayName: "Cloud")
    }

    private func makeSelector(launchArguments: [String] = []) -> PlanEditEngineSelector {
        let stub = stub!, privateCloud = privateCloud!, onDevice = onDevice!, cloud = cloud!
        let factories = PlanEditEngineFactories(
            stub: { stub },
            applePrivateCloud: { privateCloud },
            appleOnDevice: { onDevice },
            liftMarkCloud: { cloud }
        )
        return PlanEditEngineSelector(factories: factories, launchArguments: launchArguments)
    }

    func testStubLaunchArgumentWinsOverEverything() async {
        let selector = makeSelector(launchArguments: ["--ai-engine-stub", "--ai-engine-override=liftMarkCloud"])
        let engine = await selector.select(override: .liftMarkCloud, isSignedIn: true)
        XCTAssertEqual(engine.kind, .stub)
        XCTAssertTrue(selector.isStubActive)
        XCTAssertEqual(privateCloud.availabilityCalls, 0, "no availability probing when the stub is forced")
    }

    func testOverrideForcesEngineEvenWhenUnavailable() async {
        onDevice.availabilityResult = .unavailable(reason: "Apple Intelligence is off")
        let selector = makeSelector()

        let engine = await selector.select(override: .appleOnDevice, isSignedIn: true)
        XCTAssertEqual(engine.kind, .appleOnDevice)
        let availability = await engine.availability()
        XCTAssertEqual(availability, .unavailable(reason: "Apple Intelligence is off"),
                       "the forced engine's real availability is surfaced, not swallowed")
    }

    func testAutoPrefersPrivateCloudWhenAvailable() async {
        let selector = makeSelector()
        let engine = await selector.select(override: .auto, isSignedIn: true)
        XCTAssertEqual(engine.kind, .applePrivateCloud)
        XCTAssertEqual(cloud.availabilityCalls, 0, "stops at the first available engine")
    }

    func testAutoFallsBackToCloudWhenPrivateCloudUnavailable() async {
        privateCloud.availabilityResult = .unavailable(reason: "Requires iOS 27")
        let selector = makeSelector()
        let engine = await selector.select(override: .auto, isSignedIn: true)
        XCTAssertEqual(engine.kind, .liftMarkCloud)
    }

    func testAutoTreatsQuotaExhaustedAsUnavailable() async {
        privateCloud.availabilityResult = .quotaExhausted(resetAt: nil)
        let selector = makeSelector()
        let engine = await selector.select(override: .auto, isSignedIn: true)
        XCTAssertEqual(engine.kind, .liftMarkCloud)
    }

    func testAutoNeverPicksOnDevice() async {
        privateCloud.availabilityResult = .unavailable(reason: "no")
        cloud.availabilityResult = .unavailable(reason: "Sign in to use LiftMark cloud")
        let selector = makeSelector()
        _ = await selector.select(override: .auto, isSignedIn: false)
        XCTAssertEqual(onDevice.availabilityCalls, 0)
    }

    func testNoneAvailableReturnsLastEngineTried() async {
        privateCloud.availabilityResult = .unavailable(reason: "Requires iOS 27")
        cloud.availabilityResult = .unavailable(reason: "Sign in to use LiftMark cloud")
        let selector = makeSelector()

        let engine = await selector.select(override: .auto, isSignedIn: false)
        XCTAssertEqual(engine.kind, .liftMarkCloud)
        let availability = await engine.availability()
        XCTAssertEqual(availability, .unavailable(reason: "Sign in to use LiftMark cloud"))
    }

    func testAutoOrderMatchesSpec() {
        XCTAssertEqual(PlanEditEngineSelector.autoOrder, [.applePrivateCloud, .liftMarkCloud])
    }
}

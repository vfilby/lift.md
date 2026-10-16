import XCTest
@testable import LiftMark

/// Covers the `FeatureFlag` parent/child hierarchy and developer-facing copy —
/// see spec/services/feature-flags.md "Flag hierarchy".
final class FeatureFlagTests: XCTestCase {

    func testUseBetaApiIsChildOfWorkoutInbox() {
        XCTAssertEqual(FeatureFlag.useBetaApi.parent, .workoutInbox,
                       "useBetaApi must be declared a child of workoutInbox")
    }

    func testWorkoutInboxIsTopLevel() {
        XCTAssertNil(FeatureFlag.workoutInbox.parent)
        XCTAssertTrue(FeatureFlag.topLevelCases.contains(.workoutInbox))
    }

    func testChildIsNotTopLevel() {
        XCTAssertFalse(FeatureFlag.topLevelCases.contains(.useBetaApi),
                       "A child flag must not appear among the top-level roots")
        XCTAssertFalse(FeatureFlag.topLevelCases.contains(.aiPlanEditing))
    }

    func testWorkoutInboxListsChildren() {
        XCTAssertEqual(FeatureFlag.workoutInbox.children, [.useBetaApi, .aiPlanEditing])
    }

    func testChildHasNoChildren() {
        XCTAssertTrue(FeatureFlag.useBetaApi.children.isEmpty)
        XCTAssertTrue(FeatureFlag.aiPlanEditing.children.isEmpty)
    }

    func testBetaApiSummaryDropsLiftmarkBranding() {
        // Developer copy should not surface the legacy infra domain.
        XCTAssertFalse(FeatureFlag.useBetaApi.summary.lowercased().contains("liftmark"),
                       "Beta API summary should not reference the liftmark domain")
    }

    // MARK: - aiPlanEditing (spec/services/ai-plan-editing.md "Gating")

    func testAiPlanEditingIsChildOfWorkoutInboxAndOffByDefault() {
        XCTAssertEqual(FeatureFlag.aiPlanEditing.parent, .workoutInbox)
        XCTAssertFalse(FeatureFlag.aiPlanEditing.defaultValue)
        XCTAssertEqual(FeatureFlag.aiPlanEditing.title, "AI Plan Editing")
        XCTAssertEqual(FeatureFlag.aiPlanEditing.defaultsKey, "feature_flag.aiPlanEditing")
        XCTAssertEqual(FeatureFlag.aiPlanEditing.launchArgument, "--enable-flag=aiPlanEditing")
    }
}

/// `AIEngineOverride` is the one non-boolean developer setting; it lives in
/// `FeatureFlagsStore` next to the flags. See spec/services/feature-flags.md
/// "Developer setting: AI engine override".
@MainActor
final class AIEngineOverrideTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "app.liftmark.flags.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testDefaultsKeyAndCases() {
        XCTAssertEqual(AIEngineOverride.defaultsKey, "feature_flag.aiEngineOverride")
        XCTAssertEqual(AIEngineOverride.allCases, [.auto, .applePrivateCloud, .appleOnDevice, .liftMarkCloud])
        XCTAssertNil(AIEngineOverride.auto.engineKind)
        XCTAssertEqual(AIEngineOverride.applePrivateCloud.engineKind, .applePrivateCloud)
        XCTAssertEqual(AIEngineOverride.appleOnDevice.engineKind, .appleOnDevice)
        XCTAssertEqual(AIEngineOverride.liftMarkCloud.engineKind, .liftMarkCloud)
    }

    func testStoreDefaultsToAuto() {
        let store = FeatureFlagsStore(defaults: defaults, launchArguments: [])
        XCTAssertEqual(store.engineOverride, .auto)
        XCTAssertFalse(store.isAIEngineStubActive)
    }

    func testStorePersistsOverride() {
        let store = FeatureFlagsStore(defaults: defaults, launchArguments: [])
        store.engineOverride = .appleOnDevice
        XCTAssertEqual(defaults.string(forKey: AIEngineOverride.defaultsKey), "appleOnDevice")

        let reloaded = FeatureFlagsStore(defaults: defaults, launchArguments: [])
        XCTAssertEqual(reloaded.engineOverride, .appleOnDevice)
    }

    func testLaunchArgumentOverridesStoredValue() {
        defaults.set("appleOnDevice", forKey: AIEngineOverride.defaultsKey)
        let store = FeatureFlagsStore(defaults: defaults, launchArguments: ["--ai-engine-override=liftMarkCloud"])
        XCTAssertEqual(store.engineOverride, .liftMarkCloud)
    }

    func testUnknownStoredValueFallsBackToAuto() {
        defaults.set("bogus", forKey: AIEngineOverride.defaultsKey)
        let store = FeatureFlagsStore(defaults: defaults, launchArguments: ["--ai-engine-override=nope"])
        XCTAssertEqual(store.engineOverride, .auto)
    }

    func testStubLaunchArgumentIsDetected() {
        let store = FeatureFlagsStore(defaults: defaults, launchArguments: ["--ai-engine-stub"])
        XCTAssertTrue(store.isAIEngineStubActive)
    }
}

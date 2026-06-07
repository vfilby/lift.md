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
    }

    func testWorkoutInboxListsBetaApiAsChild() {
        XCTAssertEqual(FeatureFlag.workoutInbox.children, [.useBetaApi])
    }

    func testChildHasNoChildren() {
        XCTAssertTrue(FeatureFlag.useBetaApi.children.isEmpty)
    }

    func testBetaApiSummaryDropsLiftmarkBranding() {
        // Developer copy should not surface the legacy infra domain.
        XCTAssertFalse(FeatureFlag.useBetaApi.summary.lowercased().contains("liftmark"),
                       "Beta API summary should not reference the liftmark domain")
    }
}

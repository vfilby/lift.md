import XCTest
import SwiftUI
@testable import LiftMark

/// Inbox Start must push Active Workout onto the Plans tab's own stack, the
/// tab the inbox lives on. Routing through the Home tab's stack while it was
/// off screen rendered a blank placeholder (GH #487).
/// See spec/services/workout-inbox.md, "Start navigation".
final class NavigationCoordinatorTests: XCTestCase {

    func testNavigateToActiveWorkoutPushesOntoPlansStack() {
        let nav = NavigationCoordinator()
        nav.selectedTab = .plans

        nav.navigateToActiveWorkout()

        XCTAssertEqual(nav.selectedTab, .plans)
        XCTAssertEqual(nav.plansNavPath.count, 1)
        XCTAssertTrue(nav.homeNavPath.isEmpty, "the Home stack must not be touched")
    }

    func testNavigateToActiveWorkoutReplacesWhateverPlansHadPushed() {
        let nav = NavigationCoordinator()
        nav.plansNavPath.append(AppDestination.workoutDetail(id: "plan-1"))
        nav.plansNavPath.append(AppDestination.gymDetail(id: "gym-1"))

        nav.navigateToActiveWorkout()

        XCTAssertEqual(nav.plansNavPath.count, 1, "Active Workout sits directly on the Plans root")
    }

    func testNavigateToActiveWorkoutLeavesHomeStackAlone() {
        let nav = NavigationCoordinator()
        nav.homeNavPath.append(AppDestination.workoutDetail(id: "plan-1"))

        nav.navigateToActiveWorkout()

        XCTAssertEqual(nav.homeNavPath.count, 1)
        XCTAssertEqual(nav.selectedTab, .plans)
    }

    func testPopToRootOnlyResetsHome() {
        let nav = NavigationCoordinator()
        nav.homeNavPath.append(AppDestination.activeWorkout)
        nav.plansNavPath.append(AppDestination.workoutDetail(id: "plan-1"))

        nav.popToRoot()

        XCTAssertTrue(nav.homeNavPath.isEmpty)
        XCTAssertEqual(nav.plansNavPath.count, 1, "plan detail stays put after a workout summary's Done")
    }
}

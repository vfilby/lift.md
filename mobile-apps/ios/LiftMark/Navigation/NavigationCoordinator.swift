import SwiftUI

/// Coordinates navigation state across the app.
/// Allows deep views (like WorkoutSummaryView) to pop back to the root,
/// and cross-tab navigation (e.g., opening a plan from the Home tab).
@Observable
class NavigationCoordinator {
    var homeNavPath = NavigationPath()
    var selectedTab: AppTab = .home

    /// Set this to navigate to a specific plan in the Plans tab.
    var pendingPlanId: String?

    func popToRoot() {
        homeNavPath = NavigationPath()
    }

    func navigateToPlan(id: String) {
        pendingPlanId = id
        selectedTab = .plans
    }

    /// Navigate directly to the active workout screen. Used after the inbox
    /// "Start" action creates and begins a session, so the user lands in the
    /// live workout rather than the plan's detail screen (GH #210). Routes
    /// through the Home tab, which owns the `.activeWorkout` destination.
    func navigateToActiveWorkout() {
        homeNavPath = NavigationPath()
        homeNavPath.append(AppDestination.activeWorkout)
        selectedTab = .home
    }
}

enum AppTab: Hashable {
    case home
    case plans
    case workouts
    case settings
}

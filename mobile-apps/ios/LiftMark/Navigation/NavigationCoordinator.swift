import SwiftUI

/// Coordinates navigation state across the app.
/// Allows deep views (like WorkoutSummaryView) to pop back to the root,
/// and cross-tab navigation (e.g., opening a plan from the Home tab).
@Observable
class NavigationCoordinator {
    var homeNavPath = NavigationPath()
    /// The Plans tab's stack. Programmatic pushes that originate on the Plans
    /// tab (inbox Start) go here so the destination resolves on the stack
    /// that is actually on screen.
    var plansNavPath = NavigationPath()
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
    /// live workout rather than the plan's detail screen (GH #210).
    ///
    /// Pushes onto the Plans tab's own stack — the tab the inbox lives on —
    /// mirroring plan detail's Start. Pushing onto another tab's stack while
    /// it is off screen (the previous Home-tab route) left SwiftUI's blank
    /// unresolved-destination placeholder with a back button instead of the
    /// workout (GH #487).
    func navigateToActiveWorkout() {
        plansNavPath = NavigationPath()
        plansNavPath.append(AppDestination.activeWorkout)
        selectedTab = .plans
    }
}

enum AppTab: Hashable {
    case home
    case plans
    case workouts
    case settings
}

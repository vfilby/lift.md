import Foundation

/// Developer-facing runtime feature flags. See `spec/services/feature-flags.md`.
///
/// Add a new flag: append a case, give it a `title`, `summary`, and
/// `defaultValue`. The Settings UI auto-renders it. Remove a flag once
/// the feature has shipped on-by-default for a full release cycle.
enum FeatureFlag: String, CaseIterable, Identifiable {
    case workoutInbox
    case useBetaApi

    var id: String { rawValue }

    /// Human-readable label for the Settings row.
    var title: String {
        switch self {
        case .workoutInbox: return "Workout Inbox"
        case .useBetaApi: return "Use Beta API"
        }
    }

    /// One-line description shown under the toggle.
    var summary: String {
        switch self {
        case .workoutInbox:
            return "Pulls workouts pushed to your account (via Claude Code, etc.) into a local inbox on the Plans tab."
        case .useBetaApi:
            return "Route account + sync API calls to the beta environment instead of prod. "
                + "Toggling signs you out — tokens from one env don't work in the other."
        }
    }

    /// Parent flag this one is subordinate to, if any. A child flag only
    /// applies in the context of its parent — it's hidden in Settings until
    /// the parent is enabled, and disabling the parent cascades it off. See
    /// `spec/services/feature-flags.md`.
    var parent: FeatureFlag? {
        switch self {
        case .useBetaApi: return .workoutInbox  // beta API only serves account + sync, which the inbox drives
        case .workoutInbox: return nil
        }
    }

    /// Flags that declare this one as their `parent`.
    var children: [FeatureFlag] {
        FeatureFlag.allCases.filter { $0.parent == self }
    }

    /// Top-level flags (no parent), in declaration order — the roots the
    /// Settings list renders, with each flag's children nested beneath it.
    static var topLevelCases: [FeatureFlag] {
        allCases.filter { $0.parent == nil }
    }

    /// Initial state when the flag has never been touched. Almost always
    /// `false` — flip in code only for features safe for all dev builds.
    var defaultValue: Bool {
        switch self {
        case .workoutInbox: return false
        case .useBetaApi: return false
        }
    }

    /// UserDefaults key. Namespaced so a future migration can sweep
    /// `feature_flag.*` keys cleanly.
    var defaultsKey: String { "feature_flag.\(rawValue)" }

    /// Launch-argument override used by UI tests: `--enable-flag=workoutInbox`.
    var launchArgument: String { "--enable-flag=\(rawValue)" }
}

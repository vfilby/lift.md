import Foundation

/// Developer-facing runtime feature flags. See `spec/services/feature-flags.md`.
///
/// Add a new flag: append a case, give it a `title`, `summary`, and
/// `defaultValue`. The Settings UI auto-renders it. Remove a flag once
/// the feature has shipped on-by-default for a full release cycle.
enum FeatureFlag: String, CaseIterable, Identifiable {
    case workoutInbox

    var id: String { rawValue }

    /// Human-readable label for the Settings row.
    var title: String {
        switch self {
        case .workoutInbox: return "Workout Inbox"
        }
    }

    /// One-line description shown under the toggle.
    var summary: String {
        switch self {
        case .workoutInbox:
            return "Pulls workouts pushed to your account (via Claude Code, etc.) into a local inbox on the Plans tab."
        }
    }

    /// Initial state when the flag has never been touched. Almost always
    /// `false` — flip in code only for features safe for all dev builds.
    var defaultValue: Bool {
        switch self {
        case .workoutInbox: return false
        }
    }

    /// UserDefaults key. Namespaced so a future migration can sweep
    /// `feature_flag.*` keys cleanly.
    var defaultsKey: String { "feature_flag.\(rawValue)" }

    /// Launch-argument override used by UI tests: `--enable-flag=workoutInbox`.
    var launchArgument: String { "--enable-flag=\(rawValue)" }
}

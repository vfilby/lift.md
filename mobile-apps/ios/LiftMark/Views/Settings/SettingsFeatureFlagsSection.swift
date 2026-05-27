import SwiftUI

/// Developer-only section listing every `FeatureFlag` as a toggle. See
/// `spec/services/feature-flags.md`. Renders one row per case in
/// `FeatureFlag.allCases` so adding a flag adds a row automatically.
struct SettingsFeatureFlagsSection: View {
    @Environment(FeatureFlagsStore.self) private var flags

    var body: some View {
        ForEach(FeatureFlag.allCases) { flag in
            FeatureFlagRow(flag: flag)
        }
    }
}

private struct FeatureFlagRow: View {
    @Environment(FeatureFlagsStore.self) private var flags
    @Environment(AuthenticationStore.self) private var authStore
    let flag: FeatureFlag

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { flags.isEnabled(flag) },
                set: { handleToggle(to: $0) }
            )) {
                Text(flag.title)
            }
            Text(flag.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("feature-flag-\(flag.rawValue)")
    }

    /// Per-flag side effects when the toggle flips. Most flags need no
    /// extra action; `useBetaApi` forces a sign-out so env-specific
    /// tokens + caches don't collide with the new environment.
    private func handleToggle(to newValue: Bool) {
        let old = flags.isEnabled(flag)
        flags.set(flag, newValue)
        guard old != newValue else { return }
        switch flag {
        case .useBetaApi:
            Task { await authStore.logout() }
        case .workoutInbox:
            break
        }
    }
}

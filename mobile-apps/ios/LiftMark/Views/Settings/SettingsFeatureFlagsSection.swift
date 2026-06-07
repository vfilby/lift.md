import SwiftUI

/// Developer-only section listing every `FeatureFlag` as a toggle. See
/// `spec/services/feature-flags.md`. Renders one row per case in
/// `FeatureFlag.allCases` so adding a flag adds a row automatically.
struct SettingsFeatureFlagsSection: View {
    @Environment(FeatureFlagsStore.self) private var flags

    var body: some View {
        ForEach(FeatureFlag.topLevelCases) { flag in
            FeatureFlagRow(flag: flag)
            // Child flags only apply in the context of their parent, so they
            // appear nested beneath it and only while the parent is enabled.
            if flags.isEnabled(flag) {
                ForEach(flag.children) { child in
                    FeatureFlagRow(flag: child, isChild: true)
                }
            }
        }
    }
}

private struct FeatureFlagRow: View {
    @Environment(FeatureFlagsStore.self) private var flags
    @Environment(AuthenticationStore.self) private var authStore
    let flag: FeatureFlag
    var isChild = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { flags.isEnabled(flag) },
                set: { handleToggle(to: $0) }
            )) {
                Text(flag.title)
            }
            Text(flag.summary)
                .font(.lmCaption)
                .foregroundStyle(.secondary)
        }
        // Indent nested child flags so the parent relationship reads visually.
        .padding(.leading, isChild ? 20 : 0)
        .accessibilityIdentifier("feature-flag-\(flag.rawValue)")
    }

    /// Per-flag side effects when the toggle flips. Most flags need no
    /// extra action; `useBetaApi` forces a sign-out so env-specific
    /// tokens + caches don't collide with the new environment. Disabling a
    /// parent cascades its children off (running their side effects too) so a
    /// hidden child can't keep silently affecting behavior.
    private func handleToggle(to newValue: Bool) {
        let old = flags.isEnabled(flag)
        flags.set(flag, newValue)
        guard old != newValue else { return }
        applySideEffects(for: flag, enabled: newValue)

        // Cascade: turning a parent off turns off any enabled children.
        if !newValue {
            for child in flag.children where flags.isEnabled(child) {
                flags.set(child, false)
                applySideEffects(for: child, enabled: false)
            }
        }
    }

    private func applySideEffects(for flag: FeatureFlag, enabled: Bool) {
        switch flag {
        case .useBetaApi:
            Task { await authStore.logout() }
        case .workoutInbox:
            break
        }
    }
}

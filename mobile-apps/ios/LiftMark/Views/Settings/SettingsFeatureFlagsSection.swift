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
                    // The AI engine override is the one sanctioned non-boolean
                    // developer setting; it rides beneath its flag while on.
                    if child == .aiPlanEditing, flags.isEnabled(child) {
                        AIEngineOverrideRow()
                    }
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
    /// tokens + caches don't collide with the new environment, and
    /// `aiPlanEditing` resets the engine override. Disabling a parent
    /// cascades its children off (running their side effects too) so a
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
        case .aiPlanEditing:
            if !enabled {
                flags.engineOverride = .auto
            }
        case .workoutInbox:
            break
        }
    }
}

/// `Picker` for `AIEngineOverride`, nested under the `aiPlanEditing` flag.
private struct AIEngineOverrideRow: View {
    @Environment(FeatureFlagsStore.self) private var flags

    var body: some View {
        @Bindable var flags = flags
        VStack(alignment: .leading, spacing: 4) {
            Picker("AI engine", selection: $flags.engineOverride) {
                ForEach(AIEngineOverride.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Text("Force one engine for device testing. "
                 + "Automatic picks Apple Private Cloud Compute, then LiftMark cloud.")
                .font(.lmCaption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 40)
        .accessibilityIdentifier("ai-engine-override-picker")
    }
}

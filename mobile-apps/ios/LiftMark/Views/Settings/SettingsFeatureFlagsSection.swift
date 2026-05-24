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
    let flag: FeatureFlag

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { flags.isEnabled(flag) },
                set: { flags.set(flag, $0) }
            )) {
                Text(flag.title)
            }
            Text(flag.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("feature-flag-\(flag.rawValue)")
    }
}

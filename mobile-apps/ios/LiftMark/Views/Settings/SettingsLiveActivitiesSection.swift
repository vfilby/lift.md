import SwiftUI

struct SettingsLiveActivitiesSection: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Binding var liveActivitiesEnabled: Bool

    var body: some View {
        if let settings = settingsStore.settings {
            VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
                Toggle(isOn: Binding(
                    get: { settings.liveActivitiesEnabled },
                    set: { newValue in
                        var updated = settings
                        updated.liveActivitiesEnabled = newValue
                        settingsStore.updateSettings(updated)
                    }
                )) {
                    Label("Live Activities", systemImage: "rectangle.stack")
                }
                .disabled(!liveActivitiesEnabled)
                .accessibilityIdentifier("switch-live-activities")

                Text(liveActivitiesStatusText)
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .accessibilityIdentifier("live-activities-status-label")

                if !liveActivitiesEnabled {
                    Button {
                        openUserSettings()
                    } label: {
                        Text("Open Settings to enable Live Activities")
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.primary)
                    }
                    .accessibilityIdentifier("live-activities-open-settings")
                }
            }
        }
    }

    private var liveActivitiesStatusText: String {
        if liveActivitiesEnabled {
            return "Enabled"
        } else {
            return "Disabled — go to Settings to enable"
        }
    }

    private func openUserSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

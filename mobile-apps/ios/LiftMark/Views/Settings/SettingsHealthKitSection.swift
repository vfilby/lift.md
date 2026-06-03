import SwiftUI

// MARK: - HealthKit Auth Status

enum HealthKitAuthStatus {
    case notDetermined
    case authorized
    case denied
}

// MARK: - HealthKit Section

struct SettingsHealthKitSection: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Binding var healthKitAuthStatus: HealthKitAuthStatus

    var body: some View {
        if let settings = settingsStore.settings {
            VStack(alignment: .leading, spacing: LiftMarkTheme.spacingXS) {
                Toggle(isOn: Binding(
                    get: { settings.healthKitEnabled },
                    set: { newValue in
                        if newValue {
                            Task {
                                let granted = await HealthKitService.requestAuthorization()
                                if granted {
                                    var updated = settings
                                    updated.healthKitEnabled = true
                                    settingsStore.updateSettings(updated)
                                    healthKitAuthStatus = .authorized
                                } else {
                                    healthKitAuthStatus = .denied
                                }
                            }
                        } else {
                            var updated = settings
                            updated.healthKitEnabled = false
                            settingsStore.updateSettings(updated)
                        }
                    }
                )) {
                    Label("Apple Health", systemImage: "heart")
                }
                .disabled(healthKitAuthStatus == .denied)
                .accessibilityIdentifier("switch-healthkit")

                Text(healthKitStatusText)
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .accessibilityIdentifier("healthkit-status-label")

                if healthKitAuthStatus == .denied {
                    Button {
                        openUserSettings()
                    } label: {
                        Text("Open Health Settings")
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.primary)
                    }
                    .accessibilityIdentifier("healthkit-open-settings")
                }
            }
        }
    }

    // MARK: - HealthKit Status

    private var healthKitStatusText: String {
        if !HealthKitService.isHealthKitAvailable() {
            return "HealthKit is not available on this device"
        }
        switch healthKitAuthStatus {
        case .notDetermined:
            return "Not connected"
        case .authorized:
            return "Connected"
        case .denied:
            return "Access denied — open Settings to enable"
        }
    }

    static func checkHealthKitStatus(settingsStore: SettingsStore) -> HealthKitAuthStatus {
        if !HealthKitService.isHealthKitAvailable() {
            return .notDetermined
        }
        if HealthKitService.isAuthorized() {
            return .authorized
        } else if settingsStore.settings?.healthKitEnabled == true {
            return .denied
        } else {
            return .notDetermined
        }
    }

    // MARK: - Open Settings

    private func openUserSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

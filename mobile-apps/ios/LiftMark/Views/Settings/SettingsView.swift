import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(FeatureFlagsStore.self) private var featureFlags
    @State private var selectedSection: SettingsSection? = .general
    @State private var healthKitAuthStatus: HealthKitAuthStatus = .notDetermined
    @State private var liveActivitiesEnabled = false
    /// Hosts the `LoginView` sheet on this stably-mounted view rather than on
    /// `SettingsAccountSection`'s transparent, auth-swapping `Group`, so the
    /// first "Sign in" tap presents reliably instead of being dropped by a
    /// launch-settling re-render (GH #279). `SettingsAccountSection` receives
    /// this as a binding and flips it from its Sign in button.
    @State private var showingLogin = false

    var body: some View {
        Group {
            if let settings = settingsStore.settings {
                AdaptiveSplitView {
                    // iPad sidebar - navigation list
                    List {
                        ForEach(SettingsSection.visibleSections(settings: settings, forIPad: true)) { section in
                            Button {
                                selectedSection = section
                            } label: {
                                SettingsNavRow(section: section, isSelected: selectedSection == section)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        }
                    }
                    .listStyle(.plain)
                } detail: {
                    // iPad detail - section content
                    if let selectedSection {
                        iPadDetailContent(for: selectedSection, settings: settings)
                    } else {
                        ContentUnavailableView(
                            "Select a Category", systemImage: "gear",
                            description: Text("Choose a settings category from the sidebar."))
                    }
                } compact: {
                    iPhoneLayout(settings: settings)
                }
            } else {
                ProgressView()
                    .accessibilityIdentifier("settings-loading")
            }
        }
        .accessibilityIdentifier("settings-screen")
        .navigationTitle("Settings")
        // Hosted here — not on SettingsAccountSection — so the presenter is
        // stably mounted across the auth-state re-renders that otherwise drop
        // the first-tap presentation (GH #279).
        .sheet(isPresented: $showingLogin) {
            LoginView()
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onAppear {
            healthKitAuthStatus = SettingsHealthKitSection.checkHealthKitStatus(settingsStore: settingsStore)
            liveActivitiesEnabled = LiveActivityService.shared.isAvailable()
        }
        .navigationDestination(for: AppDestination.self) { destination in
            switch destination {
            case .workoutSettings:
                WorkoutSettingsView()
            case .gymDetail(let id):
                GymDetailView(gymId: id)
            case .syncSettings:
                SyncSettingsView()
            case .debugLogs:
                DebugLogsView()
            default:
                EmptyView()
            }
        }
    }

    // MARK: - iPad Detail Content

    @ViewBuilder
    private func iPadDetailContent(for section: SettingsSection, settings: UserSettings) -> some View {
        switch section {
        case .general:
            List {
                // Account is gated on the workout-inbox flag for now —
                // sign-in is currently only useful for the inbox. When
                // another auth-requiring feature ships (billing, etc.),
                // shift this gate to an `anyAuthFeatureEnabled` predicate.
                if featureFlags.isEnabled(.workoutInbox) {
                    Section("Account") {
                        SettingsAccountSection(showingLogin: $showingLogin)
                    }
                }
                Section("Appearance") {
                    AppearancePicker(selection: appearanceBinding(settings: settings))
                        .accessibilityIdentifier("picker-theme")
                }
                Section("iCloud Sync") {
                    syncNavigationLink
                }
                Section("Health & Activities") {
                    SettingsHealthKitSection(healthKitAuthStatus: $healthKitAuthStatus)
                    SettingsLiveActivitiesSection(liveActivitiesEnabled: $liveActivitiesEnabled)
                }
            }
        case .appearance:
            List {
                Section(section.rawValue) {
                    AppearancePicker(selection: appearanceBinding(settings: settings))
                        .accessibilityIdentifier("picker-theme")
                }
            }
        case .workout:
            WorkoutSettingsView()
        case .gyms:
            List {
                Section(section.rawValue) {
                    SettingsGymSection()
                }
            }
        case .integrations:
            List {
                Section("iCloud Sync") {
                    syncNavigationLink
                }
                Section("Health & Activities") {
                    SettingsHealthKitSection(healthKitAuthStatus: $healthKitAuthStatus)
                    SettingsLiveActivitiesSection(liveActivitiesEnabled: $liveActivitiesEnabled)
                }
            }
        case .ai:
            List {
                Section(section.rawValue) {
                    SettingsAISection()
                }
            }
        case .data:
            List {
                Section(section.rawValue) {
                    SettingsDataSection()
                }
            }
        case .privacy:
            List {
                Section(section.rawValue) {
                    SettingsPrivacySection()
                }
            }
        case .developer:
            List {
                Section(section.rawValue) {
                    SettingsDeveloperSection()
                }
                Section("Feature Flags") {
                    SettingsFeatureFlagsSection()
                }
            }
        case .about:
            List {
                Section(section.rawValue) {
                    SettingsAboutSection()
                }
                Section {
                    Text("lift.md")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .font(.lmFootnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    // MARK: - iPhone Layout

    @ViewBuilder
    private func iPhoneLayout(settings: UserSettings) -> some View {
        List {
            if featureFlags.isEnabled(.workoutInbox) {
                Section("Account") {
                    SettingsAccountSection(showingLogin: $showingLogin)
                }
            }

            Section("Appearance") {
                AppearancePicker(selection: appearanceBinding(settings: settings))
                    .accessibilityIdentifier("picker-theme")
            }

            Section("Workout") {
                NavigationLink(value: AppDestination.workoutSettings) {
                    Text("Workout Settings")
                }
                .accessibilityIdentifier("workout-settings-button")
            }

            Section("Gym") {
                SettingsGymSection()
            }

            Section("Integrations") {
                syncNavigationLink
                SettingsHealthKitSection(healthKitAuthStatus: $healthKitAuthStatus)
                SettingsLiveActivitiesSection(liveActivitiesEnabled: $liveActivitiesEnabled)
            }

            Section("AI Assistance") {
                SettingsAISection()
            }

            Section("Data Management") {
                SettingsDataSection()
            }

            Section("Privacy") {
                SettingsPrivacySection()
            }

            // Developer + Feature Flags visibility follows the easter-egg
            // toggle in every build configuration — see spec/screens/settings.md.
            if settings.developerModeEnabled {
                Section("Developer") {
                    SettingsDeveloperSection()
                }
                Section("Feature Flags") {
                    SettingsFeatureFlagsSection()
                }
            }

            Section("About") {
                SettingsAboutSection()
            }

            Section {
                Text("lift.md")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .font(.lmFootnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
    }

    // MARK: - Shared Helpers

    private var syncNavigationLink: some View {
        NavigationLink(value: AppDestination.syncSettings) {
            Label("iCloud Sync", systemImage: "icloud")
        }
        .accessibilityIdentifier("sync-settings-button")
    }

    private func appearanceBinding(settings: UserSettings) -> Binding<AppTheme> {
        Binding(
            get: { settings.theme },
            set: { newTheme in
                var updated = settings
                updated.theme = newTheme
                settingsStore.updateSettings(updated)
            }
        )
    }
}

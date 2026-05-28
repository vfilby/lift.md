import SwiftUI

struct ContentView: View {
    @Binding var pendingImportContent: String?
    @Environment(SettingsStore.self) private var settingsStore
    @State private var showPendingImport = false
    @State private var showOnboarding = false
    @State private var navCoordinator = NavigationCoordinator()

    private var colorScheme: ColorScheme? {
        switch settingsStore.settings?.theme ?? .auto {
        case .light: return .light
        case .dark: return .dark
        case .auto: return nil
        }
    }

    var body: some View {
        MigratorBridgeAlertContainer {
            mainContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    AuthSyncBannerView()
                }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        TabView(selection: Bindable(navCoordinator).selectedTab) {
            NavigationStack(path: $navCoordinator.homeNavPath) {
                HomeView()
            }
            .environment(navCoordinator)
            .tabItem {
                Label("LiftMark", systemImage: "house")
            }
            .tag(AppTab.home)
            .accessibilityIdentifier("tab-home")

            NavigationStack {
                WorkoutsView()
            }
            .environment(navCoordinator)
            .tabItem {
                Label("Plans", systemImage: "doc.on.clipboard")
            }
            .tag(AppTab.plans)
            .accessibilityIdentifier("tab-workouts")

            NavigationStack {
                HistoryView()
            }
            .tabItem {
                Label("Workouts", systemImage: "dumbbell")
            }
            .tag(AppTab.workouts)
            .accessibilityIdentifier("tab-history")

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(AppTab.settings)
            .accessibilityIdentifier("tab-settings")
        }
        .tint(LiftMarkTheme.tabIconSelected)
        .preferredColorScheme(colorScheme)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                guard var updated = settingsStore.settings else { return }
                updated.hasAcceptedDisclaimer = true
                settingsStore.updateSettings(updated)
                showOnboarding = false
            }
        }
        .onAppear {
            updateOnboardingState()
        }
        .task {
            // Check for pending import content set during launch (e.g., via
            // --import-content argument). Using task instead of onAppear
            // ensures the view hierarchy is fully set up before presenting
            // the sheet. onChange won't fire for the initial @State value.
            if pendingImportContent != nil {
                showPendingImport = true
            }
        }
        .onChange(of: settingsStore.settings?.hasAcceptedDisclaimer) {
            updateOnboardingState()
        }
        .sheet(isPresented: $showPendingImport) {
            ImportView(initialContent: pendingImportContent ?? "")
                .onDisappear {
                    pendingImportContent = nil
                }
        }
        .onChange(of: pendingImportContent) {
            if pendingImportContent != nil {
                showPendingImport = true
            }
        }
    }

    private func updateOnboardingState() {
        let needsOnboarding = settingsStore.settings != nil && !(settingsStore.settings?.hasAcceptedDisclaimer ?? false)
        if needsOnboarding != showOnboarding {
            showOnboarding = needsOnboarding
        }
    }
}

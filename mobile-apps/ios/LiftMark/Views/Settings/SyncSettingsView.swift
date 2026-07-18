import SwiftUI

struct SyncSettingsView: View {
    @State private var accountStatus: CloudKitAccountStatus = .couldNotDetermine
    @State private var isCheckingStatus = false
    @State private var isSyncing = false
    @State private var syncEnabled: Bool = true
    @State private var lastSyncDate: Date?
    @State private var lastSyncStats: LastSyncStats?

    var body: some View {
        List {
            // iCloud Status Section
            Section {
                HStack(spacing: LiftMarkTheme.spacingSM) {
                    Circle()
                        .fill(statusBadgeColor)
                        .frame(width: 12, height: 12)
                        .accessibilityIdentifier("sync-status-badge")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusLabel)
                            .font(.lmSubheadline.weight(.medium))
                            .accessibilityIdentifier("sync-status-label")

                        Text(statusDescription)
                            .font(.lmCaption)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            .accessibilityIdentifier("sync-status-description")
                    }
                }

                Button {
                    Task {
                        isCheckingStatus = true
                        accountStatus = await CKSyncEngineManager.shared.getAccountStatus()
                        isCheckingStatus = false
                    }
                } label: {
                    HStack {
                        Label("Check Status", systemImage: "arrow.clockwise")
                        if isCheckingStatus {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isCheckingStatus)
                .accessibilityIdentifier("sync-check-status")
            } header: {
                Text("iCloud Status")
            }

            // Sync Controls Section (only when available)
            if accountStatus == .available {
                Section("Sync Controls") {
                    Toggle(isOn: $syncEnabled) {
                        Label("Enable Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .onChange(of: syncEnabled) { _, newValue in
                        CKSyncEngineManager.shared.setSyncEnabled(newValue)
                    }
                    .accessibilityIdentifier("switch-enable-sync")

                    // Last synced date (absolute)
                    HStack {
                        Text("Last Synced")
                        Spacer()
                        Text(lastSyncDateLabel)
                            .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    }
                    .accessibilityIdentifier("sync-last-synced")

                    // Per-sync record counts (hidden until first sync)
                    if let stats = lastSyncStats {
                        HStack {
                            Text("Uploaded")
                            Spacer()
                            Text("\(stats.uploaded) records")
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        }
                        .accessibilityIdentifier("sync-records-uploaded")

                        HStack {
                            Text("Downloaded")
                            Spacer()
                            Text("\(stats.downloaded) records")
                                .foregroundStyle(LiftMarkTheme.secondaryLabel)
                        }
                        .accessibilityIdentifier("sync-records-downloaded")

                        if stats.conflicts > 0 {
                            HStack {
                                Text("Conflicts Resolved")
                                Spacer()
                                Text("\(stats.conflicts)")
                                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                            }
                            .accessibilityIdentifier("sync-records-conflicts")
                        }
                    }

                    Button {
                        isSyncing = true
                        CKSyncEngineManager.shared.fetchChanges(manual: true)
                        // The sync engine works asynchronously; the .syncCompleted
                        // notification will refresh the UI when it finishes.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            isSyncing = false
                        }
                    } label: {
                        HStack {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                            if isSyncing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSyncing || !syncEnabled)
                    .accessibilityIdentifier("sync-now-button")
                }
            }

            // Sync Info Section (always visible)
            Section {
                Text("iCloud Sync keeps your workout plans, session history, and settings "
                    + "in sync across all your devices signed into the same iCloud account.")
                    .font(.lmSubheadline)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .accessibilityIdentifier("sync-info-text")

                if accountStatus != .available {
                    Text("To use iCloud Sync, sign in to iCloud in your device's Settings app.")
                        .font(.lmSubheadline)
                        .foregroundStyle(LiftMarkTheme.warning)
                }
            } header: {
                Text("About iCloud Sync")
            }
        }
        .accessibilityIdentifier("sync-settings-screen")
        .navigationTitle("iCloud Sync")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            refreshSyncState()
            Task {
                isCheckingStatus = true
                accountStatus = await CKSyncEngineManager.shared.getAccountStatus()
                isCheckingStatus = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncCompleted)) { _ in
            refreshSyncState()
        }
    }

    // MARK: - Helpers

    private func refreshSyncState() {
        syncEnabled = CKSyncEngineManager.shared.getSyncEnabled()
        lastSyncDate = CKSyncEngineManager.shared.getLastSyncDate()
        lastSyncStats = CKSyncEngineManager.shared.getLastSyncStats()
    }

    // MARK: - Status Display

    private var statusBadgeColor: Color {
        switch accountStatus {
        case .available: return LiftMarkTheme.success
        case .noAccount: return .orange
        case .restricted: return LiftMarkTheme.destructive
        case .couldNotDetermine: return .gray
        case .error: return LiftMarkTheme.destructive
        }
    }

    private var statusLabel: String {
        switch accountStatus {
        case .available: return "iCloud Available"
        case .noAccount: return "No iCloud Account"
        case .restricted: return "Restricted"
        case .couldNotDetermine: return "Unknown"
        case .error: return "Error"
        }
    }

    private var lastSyncDateLabel: String {
        guard let lastSyncDate else { return "Not yet synced" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: lastSyncDate)
    }

    private var statusDescription: String {
        switch accountStatus {
        case .available:
            return "Your iCloud account is connected and ready for sync."
        case .noAccount:
            return "Sign in to iCloud in your device Settings to enable sync."
        case .restricted:
            return "iCloud access is restricted on this device (e.g., parental controls)."
        case .couldNotDetermine:
            return "Could not determine iCloud status. Try again later."
        case .error:
            return "An error occurred checking iCloud status."
        }
    }
}

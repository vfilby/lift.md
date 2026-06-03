import SwiftUI

/// Root container that surfaces persisted migrator-bridge failures on launch.
///
/// Reads `MigratorBridgeFailure.loadPersisted()` on appear and either:
/// - Renders `MigratorBridgeStallView` in place of `content` for boot-blocking cases
///   (disk full, integrity failed, future-version DB). The app cannot proceed; the
///   user resolves the underlying cause and relaunches.
/// - Presents an informational alert over `content` for recoverable cases. Dismissing
///   clears the persisted state so next launch is clean.
///
/// Bridged to the bridge's UserDefaults contract — see `MigratorBridgeFailure` and
/// `spec/services/migrator.md` §5.2.
struct MigratorBridgeAlertContainer<Content: View>: View {
    private let content: () -> Content
    @State private var failure: MigratorBridgeFailure?
    @State private var context: MigratorBridgeFailureContext
    @State private var exportFile: ExportFile? = nil

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
        // Load synchronously at init so boot-blocking failures suppress the main UI
        // on first render — no flash of normal content before the stall appears.
        let record = MigratorBridgeFailure.loadPersisted()
        self._failure = State(initialValue: record?.failure)
        self._context = State(initialValue: record?.context ?? .init())
    }

    var body: some View {
        Group {
            if let failure, failure.isBootBlocking {
                MigratorBridgeStallView(
                    failure: failure,
                    context: context,
                    onExportForSupport: { exportFile = resolveSupportExportFile() }
                )
            } else {
                content()
                    .alert(
                        failure?.alertTitle ?? "",
                        isPresented: alertBinding,
                        presenting: failure
                    ) { _ in
                        Button("OK", role: .cancel) { dismissAlert() }
                    } message: { failure in
                        Text(failure.alertMessage(context: context))
                    }
            }
        }
        .shareSheet(item: $exportFile)
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { failure != nil && !(failure?.isBootBlocking ?? false) },
            set: { presented in
                if !presented { dismissAlert() }
            }
        )
    }

    private func dismissAlert() {
        MigratorBridgeFailure.clearPersisted()
        failure = nil
    }

    private func resolveSupportExportFile() -> ExportFile? {
        guard let url = DatabaseManager.liveDatabaseURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return ExportFile(url: url)
    }
}

/// Full-screen stall shown when the bridge can't proceed. Offers a "share DB for
/// support" action for the integrity-failure case (spec §5.2 3.b); otherwise the
/// user must resolve the underlying condition (free storage, update the app) and
/// relaunch.
struct MigratorBridgeStallView: View {
    let failure: MigratorBridgeFailure
    let context: MigratorBridgeFailureContext
    var onExportForSupport: () -> Void

    var body: some View {
        ZStack {
            LiftMarkTheme.background.ignoresSafeArea()
            VStack(spacing: LiftMarkTheme.spacingLG) {
                Image(systemName: iconName)
                    .font(.system(size: 56))
                    .foregroundStyle(LiftMarkTheme.destructive)
                    .accessibilityHidden(true)

                Text(failure.alertTitle)
                    .font(.lmTitle2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(failure.alertMessage(context: context))
                    .font(.lmBody)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if failure.offersSupportExport {
                    Button(action: onExportForSupport) {
                        Label("Export Database for Support", systemImage: "square.and.arrow.up")
                            .font(.lmBody.weight(.semibold))
                            .padding(.horizontal, LiftMarkTheme.spacingMD)
                            .padding(.vertical, LiftMarkTheme.spacingSM)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LiftMarkTheme.primary)
                    .accessibilityIdentifier("migrator-stall-export-button")
                }
            }
            .padding(LiftMarkTheme.spacingXL)
            .frame(maxWidth: 480)
        }
        .accessibilityIdentifier("migrator-stall")
    }

    private var iconName: String {
        switch failure {
        case .diskFull: return "externaldrive.badge.exclamationmark"
        case .integrityFailed: return "exclamationmark.triangle"
        case .futureVersion: return "arrow.up.circle"
        case .backupFailed, .bridgeWriteFailed, .postBridgeMigrationFailed, .fkViolation:
            return "exclamationmark.triangle"
        }
    }
}

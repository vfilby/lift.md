import SwiftUI

/// Slim, unobtrusive "Syncing…" bar shown while a background CloudKit sync is in flight.
/// Driven by ``SyncStatusStore`` so the user knows more records may still be arriving and
/// doesn't have to keep pulling to refresh. Renders nothing when idle.
struct SyncStatusBar: View {
    let isSyncing: Bool

    var body: some View {
        if isSyncing {
            HStack(spacing: LiftMarkTheme.spacingSM) {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing…")
                    .font(.lmCaption)
                    .foregroundStyle(LiftMarkTheme.secondaryLabel)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, LiftMarkTheme.spacingXS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LiftMarkTheme.secondaryBackground)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("sync-status-bar")
        }
    }
}

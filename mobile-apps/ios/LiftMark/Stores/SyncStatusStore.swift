import Foundation

/// Observable, app-wide "is a background sync running right now?" state.
///
/// `CKSyncEngineManager` posts `.syncActivityDidChange` when a fetch/send cycle starts
/// and ends; this store mirrors that into an `@Observable` flag the UI can show as a
/// status indicator. Before this, the only sync-progress state lived locally inside the
/// Settings screen, so list views had no way to tell the user that records were still
/// arriving — forcing repeated manual pull-to-refresh.
@MainActor
@Observable
final class SyncStatusStore {
    /// True while at least one CloudKit fetch or send cycle is in flight.
    private(set) var isSyncing = false

    // nonisolated(unsafe) so the nonisolated deinit can remove the observer. The token is
    // only written once in init and read once in deinit, so there is no concurrent access.
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .syncActivityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let active = note.userInfo?["isActive"] as? Bool ?? false
            // Delivered on the main queue, so we are already on the main actor.
            MainActor.assumeIsolated {
                self?.isSyncing = active
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

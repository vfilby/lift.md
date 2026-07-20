import CloudKit
import GRDB

// MARK: - Notification

extension Notification.Name {
    /// Posted once at the end of a full fetch cycle (`didFetchChanges`), after sync stats
    /// are finalized. userInfo: `["changedRecordTypes": Set<String>]`.
    static let syncCompleted = Notification.Name("syncCompleted")

    /// Posted after each incoming batch of records is merged, so list views update live
    /// during a long multi-batch sync instead of only at the very end.
    /// userInfo: `["changedRecordTypes": Set<String>]`.
    static let syncRecordsMerged = Notification.Name("syncRecordsMerged")

    /// Posted when a sync fetch/send cycle starts or stops. userInfo: `["isActive": Bool]`.
    static let syncActivityDidChange = Notification.Name("syncActivityDidChange")
}

// MARK: - CloudKit Account Status

enum CloudKitAccountStatus: String {
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case error
}

// MARK: - CKSyncEngineManager

/// Core state and lifecycle for the CloudKit sync engine.
///
/// The implementation is split across three files to keep each cohesive:
/// - This file: stored state, lifecycle, account status, fetch triggers, and the
///   sync-stats/activity bookkeeping.
/// - `CKSyncEngineManager+Recovery.swift`: one-time recovery, zone management, full-upload
///   scheduling, and engine-state persistence.
/// - `CKSyncEngineManager+SyncEvents.swift`: the `CKSyncEngineDelegate` conformance and
///   fetched/sent/account event handling.
///
/// Stored properties without an access modifier are deliberately `internal` (not `private`)
/// so the same-type extension files above can reach them; they are not intended for use
/// outside the sync engine and its tests.
final class CKSyncEngineManager: @unchecked Sendable {
    static let shared = CKSyncEngineManager()

    let container = CKContainer(identifier: "iCloud.com.eff3.liftmark.v2")
    var engine: CKSyncEngine?
    let mapper = CKRecordMapper()
    let zoneID = CKRecordZone.ID(zoneName: "LiftMarkData", ownerName: CKCurrentUserDefaultName)

    /// Track record types for pending changes (CKRecord.ID doesn't carry type)
    var pendingRecordTypes: [String: String] = [:] // recordID.recordName -> recordType
    let lock = NSLock()

    var currentSnapshot: SessionSnapshot?

    // Sync stats accumulated during a fetch/send cycle
    var syncDownloaded = 0
    var syncUploaded = 0
    var syncConflicts = 0
    var syncChangedRecordTypes: Set<String> = []

    // Rate limiting for automatic fetches
    private static let minimumFetchInterval: TimeInterval = 30
    private var lastSyncTime: Date?

    /// Number of in-flight fetch/send cycles. Incremented on willFetch/willSend, decremented
    /// on didFetch/didSend. A counter (not a bool) keeps "syncing" true while an overlapping
    /// fetch and send are both active, and only flips to idle when the last one finishes.
    private var activeSyncOps = 0

    // Composed helpers
    let metadataStore = CKSyncMetadataStore()
    lazy var conflictResolver = CKSyncConflictResolver(mapper: mapper)

    /// Whether we've already triggered zone creation + full upload in this session.
    var hasScheduledInitialUpload = false

    /// Set during a recovery reset; the deferred local re-upload runs after the first fetch
    /// completes (so `ck_record_metadata` is repopulated with real tags first).
    var pendingRecoveryUpload = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        guard engine == nil else {
            lock.unlock()
            return
        }

        // One-time recovery (must run before loadPersistedState): on a version bump this
        // clears the engine's persisted state + system-fields cache so the engine restarts
        // fresh and re-fetches every record before re-uploading. No data rows are touched.
        prepareRecoveryIfNeeded()

        let serialization = loadPersistedState()
        let isFirstStart = serialization == nil

        let config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        engine = CKSyncEngine(config)
        lock.unlock()

        Logger.shared.info(.sync, "CKSyncEngine started (firstStart=\(isFirstStart))")

        // Don't create zone here — the engine fires .accountChange immediately,
        // which handles zone creation. Doing it here too causes a race.
        // The deferred recovery re-upload (if any) runs from `.didFetchChanges`.
    }

    func stop() {
        lock.lock()
        engine = nil
        lock.unlock()
        Logger.shared.info(.sync, "CKSyncEngine stopped")
    }

    // MARK: - Account Status

    func getAccountStatus() async -> CloudKitAccountStatus {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                return .available
            case .noAccount:
                return .noAccount
            case .restricted:
                return .restricted
            case .couldNotDetermine:
                return .couldNotDetermine
            case .temporarilyUnavailable:
                return .couldNotDetermine
            @unknown default:
                return .couldNotDetermine
            }
        } catch {
            Logger.shared.error(.sync, "Failed to get CloudKit account status", error: error)

            let errorMessage = error.localizedDescription
            if errorMessage.contains("simulator") || errorMessage.contains("development") {
                return .noAccount
            }
            if errorMessage.contains("restricted") {
                return .restricted
            }

            return .couldNotDetermine
        }
    }

    // MARK: - Sync Metadata (delegated)

    func getLastSyncDate() -> Date? { metadataStore.getLastSyncDate() }
    func getLastSyncStats() -> LastSyncStats? { metadataStore.getLastSyncStats() }
    func getSyncEnabled() -> Bool { metadataStore.getSyncEnabled() }
    func setSyncEnabled(_ enabled: Bool) { metadataStore.setSyncEnabled(enabled) }

    // MARK: - Fetch

    /// Fetch remote changes. Automatic calls are rate-limited; pass `manual: true` to bypass.
    func fetchChanges(manual: Bool = false) {
        if !manual {
            lock.lock()
            let lastSync = lastSyncTime
            lock.unlock()
            if let lastSync,
               Date().timeIntervalSince(lastSync) < Self.minimumFetchInterval {
                Logger.shared.debug(
                    .sync,
                    "[sync-engine] Skipping automatic fetch — last sync was " +
                        "\(Int(Date().timeIntervalSince(lastSync)))s ago (minimum \(Int(Self.minimumFetchInterval))s)"
                )
                return
            }
        }
        lock.lock()
        let currentEngine = engine
        lock.unlock()
        Task {
            try? await currentEngine?.fetchChanges()
        }
    }

    // MARK: - Public API for Repositories

    static func notifySave(recordType: String, recordID: String) {
        let manager = CKSyncEngineManager.shared
        manager.lock.lock()
        manager.pendingRecordTypes[recordID] = recordType
        let engine = manager.engine
        manager.lock.unlock()
        let ckRecordID = CKRecord.ID(recordName: recordID, zoneID: manager.zoneID)
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(ckRecordID)])
    }

    static func notifyDelete(recordType: String, recordID: String) {
        let manager = CKSyncEngineManager.shared
        manager.lock.lock()
        manager.pendingRecordTypes.removeValue(forKey: recordID)
        let engine = manager.engine
        manager.lock.unlock()
        let ckRecordID = CKRecord.ID(recordName: recordID, zoneID: manager.zoneID)
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(ckRecordID)])
    }

    // MARK: - Sync Stats Helpers (synchronous, safe to call from async context)

    /// Mark a fetch/send cycle as started. Posts `.syncActivityDidChange(isActive: true)`
    /// only on the 0→1 transition.
    func beginSyncActivity() {
        lock.lock()
        activeSyncOps += 1
        let becameActive = activeSyncOps == 1
        lock.unlock()
        if becameActive { postSyncActivity(true) }
    }

    /// Mark a fetch/send cycle as finished. Posts `.syncActivityDidChange(isActive: false)`
    /// only on the 1→0 transition.
    func endSyncActivity() {
        lock.lock()
        if activeSyncOps > 0 { activeSyncOps -= 1 }
        let becameIdle = activeSyncOps == 0
        lock.unlock()
        if becameIdle { postSyncActivity(false) }
    }

    private func postSyncActivity(_ active: Bool) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .syncActivityDidChange,
                object: nil,
                userInfo: ["isActive": active]
            )
        }
    }

    func resetSyncStats() {
        lock.lock()
        syncDownloaded = 0
        syncUploaded = 0
        syncConflicts = 0
        syncChangedRecordTypes = []
        lock.unlock()
    }

    func collectSyncStats() -> (stats: LastSyncStats, changedRecordTypes: Set<String>) {
        lock.lock()
        let stats = LastSyncStats(uploaded: syncUploaded, downloaded: syncDownloaded, conflicts: syncConflicts)
        let changed = syncChangedRecordTypes
        lastSyncTime = Date()
        lock.unlock()
        return (stats, changed)
    }
}

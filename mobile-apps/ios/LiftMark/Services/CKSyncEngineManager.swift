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

final class CKSyncEngineManager: @unchecked Sendable {
    static let shared = CKSyncEngineManager()

    private let container = CKContainer(identifier: "iCloud.com.eff3.liftmark.v2")
    private var engine: CKSyncEngine?
    private let mapper = CKRecordMapper()
    let zoneID = CKRecordZone.ID(zoneName: "LiftMarkData", ownerName: CKCurrentUserDefaultName)

    /// Track record types for pending changes (CKRecord.ID doesn't carry type)
    private var pendingRecordTypes: [String: String] = [:] // recordID.recordName -> recordType
    private let lock = NSLock()

    private var currentSnapshot: SessionSnapshot?

    // Sync stats accumulated during a fetch/send cycle
    private var syncDownloaded = 0
    private var syncUploaded = 0
    private var syncConflicts = 0
    private var syncChangedRecordTypes: Set<String> = []

    // Rate limiting for automatic fetches
    private static let minimumFetchInterval: TimeInterval = 30
    private var lastSyncTime: Date?

    /// Number of in-flight fetch/send cycles. Incremented on willFetch/willSend, decremented
    /// on didFetch/didSend. A counter (not a bool) keeps "syncing" true while an overlapping
    /// fetch and send are both active, and only flips to idle when the last one finishes.
    private var activeSyncOps = 0

    // Composed helpers
    private let metadataStore = CKSyncMetadataStore()
    private lazy var conflictResolver = CKSyncConflictResolver(mapper: mapper)

    private init() {}

    // MARK: - Lifecycle

    /// Whether we've already triggered zone creation + full upload in this session.
    private var hasScheduledInitialUpload = false

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

    // MARK: - Zone Management

    /// One-time recovery key. Bump the value to force a full re-upload on next launch.
    private static let fullUploadVersion = "sync.fullUploadVersion"
    /// v5: heal the SetMeasurement conflict loop. Earlier builds uploaded records with no
    /// change tag (CKRecord built fresh every time), so every update conflicted forever and
    /// the pending queue jammed (~8.6k deep), starving completed-workout uploads. v5 resets
    /// the engine's pending state + system-fields cache and re-fetches BEFORE re-uploading,
    /// so the re-upload carries authoritative tags. See spec/services/cloudkit-sync.md.
    private static let currentFullUploadVersion = 5

    /// Set during a recovery reset; the deferred local re-upload runs after the first fetch
    /// completes (so `ck_record_metadata` is repopulated with real tags first).
    private var pendingRecoveryUpload = false

    /// One-time recovery: if the stored full-upload version is behind, reset the engine's
    /// pending state + system-fields cache so the next sync does a clean fetch-then-upload.
    /// MUST run before `loadPersistedState()` so the engine starts from a fresh (nil) state
    /// and re-fetches every server record (repopulating authoritative change tags via
    /// `mergeIncoming`). Local DB rows are never touched — no data loss. The version is NOT
    /// bumped here; it's bumped only after the deferred upload is scheduled in
    /// `.didFetchChanges`, so an app kill mid-recovery simply re-runs it (idempotent).
    private func prepareRecoveryIfNeeded() {
        let current = UserDefaults.standard.integer(forKey: Self.fullUploadVersion)
        guard current < Self.currentFullUploadVersion else { return }
        Logger.shared.info(
            .sync,
            "[sync-engine] Recovery v\(Self.currentFullUploadVersion): " +
                "resetting engine state + system-fields cache (was v\(current))"
        )
        CrashReporter.shared.addBreadcrumb("sync.recovery.v5.begin", category: .sync,
                                           metadata: ["fromVersion": "\(current)"])
        clearSyncEngineState()
        mapper.metadataStore.clearAll()
        pendingRecoveryUpload = true
    }

    /// Sync read of the recovery flag — safe to call from `async` contexts (the lock is
    /// taken inside this synchronous function, not directly in the async scope).
    private func isRecoveryUploadPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingRecoveryUpload
    }

    /// After the first post-recovery fetch completes, re-upload local rows (now with correct
    /// tags) and mark recovery done. Called from `.didFetchChanges`.
    private func completeRecoveryUploadIfNeeded() {
        lock.lock()
        let shouldRun = pendingRecoveryUpload
        pendingRecoveryUpload = false
        lock.unlock()
        guard shouldRun else { return }
        Logger.shared.info(
            .sync,
            "[sync-engine] Recovery v\(Self.currentFullUploadVersion): " +
                "fetch complete, scheduling clean re-upload of local records"
        )
        scheduleFullUpload()
        UserDefaults.standard.set(Self.currentFullUploadVersion, forKey: Self.fullUploadVersion)
        CrashReporter.shared.addBreadcrumb("sync.recovery.v5.end", category: .sync)
    }

    /// Delete the persisted CKSyncEngine state so the engine restarts with a fresh change
    /// token (forcing a full re-fetch). Does not touch any data tables.
    private func clearSyncEngineState() {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM sync_engine_state")
            }
        } catch {
            Logger.shared.error(.sync, "[sync-engine] Failed to clear sync engine state for recovery", error: error)
            CrashReporter.shared.captureError(error, category: .sync, metadata: ["tag": "recovery-state-clear-failed"])
        }
    }

    /// Classifies a CKError code from `privateCloudDatabase.save(zone)` as non-fatal.
    /// - `zoneNotFound` / `partialFailure`: zone already exists on retry.
    /// - `accountTemporarilyUnavailable`: transient iCloud account state; retry on CKAccountChanged.
    static func isNonFatalZoneCreateError(_ code: CKError.Code?) -> Bool {
        switch code {
        case .zoneNotFound, .partialFailure, .accountTemporarilyUnavailable:
            return true
        default:
            return false
        }
    }

    private func createZoneAndScheduleFullUpload() async {
        Logger.shared.info(.sync, "[sync-engine] Creating zone \(zoneID.zoneName)...")

        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await container.privateCloudDatabase.save(zone)
            Logger.shared.info(.sync, "[sync-engine] Created record zone: \(zoneID.zoneName)")
        } catch {
            let ckError = error as? CKError
            if Self.isNonFatalZoneCreateError(ckError?.code) {
                Logger.shared.info(
                    .sync,
                    "[sync-engine] Zone create non-fatal (\(ckError?.code.rawValue.description ?? "?")): " +
                        "\(error.localizedDescription)"
                )
            } else {
                Logger.shared.error(.sync, "[sync-engine] Failed to create zone: \(error)")
                var metadata: [String: String] = ["zoneName": zoneID.zoneName, "tag": "zone-create-failed"]
                if let ckError {
                    metadata["errorCode"] = "\(ckError.code.rawValue)"
                    metadata["errorDomain"] = CKErrorDomain
                }
                CrashReporter.shared.captureError(error, category: .sync, metadata: metadata)
            }
        }

        // During a recovery reset, skip the immediate account-change upload — the deferred
        // `.didFetchChanges` path re-uploads after tags are repopulated, avoiding a burst of
        // (now self-healing, but noisy) conflicts in the recovery window.
        // (Read via a sync helper: NSLock is unavailable directly in this async context.)
        if isRecoveryUploadPending() {
            Logger.shared.info(.sync, "[sync-engine] Deferring account-change full upload until post-recovery fetch")
            return
        }

        scheduleFullUpload()
    }

    private func scheduleFullUpload() {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            try dbQueue.read { db in
                let tables: [(tableName: String, recordType: String)] = [
                    ("gyms", "Gym"),
                    ("gym_equipment", "GymEquipment"),
                    ("workout_templates", "WorkoutPlan"),
                    ("template_exercises", "PlannedExercise"),
                    ("template_sets", "PlannedSet"),
                    ("workout_sessions", "WorkoutSession"),
                    ("session_exercises", "SessionExercise"),
                    ("session_sets", "SessionSet"),
                    ("set_measurements", "SetMeasurement"),
                    // user_settings excluded — fetched from server, only uploaded on change
                ]

                var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []

                for (tableName, recordType) in tables {
                    let rows = try Row.fetchAll(db, sql: "SELECT id FROM \(tableName)")
                    for row in rows {
                        guard let id: String = row["id"] else { continue }
                        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
                        pendingChanges.append(.saveRecord(recordID))

                        lock.lock()
                        pendingRecordTypes[id] = recordType
                        lock.unlock()
                    }
                }

                if !pendingChanges.isEmpty {
                    lock.lock()
                    let currentEngine = engine
                    lock.unlock()
                    currentEngine?.state.add(pendingRecordZoneChanges: pendingChanges)
                    Logger.shared.info(.sync, "Scheduled full upload: \(pendingChanges.count) records")
                }
            }
        } catch {
            Logger.shared.error(.sync, "Failed to schedule full upload", error: error)
            CrashReporter.shared.captureError(error, category: .sync, metadata: ["tag": "full-upload-schedule-failed"])
        }
    }

    // MARK: - State Persistence

    private func persistState(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            let data = try JSONEncoder().encode(serialization)
            let dbQueue = try DatabaseManager.shared.database()
            try dbQueue.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO sync_engine_state (id, data) VALUES ('default', ?)",
                    arguments: [data]
                )
            }
        } catch {
            Logger.shared.error(.sync, "Failed to persist sync engine state", error: error)
            CrashReporter.shared.captureError(error, category: .sync, metadata: ["tag": "state-persist-failed"])
        }
    }

    private func loadPersistedState() -> CKSyncEngine.State.Serialization? {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            return try dbQueue.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT data FROM sync_engine_state WHERE id = 'default'")
                guard let row, let data: Data = row["data"] else { return nil }
                return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            }
        } catch {
            Logger.shared.error(.sync, "Failed to load persisted sync engine state", error: error)
            CrashReporter.shared.captureError(error, category: .sync, metadata: ["tag": "state-load-failed"])
            return nil
        }
    }

    // MARK: - Fetched Changes

    /// Dependency order for merging: parents before children.
    private static let mergeOrder = [
        "Gym", "GymEquipment", "WorkoutPlan", "PlannedExercise", "PlannedSet",
        "WorkoutSession", "SessionExercise", "SessionSet", "SetMeasurement", "UserSettings"
    ]

    private func handleFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        let protectedIds = mapper.getActiveSessionProtectedIds()
        var downloaded = 0

        // Sort modifications by dependency order (parents before children)
        let sortedModifications = event.modifications.sorted { lhs, rhs in
            let lhsIndex = Self.mergeOrder.firstIndex(of: lhs.record.recordType) ?? Int.max
            let rhsIndex = Self.mergeOrder.firstIndex(of: rhs.record.recordType) ?? Int.max
            return lhsIndex < rhsIndex
        }

        // Multi-pass merge: retry until all records are merged or no progress is made.
        // This handles arbitrarily deep FK hierarchies (e.g., Plan → Exercise → Set).
        var pendingRecords: [CKRecord] = []
        var changedTypes: Set<String> = []

        for modification in sortedModifications {
            let record = modification.record
            let recordId = record.recordID.recordName
            let recordType = record.recordType

            // Allow WorkoutSession updates through protection — status changes
            // (e.g., completed on another device) must sync even during active sessions.
            // The mergeWorkoutSession handler preserves local cancellation status.
            let isProtectedSession = recordType == "WorkoutSession"
                && protectedIds.sessionId == recordId

            if !isProtectedSession,
               let protectedSet = protectedIds.byRecordType[recordType],
               protectedSet.contains(recordId) {
                Logger.shared.debug(.sync, "[sync-engine] Skipping protected record: \(recordType)/\(recordId)")
                continue
            }
            pendingRecords.append(record)
        }

        let maxPasses = Self.mergeOrder.count
        for pass in 0..<maxPasses {
            guard !pendingRecords.isEmpty else { break }

            var failedRecords: [CKRecord] = []
            var mergedThisPass = 0

            for record in pendingRecords {
                let recordId = record.recordID.recordName
                let recordType = record.recordType
                do {
                    let merged = try mapper.mergeIncoming(record)
                    if merged {
                        downloaded += 1
                        mergedThisPass += 1
                        changedTypes.insert(recordType)
                        Logger.shared.debug(
                            .sync,
                            "[sync-engine] Merged \(recordType)/\(recordId)\(pass > 0 ? " (pass \(pass + 1))" : "")"
                        )
                    } else {
                        failedRecords.append(record)
                    }
                } catch {
                    failedRecords.append(record)
                }
            }

            pendingRecords = failedRecords

            if mergedThisPass == 0 {
                for record in pendingRecords {
                    Logger.shared.debug(
                        .sync,
                        "[sync-engine] Skipped merge \(record.recordType)/\(record.recordID.recordName) " +
                            "— local is newer or unchanged"
                    )
                }
                break
            }

            if !pendingRecords.isEmpty {
                Logger.shared.debug(
                    .sync,
                    "[sync-engine] Pass \(pass + 1) merged \(mergedThisPass), " +
                        "retrying \(pendingRecords.count) remaining"
                )
            }
        }

        for deletion in event.deletions {
            let recordId = deletion.recordID.recordName
            let recordType = deletion.recordType

            // Skip if this record belongs to an active workout session
            if let protectedSet = protectedIds.byRecordType[recordType], protectedSet.contains(recordId) {
                Logger.shared.debug(.sync, "[sync-engine] Skipping protected deletion: \(recordType)/\(recordId)")
                continue
            }

            do {
                try mapper.deleteLocalRecord(id: recordId)
                mapper.metadataStore.remove(recordId)
                downloaded += 1
                changedTypes.insert(recordType)
                Logger.shared.debug(.sync, "[sync-engine] Deleted \(recordType)/\(recordId)")
            } catch {
                Logger.shared.error(.sync, "[sync-engine] Failed to delete \(recordType)/\(recordId)", error: error)
            }
        }

        lock.lock()
        syncDownloaded += downloaded
        syncChangedRecordTypes.formUnion(changedTypes)
        lock.unlock()

        // Notify per-batch so list views refresh as records arrive during a long sync,
        // rather than waiting for the single .syncCompleted at the end of all batches.
        if !changedTypes.isEmpty {
            let typesToReload = changedTypes
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .syncRecordsMerged,
                    object: nil,
                    userInfo: ["changedRecordTypes": typesToReload]
                )
            }
        }
    }

    // MARK: - Sent Changes (delegated)

    private func handleSentChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) {
        // Log successful saves and persist their (now-advanced) system fields so the NEXT
        // edit of each record uploads with the current change tag instead of conflicting.
        for saved in event.savedRecords {
            mapper.metadataStore.save(saved)
            Logger.shared.info(.sync, "[sync-engine] Uploaded \(saved.recordType)/\(saved.recordID.recordName)")
        }

        // Drop metadata for confirmed deletes so a reused record name can't upload a dead tag.
        for deletedID in event.deletedRecordIDs {
            mapper.metadataStore.remove(deletedID.recordName)
        }

        let result = conflictResolver.handleSentChanges(event, removePendingType: { recordName in
            self.lock.lock()
            self.pendingRecordTypes.removeValue(forKey: recordName)
            self.lock.unlock()
        }, engine: engine)

        Logger.shared.debug(
            .sync,
            "[sync-engine] Sent changes: \(result.uploaded) uploaded, \(result.conflicts) conflicts, " +
                "\(event.failedRecordSaves.count) failed"
        )

        // Re-queue records that had local-wins conflicts — the cached server records
        // are ready with local values applied, but CKSyncEngine needs them re-added
        // to pendingRecordZoneChanges to trigger another batch.
        if result.conflicts > 0 {
            var requeued = 0
            for failedSave in event.failedRecordSaves where failedSave.error.code == .serverRecordChanged {
                let recordName = failedSave.record.recordID.recordName
                if conflictResolver.cachedServerRecord(for: recordName) != nil {
                    engine?.state.add(pendingRecordZoneChanges: [.saveRecord(failedSave.record.recordID)])
                    requeued += 1
                }
            }
            if requeued > 0 {
                Logger.shared.info(.sync, "[sync-engine] Re-queued \(requeued) conflict-resolved records for upload")
            }
        }

        lock.lock()
        syncUploaded += result.uploaded
        syncConflicts += result.conflicts
        lock.unlock()
    }

    // MARK: - Account Changes

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        switch event.changeType {
        case .switchAccounts:
            Logger.shared.warn(
                .sync,
                "[sync-engine] CloudKit account switched — resetting upload state before syncing to new account"
            )
            lock.lock()
            hasScheduledInitialUpload = true
            lock.unlock()
            Logger.shared.info(.sync, "[sync-engine] Account changed (\(event.changeType)), creating zone and scheduling full upload")
            Task {
                await createZoneAndScheduleFullUpload()
            }
        case .signIn:
            lock.lock()
            guard !hasScheduledInitialUpload else {
                lock.unlock()
                Logger.shared.info(.sync, "[sync-engine] Account changed but initial upload already scheduled, skipping")
                return
            }
            hasScheduledInitialUpload = true
            lock.unlock()
            Logger.shared.info(.sync, "[sync-engine] Account changed (\(event.changeType)), creating zone and scheduling full upload")
            Task {
                await createZoneAndScheduleFullUpload()
            }
        case .signOut:
            Logger.shared.info(.sync, "[sync-engine] Account signed out, clearing engine state")
            do {
                let dbQueue = try DatabaseManager.shared.database()
                try dbQueue.write { db in
                    try db.execute(sql: "DELETE FROM sync_engine_state")
                }
            } catch {
                Logger.shared.error(.sync, "[sync-engine] Failed to clear engine state on sign out", error: error)
            }
        @unknown default:
            Logger.shared.warn(.sync, "[sync-engine] Unknown account change type")
        }
    }

    // MARK: - Sync Stats Helpers (synchronous, safe to call from async context)

    /// Mark a fetch/send cycle as started. Posts `.syncActivityDidChange(isActive: true)`
    /// only on the 0→1 transition.
    private func beginSyncActivity() {
        lock.lock()
        activeSyncOps += 1
        let becameActive = activeSyncOps == 1
        lock.unlock()
        if becameActive { postSyncActivity(true) }
    }

    /// Mark a fetch/send cycle as finished. Posts `.syncActivityDidChange(isActive: false)`
    /// only on the 1→0 transition.
    private func endSyncActivity() {
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

    private func resetSyncStats() {
        lock.lock()
        syncDownloaded = 0
        syncUploaded = 0
        syncConflicts = 0
        syncChangedRecordTypes = []
        lock.unlock()
    }

    private func collectSyncStats() -> (stats: LastSyncStats, changedRecordTypes: Set<String>) {
        lock.lock()
        let stats = LastSyncStats(uploaded: syncUploaded, downloaded: syncDownloaded, conflicts: syncConflicts)
        let changed = syncChangedRecordTypes
        lastSyncTime = Date()
        lock.unlock()
        return (stats, changed)
    }
}

// MARK: - CKSyncEngineDelegate

extension CKSyncEngineManager: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let stateUpdate):
            persistState(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            handleAccountChange(accountChange)

        case .fetchedRecordZoneChanges(let fetchedChanges):
            handleFetchedChanges(fetchedChanges)

        case .sentRecordZoneChanges(let sentChanges):
            handleSentChanges(sentChanges)

        case .willFetchChanges:
            beginSyncActivity()
            currentSnapshot = SyncSessionGuard.takeSnapshot()
            resetSyncStats()
            CrashReporter.shared.addBreadcrumb("sync.fetch.begin", category: .sync)

        case .didFetchChanges:
            if let snapshot = currentSnapshot {
                SyncSessionGuard.validateAndRestore(snapshot: snapshot)
            }
            currentSnapshot = nil
            CrashReporter.shared.addBreadcrumb("sync.fetch.end", category: .sync)
            let (stats, changedRecordTypes) = collectSyncStats()
            metadataStore.updateSyncMetadata(stats: stats)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .syncCompleted,
                    object: nil,
                    userInfo: ["changedRecordTypes": changedRecordTypes]
                )
            }
            // Now that the post-recovery fetch has repopulated authoritative change tags,
            // re-upload local rows cleanly (one-time, gated by the recovery flag).
            completeRecoveryUploadIfNeeded()
            endSyncActivity()

        case .willSendChanges:
            beginSyncActivity()
            // Clear resolved conflicts so records modified since last cycle can be re-uploaded
            conflictResolver.clearResolved()
            CrashReporter.shared.addBreadcrumb("sync.send.begin", category: .sync)

        case .didSendChanges:
            CrashReporter.shared.addBreadcrumb("sync.send.end", category: .sync)
            endSyncActivity()

        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        case .fetchedDatabaseChanges, .sentDatabaseChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Deduplicate pending changes (re-queued conflicts can cause duplicates)
        var seen = Set<CKRecord.ID>()
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { change in
            let id: CKRecord.ID
            switch change {
            case .saveRecord(let recordID): id = recordID
            case .deleteRecord(let recordID): id = recordID
            @unknown default: return true
            }
            guard !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }

        Logger.shared.debug(.sync, "[sync-engine] Preparing batch: \(pendingChanges.count) pending changes")

        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { recordID in
            let recordName = recordID.recordName

            // Skip records that were already resolved via conflict merge
            if self.conflictResolver.isConflictResolved(recordName) {
                return nil
            }

            // If we have a cached server record from a previous conflict (local-wins),
            // use it as the base and apply local values on top. This preserves the
            // changeTag so CloudKit accepts the update.
            if let serverRecord = self.conflictResolver.cachedServerRecord(for: recordName) {
                if let localRecord = self.mapper.createCKRecord(for: recordID, zoneID: self.zoneID) {
                    // Copy all local field values onto the server record
                    for key in localRecord.allKeys() {
                        serverRecord[key] = localRecord[key]
                    }
                    Logger.shared.debug(
                        .sync,
                        "[sync-engine] Re-uploading \(serverRecord.recordType)/\(recordName) with server changeTag"
                    )
                    return serverRecord
                }
                return nil
            }

            let record = self.mapper.createCKRecord(for: recordID, zoneID: self.zoneID)
            if let record {
                Logger.shared.debug(.sync, "[sync-engine] Uploading \(record.recordType)/\(recordName)")
            }
            return record
        }
        return batch
    }
}

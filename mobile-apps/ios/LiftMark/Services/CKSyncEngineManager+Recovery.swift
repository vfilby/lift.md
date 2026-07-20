import CloudKit
import GRDB

// MARK: - Recovery, Zone Management & State Persistence

extension CKSyncEngineManager {

    // MARK: - Recovery

    /// One-time recovery key. Bump the value to force a full re-upload on next launch.
    private static let fullUploadVersion = "sync.fullUploadVersion"
    /// v5: heal the SetMeasurement conflict loop. Earlier builds uploaded records with no
    /// change tag (CKRecord built fresh every time), so every update conflicted forever and
    /// the pending queue jammed (~8.6k deep), starving completed-workout uploads. v5 resets
    /// the engine's pending state + system-fields cache and re-fetches BEFORE re-uploading,
    /// so the re-upload carries authoritative tags. See spec/services/cloudkit-sync.md.
    private static let currentFullUploadVersion = 5

    /// One-time recovery: if the stored full-upload version is behind, reset the engine's
    /// pending state + system-fields cache so the next sync does a clean fetch-then-upload.
    /// MUST run before `loadPersistedState()` so the engine starts from a fresh (nil) state
    /// and re-fetches every server record (repopulating authoritative change tags via
    /// `mergeIncoming`). Local DB rows are never touched — no data loss. The version is NOT
    /// bumped here; it's bumped only after the deferred upload is scheduled in
    /// `.didFetchChanges`, so an app kill mid-recovery simply re-runs it (idempotent).
    func prepareRecoveryIfNeeded() {
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
    func completeRecoveryUploadIfNeeded() {
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

    // MARK: - Zone Management

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

    func createZoneAndScheduleFullUpload() async {
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

    func persistState(_ serialization: CKSyncEngine.State.Serialization) {
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

    func loadPersistedState() -> CKSyncEngine.State.Serialization? {
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
}

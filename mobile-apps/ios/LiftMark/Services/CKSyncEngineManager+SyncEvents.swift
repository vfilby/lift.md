import CloudKit
import GRDB

// MARK: - Fetched / Sent / Account Event Handling

extension CKSyncEngineManager {

    /// Dependency order for merging: parents before children.
    private static let mergeOrder = [
        "Gym", "GymEquipment", "WorkoutPlan", "PlannedExercise", "PlannedSet",
        "WorkoutSession", "SessionExercise", "SessionSet", "SetMeasurement", "UserSettings"
    ]

    // MARK: - Fetched Changes

    func handleFetchedChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        let protectedIds = mapper.getActiveSessionProtectedIds()
        var changedTypes: Set<String> = []

        let pendingRecords = sortedUnprotectedRecords(from: event, protectedIds: protectedIds)
        var downloaded = mergeWithDependencyRetries(pendingRecords, changedTypes: &changedTypes)
        downloaded += applyFetchedDeletions(from: event, protectedIds: protectedIds, changedTypes: &changedTypes)

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

    /// Sort modifications by dependency order (parents before children) and drop records
    /// protected by the active workout session.
    private func sortedUnprotectedRecords(
        from event: CKSyncEngine.Event.FetchedRecordZoneChanges,
        protectedIds: CKRecordMapper.ActiveSessionProtectedIds
    ) -> [CKRecord] {
        let sortedModifications = event.modifications.sorted { lhs, rhs in
            let lhsIndex = Self.mergeOrder.firstIndex(of: lhs.record.recordType) ?? Int.max
            let rhsIndex = Self.mergeOrder.firstIndex(of: rhs.record.recordType) ?? Int.max
            return lhsIndex < rhsIndex
        }

        var pendingRecords: [CKRecord] = []
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
        return pendingRecords
    }

    /// Multi-pass merge: retry until all records are merged or no progress is made.
    /// This handles arbitrarily deep FK hierarchies (e.g., Plan → Exercise → Set).
    /// Returns the total number of merged records.
    private func mergeWithDependencyRetries(_ records: [CKRecord], changedTypes: inout Set<String>) -> Int {
        var pendingRecords = records
        var downloaded = 0

        let maxPasses = Self.mergeOrder.count
        for pass in 0..<maxPasses {
            guard !pendingRecords.isEmpty else { break }

            let result = mergeSinglePass(pendingRecords, pass: pass, changedTypes: &changedTypes)
            downloaded += result.mergedCount
            pendingRecords = result.failed

            if result.mergedCount == 0 {
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
                    "[sync-engine] Pass \(pass + 1) merged \(result.mergedCount), " +
                        "retrying \(pendingRecords.count) remaining"
                )
            }
        }
        return downloaded
    }

    /// One merge pass over the pending records: returns how many merged and which ones
    /// still need a retry (FK parent not merged yet, or merge threw).
    private func mergeSinglePass(
        _ records: [CKRecord],
        pass: Int,
        changedTypes: inout Set<String>
    ) -> (mergedCount: Int, failed: [CKRecord]) {
        var failedRecords: [CKRecord] = []
        var mergedThisPass = 0

        for record in records {
            let recordId = record.recordID.recordName
            let recordType = record.recordType
            do {
                let merged = try mapper.mergeIncoming(record)
                if merged {
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
        return (mergedThisPass, failedRecords)
    }

    /// Apply incoming deletions, skipping records protected by the active workout session.
    /// Returns the number of applied deletions.
    private func applyFetchedDeletions(
        from event: CKSyncEngine.Event.FetchedRecordZoneChanges,
        protectedIds: CKRecordMapper.ActiveSessionProtectedIds,
        changedTypes: inout Set<String>
    ) -> Int {
        var downloaded = 0
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
        return downloaded
    }

    // MARK: - Sent Changes (delegated)

    func handleSentChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) {
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

    func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
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

        default:
            await handleSyncCycleEvent(event)
        }
    }

    /// Fetch/send cycle lifecycle events (begin/end bookkeeping). Split from `handleEvent`
    /// to keep each switch within the cyclomatic-complexity lint limit.
    private func handleSyncCycleEvent(_ event: CKSyncEngine.Event) async {
        switch event {
        case .willFetchChanges:
            beginSyncActivity()
            currentSnapshot = SyncSessionGuard.takeSnapshot()
            resetSyncStats()
            CrashReporter.shared.addBreadcrumb("sync.fetch.begin", category: .sync)

        case .didFetchChanges:
            await finishFetchCycle()

        case .willSendChanges:
            beginSyncActivity()
            // Clear resolved conflicts so records modified since last cycle can be re-uploaded
            conflictResolver.clearResolved()
            CrashReporter.shared.addBreadcrumb("sync.send.begin", category: .sync)

        case .didSendChanges:
            CrashReporter.shared.addBreadcrumb("sync.send.end", category: .sync)
            endSyncActivity()

        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .fetchedDatabaseChanges, .sentDatabaseChanges:
            break

        default:
            break
        }
    }

    /// End-of-fetch bookkeeping: run the session guard, finalize stats, notify listeners,
    /// then kick the deferred recovery upload (if any) and mark the cycle idle.
    private func finishFetchCycle() async {
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

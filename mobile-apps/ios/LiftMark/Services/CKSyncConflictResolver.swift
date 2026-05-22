import CloudKit

// MARK: - CKSyncConflictResolver

/// Handles the result of sent record zone changes: success cleanup, conflict resolution,
/// and error-code-specific logging/recovery.
final class CKSyncConflictResolver: @unchecked Sendable {

    private let mapper: CKRecordMapper
    private let lock = NSLock()

    /// Records that already exist on the server — skip these in nextRecordZoneChangeBatch.
    private var resolvedConflicts = Set<String>() // recordID.recordName

    /// Server records from conflicts where local wins — used as base for re-upload
    /// so the changeTag matches what CloudKit expects.
    private var serverRecordCache = [String: CKRecord]() // recordName → server CKRecord

    init(mapper: CKRecordMapper) {
        self.mapper = mapper
    }

    /// Returns true if the given recordName was already resolved (server was newer and merged).
    func isConflictResolved(_ recordName: String) -> Bool {
        lock.lock()
        let resolved = resolvedConflicts.contains(recordName)
        lock.unlock()
        return resolved
    }

    /// Clear resolved conflicts at the start of each sync cycle so records
    /// can be re-uploaded if they change again after a previous conflict.
    func clearResolved() {
        lock.lock()
        resolvedConflicts.removeAll()
        // Don't clear serverRecordCache — cached records are needed across batches
        lock.unlock()
    }

    /// Returns the server's version of a record from a previous conflict,
    /// so we can apply local values on top of it (preserving the changeTag).
    func cachedServerRecord(for recordName: String) -> CKRecord? {
        lock.lock()
        let record = serverRecordCache[recordName]
        lock.unlock()
        return record
    }

    /// Process the result of a sent-changes event.
    ///
    /// - Parameters:
    ///   - event: The sent-changes event from CKSyncEngine.
    ///   - removePendingType: Callback to remove a record name from the caller's pending-types map.
    ///   - engine: The sync engine, needed to remove pending changes for unknown-item errors.
    /// - Returns: The number of successfully uploaded records and the number of conflicts encountered.
    @discardableResult
    func handleSentChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        removePendingType: (String) -> Void,
        engine: CKSyncEngine?
    ) -> (uploaded: Int, conflicts: Int) {
        var conflicts = 0

        // Clean up successfully saved records
        for savedRecord in event.savedRecords {
            let recordName = savedRecord.recordID.recordName
            removePendingType(recordName)
        }

        // Handle failures
        for failedSave in event.failedRecordSaves {
            let record = failedSave.record
            let recordName = record.recordID.recordName
            let recordType = record.recordType
            let error = failedSave.error

            switch error.code {
            case .serverRecordChanged:
                conflicts += 1
                handleServerRecordChanged(recordName: recordName, recordType: recordType, error: error)

            case .networkFailure, .networkUnavailable:
                Logger.shared.warn(.sync, "[sync-engine] Network unavailable for \(recordType)/\(recordName) (CKError \(error.code.rawValue)), CKSyncEngine will retry")
                // Transient — breadcrumb only, don't capture.
                CrashReporter.shared.addBreadcrumb("sync.networkRetry", category: .sync, metadata: ["recordType": recordType, "errorCode": "\(error.code.rawValue)"])

            case .quotaExceeded:
                Logger.shared.error(.sync, "[sync-engine] iCloud quota exceeded for \(recordType)/\(recordName) (CKError \(error.code.rawValue))")
                CrashReporter.shared.captureError(error, category: .sync, metadata: ["recordType": recordType, "errorCode": "\(error.code.rawValue)", "errorDomain": CKErrorDomain])

            case .notAuthenticated:
                Logger.shared.error(.sync, "[sync-engine] Not authenticated for \(recordType)/\(recordName) (CKError \(error.code.rawValue))")
                CrashReporter.shared.captureError(error, category: .sync, metadata: ["recordType": recordType, "errorCode": "\(error.code.rawValue)", "errorDomain": CKErrorDomain])

            case .unknownItem:
                Logger.shared.warn(.sync, "[sync-engine] Unknown item \(recordType)/\(recordName) (CKError \(error.code.rawValue), parent likely deleted), removing from pending")
                let ckRecordID = record.recordID
                engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(ckRecordID)])
                removePendingType(recordName)

            case .partialFailure:
                handlePartialFailure(recordName: recordName, recordType: recordType, error: error)

            case .invalidArguments, .serverRejectedRequest:
                // CKError 12 (invalidArguments) and 2006 (serverRejectedRequest) both
                // indicate the local record doesn't match the deployed CloudKit container
                // schema — typically a field present locally but not in Production, or
                // a type mismatch. Capture the field names so we can identify which
                // schema element is missing without needing to repro.
                let fields = record.allKeys().sorted().joined(separator: ",")
                Logger.shared.error(
                    .sync,
                    "[sync-engine] Server rejected \(recordType)/\(recordName) "
                        + "(CKError \(error.code.rawValue) "
                        + "(\(Self.errorCodeName(error.code)))) "
                        + "— likely schema drift. Fields sent: [\(fields)]"
                )
                let metadata: [String: String] = [
                    "recordType": recordType,
                    "recordFields": fields,
                    "errorCode": "\(error.code.rawValue)",
                    "errorDomain": CKErrorDomain,
                    "tag": "schema-drift-suspected"
                ]
                Self.captureOncePerBuild(
                    key: "ck-reject-\(error.code.rawValue)-\(recordType)",
                    error: error,
                    breadcrumb: "sync.schemaDrift.repeat",
                    metadata: metadata
                )

            default:
                Logger.shared.error(
                    .sync,
                    "[sync-engine] Failed to save \(recordType)/\(recordName): "
                        + "CKError \(error.code.rawValue) "
                        + "(\(Self.errorCodeName(error.code))) "
                        + "— \(error.localizedDescription)"
                )
                let fields = record.allKeys().sorted().joined(separator: ",")
                let metadata: [String: String] = [
                    "recordType": recordType,
                    "recordFields": fields,
                    "errorCode": "\(error.code.rawValue)",
                    "errorDomain": CKErrorDomain
                ]
                Self.captureOncePerBuild(
                    key: "ck-fail-\(error.code.rawValue)-\(recordType)",
                    error: error,
                    breadcrumb: "sync.saveFailed.repeat",
                    metadata: metadata
                )
            }
        }

        return (uploaded: event.savedRecords.count, conflicts: conflicts)
    }

    // MARK: - Private

    private func handleServerRecordChanged(recordName: String, recordType: String, error: CKError) {
        if let serverRecord = error.serverRecord {
            // Always merge the server record first (to get latest changeTag into local state),
            // then if local is newer, apply local values on top and queue for re-upload.
            do {
                _ = try mapper.mergeIncoming(serverRecord)
            } catch {
                Logger.shared.error(.sync, "[sync-engine] Failed to merge conflict for \(recordType)/\(recordName)", error: error)
                CrashReporter.shared.captureError(error, category: .sync, metadata: ["recordType": recordType, "tag": "conflict-merge-failed"])
            }

            if mapper.serverRecordIsNewer(serverRecord) {
                // Server wins — we already merged it above, mark resolved
                Logger.shared.info(.sync, "[sync-engine] Conflict: server wins for \(recordType)/\(recordName)")
                lock.lock()
                resolvedConflicts.insert(recordName)
                lock.unlock()
            } else {
                // Local is newer — apply local values onto the server record (which now has
                // the correct changeTag after merge) and cache for immediate re-upload.
                if let localRecord = mapper.createCKRecord(
                    for: CKRecord.ID(recordName: recordName, zoneID: serverRecord.recordID.zoneID),
                    zoneID: serverRecord.recordID.zoneID
                ) {
                    for key in localRecord.allKeys() {
                        serverRecord[key] = localRecord[key]
                    }
                }
                lock.lock()
                serverRecordCache[recordName] = serverRecord
                lock.unlock()
                Logger.shared.info(.sync, "[sync-engine] Conflict: local wins for \(recordType)/\(recordName), re-uploading")
            }
        } else {
            Logger.shared.error(.sync, "[sync-engine] serverRecordChanged for \(recordType)/\(recordName) but no serverRecord provided (CKError \(error.code.rawValue))")
            CrashReporter.shared.captureError(error, category: .sync, metadata: ["recordType": recordType, "errorCode": "\(error.code.rawValue)", "tag": "missing-server-record"])
        }
    }

    private func handlePartialFailure(recordName: String, recordType: String, error: CKError) {
        if let partialErrors = error.partialErrorsByItemID {
            for (itemID, itemError) in partialErrors {
                let ckError = itemError as? CKError
                let codeInfo = ckError.map { "CKError \($0.code.rawValue) (\(Self.errorCodeName($0.code)))" } ?? "non-CK error"
                let subRecordID = (itemID as? CKRecord.ID)?.recordName ?? "\(itemID)"
                Logger.shared.error(.sync, "[sync-engine] Partial failure for \(recordType)/\(subRecordID): \(codeInfo) — \(itemError.localizedDescription)")
                var metadata: [String: String] = ["recordType": recordType, "tag": "partial-failure"]
                if let ckError {
                    metadata["errorCode"] = "\(ckError.code.rawValue)"
                    metadata["errorDomain"] = CKErrorDomain
                }
                CrashReporter.shared.captureError(itemError, category: .sync, metadata: metadata)
            }
            CrashReporter.shared.captureError(error, category: .sync, metadata: ["recordType": recordType, "partialFailureCount": "\(partialErrors.count)", "tag": "partial-failure-rollup"])
        } else {
            Logger.shared.error(.sync, "[sync-engine] Partial failure for \(recordType)/\(recordName): CKError \(error.code.rawValue) — \(error.localizedDescription)")
            CrashReporter.shared.captureError(
                error,
                category: .sync,
                metadata: [
                    "recordType": recordType,
                    "errorCode": "\(error.code.rawValue)",
                    "errorDomain": CKErrorDomain,
                    "tag": "partial-failure"
                ]
            )
        }
    }

    // MARK: - Helpers

    /// Human-readable name for common CKError codes.
    private static let errorCodeNames: [CKError.Code: String] = [
        .internalError: "internalError",
        .partialFailure: "partialFailure",
        .networkUnavailable: "networkUnavailable",
        .networkFailure: "networkFailure",
        .badContainer: "badContainer",
        .serviceUnavailable: "serviceUnavailable",
        .requestRateLimited: "requestRateLimited",
        .missingEntitlement: "missingEntitlement",
        .notAuthenticated: "notAuthenticated",
        .permissionFailure: "permissionFailure",
        .unknownItem: "unknownItem",
        .invalidArguments: "invalidArguments",
        .serverRecordChanged: "serverRecordChanged",
        .serverRejectedRequest: "serverRejectedRequest",
        .assetFileNotFound: "assetFileNotFound",
        .assetFileModified: "assetFileModified",
        .incompatibleVersion: "incompatibleVersion",
        .constraintViolation: "constraintViolation",
        .operationCancelled: "operationCancelled",
        .changeTokenExpired: "changeTokenExpired",
        .batchRequestFailed: "batchRequestFailed",
        .zoneBusy: "zoneBusy",
        .badDatabase: "badDatabase",
        .quotaExceeded: "quotaExceeded",
        .zoneNotFound: "zoneNotFound",
        .limitExceeded: "limitExceeded",
        .userDeletedZone: "userDeletedZone",
        .managedAccountRestricted: "managedAccountRestricted",
        .participantMayNeedVerification: "participantMayNeedVerification",
        .accountTemporarilyUnavailable: "accountTemporarilyUnavailable",
    ]

    static func errorCodeName(_ code: CKError.Code) -> String {
        errorCodeNames[code] ?? "unknown(\(code.rawValue))"
    }

    // MARK: - Capture throttling

    /// Persistent set of (build, key) tuples we've already reported. Same
    /// schema-drift fields would otherwise re-fire every sync cycle on every
    /// affected device, so we capture the full error once per build then drop
    /// to a breadcrumb. Resets when the build number changes so a new release
    /// gets fresh signal even for an already-known offender.
    private static let capturedKeysDefault = "ck-sync-captured-keys"
    private static let capturedBuildDefault = "ck-sync-captured-build"
    private static let capturedKeysLock = NSLock()

    private static func captureOncePerBuild(
        key: String,
        error: Error,
        breadcrumb: String,
        metadata: [String: String]
    ) {
        let defaults = UserDefaults.standard
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        capturedKeysLock.lock()
        let storedBuild = defaults.string(forKey: capturedBuildDefault)
        var captured: Set<String>
        if storedBuild == currentBuild {
            captured = Set(defaults.stringArray(forKey: capturedKeysDefault) ?? [])
        } else {
            captured = []
            defaults.set(currentBuild, forKey: capturedBuildDefault)
        }
        let alreadyCaptured = captured.contains(key)
        if !alreadyCaptured {
            captured.insert(key)
            defaults.set(Array(captured), forKey: capturedKeysDefault)
        }
        capturedKeysLock.unlock()

        if alreadyCaptured {
            CrashReporter.shared.addBreadcrumb(breadcrumb, category: .sync, metadata: metadata)
        } else {
            CrashReporter.shared.captureError(error, category: .sync, metadata: metadata)
        }
    }
}

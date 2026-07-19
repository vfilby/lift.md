import CloudKit
import GRDB

/// Handles conversion between GRDB row types and CKRecords, plus merging incoming
/// CKRecords into the local database. Extracted from CloudKitService to support the
/// CKSyncEngine migration.
///
/// Per-record-type mapping and merging lives in extensions:
/// - `CKRecordMapper+Gyms` — Gym, GymEquipment
/// - `CKRecordMapper+Plans` — WorkoutPlan, PlannedExercise, PlannedSet
/// - `CKRecordMapper+Sessions` — WorkoutSession, SessionExercise, SessionSet
/// - `CKRecordMapper+Settings` — UserSettings
/// - `CKRecordMapper+SetMeasurement` — SetMeasurement (plus set-measurement dual read/write)
/// - `CKRecordMapper+ActiveSession` — active-session sync protection
final class CKRecordMapper {
    let dbManager: DatabaseManager

    /// Per-record CloudKit system-fields (change tag) cache. Used to rehydrate CKRecords
    /// on upload so updates carry the current change tag instead of conflicting forever.
    let metadataStore: CKRecordMetadataStore

    init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
        self.metadataStore = CKRecordMetadataStore(dbManager: dbManager)
    }

    /// Rehydrate a freshly-built record onto its server-confirmed system fields (change
    /// tag), so an upload of an already-existing record is accepted by CloudKit instead of
    /// conflicting. If we hold stored system fields for this record, copy the fresh record's
    /// data fields onto the decoded (metadata-only) base and return that; otherwise return
    /// the fresh record unchanged (a genuinely new record CloudKit will create).
    ///
    /// Applied by `createCKRecord` *outside* any open database read — `decodedRecord` opens
    /// its own read, so calling it inside another read would trip GRDB's non-reentrancy.
    func applyStoredSystemFields(to record: CKRecord) -> CKRecord {
        guard let base = metadataStore.decodedRecord(for: record.recordID.recordName),
              base.recordType == record.recordType else {
            return record
        }
        for key in record.allKeys() {
            base[key] = record[key]
        }
        return base
    }

    // MARK: - Date Helpers

    let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let isoFormatterNoFrac: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func parseDate(_ str: String?) -> Date? {
        guard let str else { return nil }
        return isoFormatter.date(from: str) ?? isoFormatterNoFrac.date(from: str)
    }

    func dateToISO(_ date: Date?) -> String? {
        guard let date else { return nil }
        return isoFormatter.string(from: date)
    }

    // MARK: - CKRecord Field Extractors

    func stringField(_ record: CKRecord, _ key: String) -> String? {
        record[key] as? String
    }

    func int64Field(_ record: CKRecord, _ key: String) -> Int64? {
        record[key] as? Int64
    }

    func doubleField(_ record: CKRecord, _ key: String) -> Double? {
        record[key] as? Double
    }

    func dateField(_ record: CKRecord, _ key: String) -> Date? {
        record[key] as? Date
    }

    func stringListField(_ record: CKRecord, _ key: String) -> [String] {
        record[key] as? [String] ?? []
    }

    func referenceId(_ record: CKRecord, _ key: String) -> String? {
        if let ref = record[key] as? CKRecord.Reference {
            return ref.recordID.recordName
        }
        return record[key] as? String
    }

    /// Returns true if the given CKRecord's updatedAt is strictly newer than the local
    /// record's updatedAt. Used by conflict resolution to decide whether server or local
    /// wins. On equal timestamps this returns false — local is kept (last-writer-wins with
    /// a local-keeps-tie rule), which is required so a recovery re-fetch can't clobber a
    /// dirty local row that shares a timestamp with its server copy.
    func serverRecordIsNewer(_ record: CKRecord) -> Bool {
        do {
            let dbQueue = try dbManager.database()
            return try dbQueue.read { db in
                let remoteDate = self.dateField(record, "updatedAt")

                // Look up the local updatedAt based on record type
                let localUpdatedAt = try self.localUpdatedAt(for: record, db: db)

                return self.remoteIsNewer(remoteDate: remoteDate, localUpdatedAt: localUpdatedAt)
            }
        } catch {
            // If we can't read the local DB, default to server wins
            Logger.shared.error(.sync, "Failed to read local record for conflict check: \(error.localizedDescription)")
            return true
        }
    }

    /// Look up the local row's updatedAt for the given record's type and record name.
    private func localUpdatedAt(for record: CKRecord, db: Database) throws -> String? {
        let recordName = record.recordID.recordName
        switch record.recordType {
        case "Gym":
            return try GymRow.fetchOne(db, key: recordName)?.updatedAt
        case "GymEquipment":
            return try GymEquipmentRow.fetchOne(db, key: recordName)?.updatedAt
        case "WorkoutPlan":
            return try WorkoutPlanRow.fetchOne(db, key: recordName)?.updatedAt
        case "PlannedExercise":
            return try PlannedExerciseRow.fetchOne(db, key: recordName)?.updatedAt
        case "PlannedSet":
            return try PlannedSetRow.fetchOne(db, key: recordName)?.updatedAt
        default:
            return try sessionTierUpdatedAt(recordType: record.recordType, recordName: recordName, db: db)
        }
    }

    /// Session-tier and singleton half of `localUpdatedAt(for:db:)`.
    private func sessionTierUpdatedAt(recordType: String, recordName: String, db: Database) throws -> String? {
        switch recordType {
        case "WorkoutSession":
            return try WorkoutSessionRow.fetchOne(db, key: recordName)?.updatedAt
        case "SessionExercise":
            return try SessionExerciseRow.fetchOne(db, key: recordName)?.updatedAt
        case "SessionSet":
            return try SessionSetRow.fetchOne(db, key: recordName)?.updatedAt
        case "UserSettings":
            return try UserSettingsRow.fetchOne(db, key: recordName)?.updatedAt
        case "SetMeasurement":
            return try SetMeasurementRow.fetchOne(db, key: recordName)?.updatedAt
        default:
            return nil
        }
    }

    /// Returns true if remote updatedAt is newer than local updatedAt.
    func remoteIsNewer(remoteDate: Date?, localUpdatedAt: String?) -> Bool {
        guard let remoteDate else { return false }
        guard let localStr = localUpdatedAt, let localDate = parseDate(localStr) else { return true }
        return remoteDate > localDate
    }

    // MARK: - Reference Helper

    func makeReference(recordName: String, zoneID: CKRecordZone.ID) -> CKRecord.Reference {
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        return CKRecord.Reference(recordID: id, action: .none)
    }

    // MARK: - Merge Incoming

    /// Routes an incoming CKRecord to the appropriate merge method. Returns true if local DB was updated.
    func mergeIncoming(_ record: CKRecord) throws -> Bool {
        let dbQueue = try dbManager.database()

        // Persist the server's system fields UNCONDITIONALLY — before (and regardless of)
        // the row-merge decision. Even when local wins / is unchanged, the server's change
        // tag is the concurrency token our NEXT upload of this record must carry, or that
        // upload will conflict. A record first learned via fetch and later edited locally
        // depends on this.
        metadataStore.save(record)

        switch record.recordType {
        case "Gym", "GymEquipment":
            return try mergeGymRecord(record, dbQueue: dbQueue)
        case "WorkoutPlan", "PlannedExercise", "PlannedSet":
            return try mergePlanRecord(record, dbQueue: dbQueue)
        case "WorkoutSession", "SessionExercise", "SessionSet":
            return try mergeSessionRecord(record, dbQueue: dbQueue)
        case "UserSettings":
            return try mergeUserSettings(record, dbQueue: dbQueue)
        case "SetMeasurement":
            return try mergeSetMeasurement(record, dbQueue: dbQueue)
        default:
            return logUnknownRecordType(record)
        }
    }

    /// Shared fallback for a CKRecord whose type no merge route recognizes.
    func logUnknownRecordType(_ record: CKRecord) -> Bool {
        Logger.shared.warn(.sync, "Unknown record type for merge: \(record.recordType)")
        return false
    }

    // MARK: - Record Lookup

    /// Create a CKRecord for a local row identified by its record ID.
    /// Scans all entity tables to find the matching row.
    func createCKRecord(for recordID: CKRecord.ID, zoneID: CKRecordZone.ID) -> CKRecord? {
        let id = recordID.recordName
        do {
            let dbQueue = try dbManager.database()
            // Build the fresh record inside the read, then rehydrate its change tag OUTSIDE
            // the read (applyStoredSystemFields opens its own read → would be reentrant here).
            let fresh = try dbQueue.read { db -> CKRecord? in
                try self.freshGymTierRecord(id: id, zoneID: zoneID, db: db)
                    ?? self.freshPlanTierRecord(id: id, zoneID: zoneID, db: db)
                    ?? self.freshSessionTierRecord(id: id, zoneID: zoneID, db: db)
                    ?? self.freshSettingsRecord(id: id, zoneID: zoneID, db: db)
                    ?? self.freshMeasurementRecord(id: id, zoneID: zoneID, db: db)
            }
            guard let fresh else { return nil }
            return applyStoredSystemFields(to: fresh)
        } catch {
            Logger.shared.error(.sync, "Failed to look up local record for \(id)", error: error)
            return nil
        }
    }

    // MARK: - Local Deletion

    /// Delete a local record by ID, scanning all entity tables.
    func deleteLocalRecord(id: String) throws {
        let dbQueue = try dbManager.database()
        let tables = [
            "gyms", "gym_equipment", "workout_templates", "template_exercises",
            "template_sets", "workout_sessions", "session_exercises", "session_sets",
            "user_settings"
        ]
        try dbQueue.write { db in
            // Clean up measurements if this is a set being deleted (no CASCADE)
            try db.execute(sql: "DELETE FROM set_measurements WHERE set_id = ?", arguments: [id])

            // Also try deleting from set_measurements directly (the deleted record may BE a SetMeasurement)
            try db.execute(sql: "DELETE FROM set_measurements WHERE id = ?", arguments: [id])
            if db.changesCount > 0 { return }

            for table in tables {
                try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id])
                if db.changesCount > 0 { return }
            }
        }
    }
}

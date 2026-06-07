import CloudKit
import Foundation
import GRDB

/// Persists each CloudKit record's system fields (the `recordChangeTag` and zone
/// metadata) in the `ck_record_metadata` table, keyed by record name.
///
/// CKSyncEngine's serialized state holds only the database/zone change tokens and the
/// set of pending record IDs — it does NOT store the records or their change tags.
/// Persisting `encodedSystemFields` is therefore the app's responsibility: every
/// upload of an already-existing record must be rehydrated from these stored system
/// fields so it carries the current change tag. Without this, each upload sends a nil
/// change tag, CloudKit rejects it with `serverRecordChanged`, and the resolver loops
/// forever (the conflict-loop this type was introduced to fix).
///
/// See `spec/services/cloudkit-sync.md`.
final class CKRecordMetadataStore: @unchecked Sendable {
    private let dbManager: DatabaseManager

    init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Read

    /// The archived system-fields blob for a record, or nil if we've never seen it confirmed.
    func systemFields(for recordName: String) -> Data? {
        do {
            let dbQueue = try dbManager.database()
            return try dbQueue.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT system_fields FROM ck_record_metadata WHERE record_name = ?",
                    arguments: [recordName]
                )
            }
        } catch {
            Logger.shared.error(.sync, "Failed to read CK system fields for \(recordName)", error: error)
            return nil
        }
    }

    /// A metadata-only CKRecord rehydrated from stored system fields (no user fields set),
    /// carrying the last server-confirmed change tag. Returns nil when no metadata exists
    /// (i.e. the record is genuinely new and must be created fresh).
    func decodedRecord(for recordName: String) -> CKRecord? {
        guard let data = systemFields(for: recordName) else { return nil }
        do {
            // System fields are written by `encodeSystemFields(with:)` at the archive's top
            // level (not as a keyed root object), so they must be read back with the
            // `CKRecord(coder:)` initializer — not `unarchivedObject(ofClass:from:)`.
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            let record = CKRecord(coder: unarchiver)
            unarchiver.finishDecoding()
            guard let record else { throw CocoaError(.coderReadCorrupt) }
            return record
        } catch {
            // Corrupt/incompatible metadata: drop it so the record uploads fresh and self-heals.
            Logger.shared.warn(.sync, "Failed to decode CK system fields for \(recordName); dropping cached metadata")
            remove(recordName)
            return nil
        }
    }

    // MARK: - Write

    /// Store the system fields from a server-confirmed record (after a successful save,
    /// an incoming fetch, or a conflict's `error.serverRecord`). Idempotent upsert.
    func save(_ record: CKRecord) {
        do {
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            record.encodeSystemFields(with: coder)
            coder.finishEncoding()
            let data = coder.encodedData
            let now = isoFormatter.string(from: Date())
            let dbQueue = try dbManager.database()
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO ck_record_metadata (record_name, record_type, system_fields, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(record_name) DO UPDATE SET
                        record_type = excluded.record_type,
                        system_fields = excluded.system_fields,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [record.recordID.recordName, record.recordType, data, now]
                )
            }
        } catch {
            let name = record.recordID.recordName
            Logger.shared.error(.sync, "Failed to persist CK system fields for \(name)", error: error)
        }
    }

    /// Drop the metadata for a record after a confirmed delete (local or remote).
    func remove(_ recordName: String) {
        do {
            let dbQueue = try dbManager.database()
            try dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM ck_record_metadata WHERE record_name = ?",
                    arguments: [recordName]
                )
            }
        } catch {
            Logger.shared.error(.sync, "Failed to remove CK system fields for \(recordName)", error: error)
        }
    }

    /// Clear all cached system fields. Used by the v5 recovery (so a forced re-fetch
    /// repopulates authoritative tags) and by test isolation.
    func clearAll() {
        do {
            let dbQueue = try dbManager.database()
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM ck_record_metadata")
            }
        } catch {
            Logger.shared.error(.sync, "Failed to clear CK record metadata", error: error)
        }
    }
}

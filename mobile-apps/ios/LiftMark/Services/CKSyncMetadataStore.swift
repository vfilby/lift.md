import Foundation
import GRDB

// MARK: - Last Sync Stats

struct LastSyncStats {
    var uploaded: Int
    var downloaded: Int
    var conflicts: Int
}

// MARK: - CKSyncMetadataStore

/// Reads and writes the `sync_metadata` table: last sync date, stats, and sync-enabled flag.
final class CKSyncMetadataStore: @unchecked Sendable {

    // MARK: - Read

    func getLastSyncDate() -> Date? {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            return try dbQueue.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT last_sync_date FROM sync_metadata LIMIT 1")
                if let row, let dateString: String = row["last_sync_date"] {
                    return ISO8601DateFormatter().date(from: dateString)
                }
                return nil
            }
        } catch {
            Logger.shared.error(.sync, "Failed to read last sync date", error: error)
            return nil
        }
    }

    func getLastSyncStats() -> LastSyncStats? {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            return try dbQueue.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT last_sync_date, last_uploaded, last_downloaded, last_conflicts FROM sync_metadata LIMIT 1")
                guard let row, (row["last_sync_date"] as String?) != nil else { return nil }
                return LastSyncStats(
                    uploaded: row["last_uploaded"] ?? 0,
                    downloaded: row["last_downloaded"] ?? 0,
                    conflicts: row["last_conflicts"] ?? 0
                )
            }
        } catch {
            Logger.shared.error(.sync, "Failed to read last sync stats", error: error)
            return nil
        }
    }

    func getSyncEnabled() -> Bool {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            return try dbQueue.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT sync_enabled FROM sync_metadata LIMIT 1")
                if let row, let value: Int = row["sync_enabled"] {
                    return value != 0
                }
                return true // default on
            }
        } catch {
            return true
        }
    }

    // MARK: - Write

    func setSyncEnabled(_ enabled: Bool) {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            let now = ISO8601DateFormatter().string(from: Date())
            try dbQueue.write { db in
                let existing = try Row.fetchOne(db, sql: "SELECT id FROM sync_metadata LIMIT 1")
                if existing != nil {
                    try db.execute(sql: "UPDATE sync_metadata SET sync_enabled = ?, updated_at = ?", arguments: [enabled ? 1 : 0, now])
                } else {
                    try db.execute(
                        sql: "INSERT INTO sync_metadata (id, device_id, sync_enabled, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                        arguments: [IDGenerator.generate(), UUID().uuidString, enabled ? 1 : 0, now, now]
                    )
                }
            }
        } catch {
            Logger.shared.error(.sync, "Failed to update sync enabled", error: error)
        }
    }

    func updateSyncMetadata(stats: LastSyncStats = LastSyncStats(uploaded: 0, downloaded: 0, conflicts: 0)) {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            let now = ISO8601DateFormatter().string(from: Date())
            try dbQueue.write { db in
                let existing = try Row.fetchOne(db, sql: "SELECT id FROM sync_metadata LIMIT 1")
                if existing != nil {
                    try db.execute(
                        sql: "UPDATE sync_metadata SET last_sync_date = ?, last_uploaded = ?, last_downloaded = ?, last_conflicts = ?, updated_at = ?",
                        arguments: [now, stats.uploaded, stats.downloaded, stats.conflicts, now]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO sync_metadata (id, device_id, last_sync_date,
                                last_uploaded, last_downloaded, last_conflicts,
                                sync_enabled, created_at, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            IDGenerator.generate(), UUID().uuidString, now,
                            stats.uploaded, stats.downloaded, stats.conflicts,
                            1, now, now
                        ]
                    )
                }
            }
        } catch {
            Logger.shared.error(.sync, "Failed to update sync metadata", error: error)
        }
    }
}

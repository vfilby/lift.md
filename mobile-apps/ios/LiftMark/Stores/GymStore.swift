import Foundation
import GRDB

@MainActor
@Observable
final class GymStore {
    private(set) var gyms: [Gym] = []
    private(set) var isLoading = false
    private(set) var lastError: Error?

    func clearError() {
        lastError = nil
    }

    func loadGyms() {
        isLoading = true
        defer { isLoading = false }
        do {
            let dbQueue = try DatabaseManager.shared.database()
            let rows = try dbQueue.read { db in
                try GymRow
                    .filter(Column("deleted_at") == nil)
                    .order(Column("is_default").desc, Column("name"))
                    .fetchAll(db)
            }
            gyms = rows.map {
                Gym(
                    id: $0.id,
                    name: $0.name,
                    isDefault: $0.isDefault != 0,
                    deletedAt: $0.deletedAt,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }

            // Safety net: ensure exactly one default gym
            ensureSingleDefault()
            lastError = nil
        } catch {
            lastError = error
            Logger.shared.error(.database, "Failed to load gyms", error: error)
        }
    }

    func createGym(name: String) {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            let now = ISO8601DateFormatter().string(from: Date())
            let gymId = IDGenerator.generate()
            let isDefault = gyms.filter({ !$0.isDeleted }).isEmpty
            try dbQueue.write { db in
                let row = GymRow(
                    id: gymId,
                    name: name,
                    isDefault: isDefault ? 1 : 0,
                    deletedAt: nil,
                    createdAt: now,
                    updatedAt: now
                )
                try row.insert(db)
            }
            CKSyncEngineManager.notifySave(recordType: "Gym", recordID: gymId)
            let newGym = Gym(
                id: gymId, name: name, isDefault: isDefault, deletedAt: nil, createdAt: now, updatedAt: now)
            gyms.append(newGym)
            lastError = nil
        } catch {
            lastError = error
            Logger.shared.error(.database, "Failed to create gym", error: error)
        }
    }

    func deleteGym(id: String) {
        let activeGyms = gyms.filter { !$0.isDeleted }
        guard activeGyms.count > 1 else { return }

        let deletedGym = activeGyms.first { $0.id == id }

        do {
            let dbQueue = try DatabaseManager.shared.database()
            let now = ISO8601DateFormatter().string(from: Date())
            // Collect equipment IDs for sync notification
            let equipmentIds = try dbQueue.read { db -> [String] in
                let rows = try Row.fetchAll(db, sql: "SELECT id FROM gym_equipment WHERE gym_id = ?", arguments: [id])
                return rows.compactMap { $0["id"] as String? }
            }
            var newDefaultId: String?
            try dbQueue.write { db in
                // Soft-delete the gym
                try db.execute(
                    sql: "UPDATE gyms SET deleted_at = ?, updated_at = ? WHERE id = ?",
                    arguments: [now, now, id]
                )
                // Soft-delete associated equipment
                try db.execute(
                    sql: "UPDATE gym_equipment SET deleted_at = ?, updated_at = ? WHERE gym_id = ?",
                    arguments: [now, now, id]
                )

                // If deleted gym was the default, reassign to first remaining active gym
                if deletedGym?.isDefault == true {
                    let firstRemaining = try Row.fetchOne(
                        db,
                        sql: "SELECT id FROM gyms WHERE deleted_at IS NULL AND id != ? ORDER BY name LIMIT 1",
                        arguments: [id]
                    )
                    if let defaultId: String = firstRemaining?["id"] {
                        newDefaultId = defaultId
                        try db.execute(sql: "UPDATE gyms SET is_default = 0 WHERE deleted_at IS NULL")
                        try db.execute(
                            sql: "UPDATE gyms SET is_default = 1, updated_at = ? WHERE id = ?",
                            arguments: [now, defaultId]
                        )
                    }
                }
            }
            // Notify sync engine (soft-delete = save with deleted_at set)
            CKSyncEngineManager.notifySave(recordType: "Gym", recordID: id)
            for eqId in equipmentIds {
                CKSyncEngineManager.notifySave(recordType: "GymEquipment", recordID: eqId)
            }
            if let newDefaultId {
                CKSyncEngineManager.notifySave(recordType: "Gym", recordID: newDefaultId)
            }
            loadGyms()
        } catch {
            lastError = error
            Logger.shared.error(.database, "Failed to delete gym", error: error)
        }
    }

    func setDefault(id: String) {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            let now = ISO8601DateFormatter().string(from: Date())
            // Collect all active gym IDs to notify (they all get updated_at changed)
            let activeGymIds = try dbQueue.read { db -> [String] in
                let rows = try Row.fetchAll(db, sql: "SELECT id FROM gyms WHERE deleted_at IS NULL")
                return rows.compactMap { $0["id"] as String? }
            }
            try dbQueue.write { db in
                // Clear all defaults, then set the chosen one
                try db.execute(
                    sql: "UPDATE gyms SET is_default = 0, updated_at = ? WHERE deleted_at IS NULL",
                    arguments: [now]
                )
                try db.execute(
                    sql: "UPDATE gyms SET is_default = 1, updated_at = ? WHERE id = ?",
                    arguments: [now, id]
                )
            }
            for gymId in activeGymIds {
                CKSyncEngineManager.notifySave(recordType: "Gym", recordID: gymId)
            }
            loadGyms()
        } catch {
            lastError = error
            Logger.shared.error(.database, "Failed to set default gym", error: error)
        }
    }

    // MARK: - Private

    /// Ensures exactly one gym is marked as default. Fixes data if needed.
    private func ensureSingleDefault() {
        let defaults = gyms.filter(\.isDefault)
        if defaults.count == 1 { return }

        do {
            let dbQueue = try DatabaseManager.shared.database()
            let now = ISO8601DateFormatter().string(from: Date())
            try dbQueue.write { db in
                // Clear all defaults
                try db.execute(
                    sql: "UPDATE gyms SET is_default = 0 WHERE deleted_at IS NULL"
                )
                // Set the first active gym as default
                let first = try Row.fetchOne(
                    db,
                    sql: "SELECT id FROM gyms WHERE deleted_at IS NULL ORDER BY name LIMIT 1"
                )
                if let defaultId: String = first?["id"] {
                    try db.execute(
                        sql: "UPDATE gyms SET is_default = 1, updated_at = ? WHERE id = ?",
                        arguments: [now, defaultId]
                    )
                }
            }

            // Re-read after fixing
            let rows = try dbQueue.read { db in
                try GymRow
                    .filter(Column("deleted_at") == nil)
                    .order(Column("is_default").desc, Column("name"))
                    .fetchAll(db)
            }
            gyms = rows.map {
                Gym(
                    id: $0.id,
                    name: $0.name,
                    isDefault: $0.isDefault != 0,
                    deletedAt: $0.deletedAt,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }
        } catch {
            lastError = error
            Logger.shared.error(.database, "Failed to ensure single default gym", error: error)
        }
    }
}

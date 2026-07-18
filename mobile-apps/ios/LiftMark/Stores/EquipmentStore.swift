import Foundation
import GRDB

@MainActor
@Observable
final class EquipmentStore {
    private(set) var equipment: [GymEquipment] = []
    private(set) var isLoading = false
    private(set) var lastError: Error?

    func clearError() {
        lastError = nil
    }

    func loadEquipment(forGym gymId: String) {
        isLoading = true
        defer { isLoading = false }
        do {
            let dbQueue = try DatabaseManager.shared.database()
            let rows = try dbQueue.read { db in
                try GymEquipmentRow
                    .filter(Column("gym_id") == gymId && Column("deleted_at") == nil)
                    .order(Column("name"))
                    .fetchAll(db)
            }
            equipment = rows.map {
                GymEquipment(
                    id: $0.id,
                    gymId: $0.gymId ?? gymId,
                    name: $0.name,
                    isAvailable: $0.isAvailable != 0,
                    lastCheckedAt: $0.lastCheckedAt,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }
            lastError = nil
        } catch {
            lastError = error
            Logger.shared.error(.database, "Failed to load equipment", error: error)
        }
    }

    func addEquipment(name: String, gymId: String) {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            let now = ISO8601DateFormatter().string(from: Date())
            let equipmentId = IDGenerator.generate()
            try dbQueue.write { db in
                let row = GymEquipmentRow(
                    id: equipmentId,
                    name: name,
                    isAvailable: 1,
                    lastCheckedAt: nil,
                    deletedAt: nil,
                    createdAt: now,
                    updatedAt: now,
                    gymId: gymId
                )
                try row.insert(db)
            }
            CKSyncEngineManager.notifySave(recordType: "GymEquipment", recordID: equipmentId)
            let newEquipment = GymEquipment(
                id: equipmentId, gymId: gymId, name: name, isAvailable: true,
                lastCheckedAt: nil, createdAt: now, updatedAt: now)
            equipment.append(newEquipment)
            lastError = nil
        } catch {
            lastError = error
            Logger.shared.error(.database, "Failed to add equipment", error: error)
        }
    }

    func removeEquipment(id: String, gymId: String) {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM gym_equipment WHERE id = ?", arguments: [id])
            }
            CKSyncEngineManager.notifyDelete(recordType: "GymEquipment", recordID: id)
            equipment.removeAll { $0.id == id }
            lastError = nil
        } catch {
            lastError = error
            Logger.shared.error(.database, "Failed to remove equipment", error: error)
        }
    }

    func toggleAvailability(id: String, gymId: String) {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            let now = ISO8601DateFormatter().string(from: Date())
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE gym_equipment SET is_available = CASE WHEN is_available = 1 THEN 0 ELSE 1 END, "
                        + "last_checked_at = ? WHERE id = ?",
                    arguments: [now, id]
                )
            }
            CKSyncEngineManager.notifySave(recordType: "GymEquipment", recordID: id)
            if let index = equipment.firstIndex(where: { $0.id == id }) {
                equipment[index].isAvailable.toggle()
            }
            lastError = nil
        } catch {
            lastError = error
            Logger.shared.error(.database, "Failed to toggle equipment", error: error)
        }
    }
}

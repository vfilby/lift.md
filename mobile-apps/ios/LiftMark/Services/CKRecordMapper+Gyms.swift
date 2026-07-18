import CloudKit
import GRDB

// MARK: - Gym & GymEquipment CKRecord Mapping & Merging

extension CKRecordMapper {

    // MARK: - To CKRecord

    func toCKRecord(_ gym: GymRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "Gym", recordID: CKRecord.ID(recordName: gym.id, zoneID: zoneID))
        record["name"] = gym.name as CKRecordValue
        record["isDefault"] = Int64(gym.isDefault) as CKRecordValue
        if let date = parseDate(gym.createdAt) { record["createdAt"] = date as CKRecordValue }
        if let date = parseDate(gym.updatedAt) { record["updatedAt"] = date as CKRecordValue }
        return record
    }

    func toCKRecord(_ eq: GymEquipmentRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "GymEquipment", recordID: CKRecord.ID(recordName: eq.id, zoneID: zoneID))
        record["name"] = eq.name as CKRecordValue
        record["isAvailable"] = Int64(eq.isAvailable) as CKRecordValue
        if let gymId = eq.gymId {
            record["gymId"] = makeReference(recordName: gymId, zoneID: zoneID) as CKRecordValue
        }
        if let date = parseDate(eq.lastCheckedAt) { record["lastCheckedAt"] = date as CKRecordValue }
        if let date = parseDate(eq.createdAt) { record["createdAt"] = date as CKRecordValue }
        if let date = parseDate(eq.updatedAt) { record["updatedAt"] = date as CKRecordValue }
        return record
    }

    // MARK: - Merge Routing

    /// Routes an incoming gym-tier CKRecord (Gym, GymEquipment) to its merge method.
    func mergeGymRecord(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        switch record.recordType {
        case "Gym":
            return try mergeGym(record, dbQueue: dbQueue)
        case "GymEquipment":
            return try mergeGymEquipment(record, dbQueue: dbQueue)
        default:
            return logUnknownRecordType(record)
        }
    }

    // MARK: - Merge Methods

    private func mergeGym(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let existing = try GymRow.fetchOne(db, key: record.recordID.recordName)

            // Don't re-insert a gym that was soft-deleted locally
            if let existing, existing.deletedAt != nil {
                return false
            }

            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }
            let row = GymRow(
                id: record.recordID.recordName,
                name: self.stringField(record, "name") ?? "Gym",
                isDefault: Int(self.int64Field(record, "isDefault") ?? 0),
                deletedAt: nil,
                createdAt: self.dateToISO(self.dateField(record, "createdAt")) ?? existing?.createdAt
                    ?? self.isoFormatter.string(from: Date()),
                updatedAt: self.dateToISO(remoteUpdatedAt) ?? existing?.updatedAt
                    ?? self.isoFormatter.string(from: Date())
            )
            if existing != nil { try row.update(db) } else { try row.insert(db) }
            return true
        }
    }

    private func mergeGymEquipment(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let existing = try GymEquipmentRow.fetchOne(db, key: record.recordID.recordName)

            // Don't re-insert equipment that was soft-deleted locally
            if let existing, existing.deletedAt != nil {
                return false
            }

            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }
            let row = GymEquipmentRow(
                id: record.recordID.recordName,
                name: self.stringField(record, "name") ?? "Equipment",
                isAvailable: Int(self.int64Field(record, "isAvailable") ?? 1),
                lastCheckedAt: self.dateToISO(self.dateField(record, "lastCheckedAt")),
                deletedAt: nil,
                createdAt: self.dateToISO(self.dateField(record, "createdAt")) ?? existing?.createdAt
                    ?? self.isoFormatter.string(from: Date()),
                updatedAt: self.dateToISO(remoteUpdatedAt) ?? existing?.updatedAt
                    ?? self.isoFormatter.string(from: Date()),
                gymId: self.referenceId(record, "gymId")
            )
            if existing != nil { try row.update(db) } else { try row.insert(db) }
            return true
        }
    }

    // MARK: - Record Lookup

    /// Build a fresh CKRecord for a gym-tier row (Gym, GymEquipment) matching the given ID,
    /// or nil if no such row exists or the row was soft-deleted locally.
    func freshGymTierRecord(id: String, zoneID: CKRecordZone.ID, db: Database) throws -> CKRecord? {
        if let gym = try GymRow.fetchOne(db, key: id) {
            if gym.deletedAt != nil { return nil }
            return toCKRecord(gym, zoneID: zoneID)
        }
        if let eq = try GymEquipmentRow.fetchOne(db, key: id) {
            if eq.deletedAt != nil { return nil }
            return toCKRecord(eq, zoneID: zoneID)
        }
        return nil
    }
}

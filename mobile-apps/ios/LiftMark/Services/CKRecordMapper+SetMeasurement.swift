import CloudKit
import GRDB

// MARK: - SetMeasurement CKRecord Mapping & Merging

extension CKRecordMapper {

    // MARK: - To CKRecord

    func toCKRecord(_ m: SetMeasurementRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "SetMeasurement", recordID: CKRecord.ID(recordName: m.id, zoneID: zoneID))
        record["setId"] = makeReference(recordName: m.setId, zoneID: zoneID) as CKRecordValue
        record["parentType"] = m.parentType as CKRecordValue
        record["role"] = m.role as CKRecordValue
        record["kind"] = m.kind as CKRecordValue
        record["value"] = m.value as CKRecordValue
        if let u = m.unit { record["unit"] = u as CKRecordValue }
        record["groupIndex"] = Int64(m.groupIndex) as CKRecordValue
        if let d = parseDate(m.updatedAt) { record["updatedAt"] = d as CKRecordValue }
        return record
    }

    func toCKRecord(_ ps: PlannedSetRow, measurements: [SetMeasurementRow] = [], zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "PlannedSet", recordID: CKRecord.ID(recordName: ps.id, zoneID: zoneID))
        record["plannedExerciseId"] = makeReference(recordName: ps.templateExerciseId, zoneID: zoneID) as CKRecordValue
        record["orderIndex"] = Int64(ps.orderIndex) as CKRecordValue
        var attrs: [String] = []
        if ps.isDropset != 0 { attrs.append("dropset") }
        if ps.isPerSide != 0 { attrs.append("perSide") }
        if ps.isAmrap != 0 { attrs.append("amrap") }
        if !attrs.isEmpty { record["attributes"] = attrs as CKRecordValue }

        // Write target fields from measurements (dual-write for backward compat with old devices)
        writeMeasurementFields(from: measurements, to: record)

        if let r = ps.restSeconds { record["restSeconds"] = Int64(r) as CKRecordValue }
        if let n = ps.notes { record["notes"] = n as CKRecordValue }
        if let d = parseDate(ps.updatedAt) { record["updatedAt"] = d as CKRecordValue }
        return record
    }

    func toCKRecord(_ ss: SessionSetRow, measurements: [SetMeasurementRow] = [], zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "SessionSet", recordID: CKRecord.ID(recordName: ss.id, zoneID: zoneID))
        record["sessionExerciseId"] = makeReference(recordName: ss.sessionExerciseId, zoneID: zoneID) as CKRecordValue
        record["orderIndex"] = Int64(ss.orderIndex) as CKRecordValue
        record["status"] = ss.status as CKRecordValue

        // Attributes
        var attrs: [String] = []
        if ss.isDropset != 0 { attrs.append("dropset") }
        if ss.isPerSide != 0 { attrs.append("perSide") }
        if ss.isAmrap != 0 { attrs.append("amrap") }
        if !attrs.isEmpty { record["attributes"] = attrs as CKRecordValue }

        // Write target/actual fields from measurements (dual-write for backward compat)
        writeMeasurementFields(from: measurements, to: record)

        setOptionalInt(on: record, key: "restSeconds", value: ss.restSeconds)
        setOptionalString(on: record, key: "notes", value: ss.notes)
        setOptionalString(on: record, key: "side", value: ss.side)
        setOptionalDate(on: record, key: "completedAt", isoString: ss.completedAt)
        setOptionalDate(on: record, key: "updatedAt", isoString: ss.updatedAt)
        return record
    }

    // MARK: - CKRecord Field Helpers

    func setOptionalString(on record: CKRecord, key: String, value: String?) {
        if let v = value { record[key] = v as CKRecordValue }
    }

    func setOptionalInt(on record: CKRecord, key: String, value: Int?) {
        if let v = value { record[key] = Int64(v) as CKRecordValue }
    }

    func setOptionalDate(on record: CKRecord, key: String, isoString: String?) {
        if let d = parseDate(isoString) { record[key] = d as CKRecordValue }
    }

    /// Write measurement fields onto a CKRecord for backward compatibility with older devices.
    /// Filters to groupIndex == 0 and writes prefixed fields (e.g., targetWeight, actualReps).
    func writeMeasurementFields(from measurements: [SetMeasurementRow], to record: CKRecord) {
        let groupZero = measurements.filter { $0.groupIndex == 0 }
        for m in groupZero {
            let prefix = m.role == "target" ? "target" : "actual"
            switch m.kind {
            case "weight":
                record["\(prefix)Weight"] = m.value as CKRecordValue
                if let u = m.unit { record["\(prefix)WeightUnit"] = u as CKRecordValue }
            case "reps":
                record["\(prefix)Reps"] = Int64(m.value) as CKRecordValue
            case "time":
                record["\(prefix)Time"] = Int64(m.value) as CKRecordValue
            case "distance":
                record["\(prefix)Distance"] = m.value as CKRecordValue
                if let u = m.unit { record["\(prefix)DistanceUnit"] = u as CKRecordValue }
            case "rpe":
                record["\(prefix)Rpe"] = m.value as CKRecordValue
            default: break
            }
        }
    }

    // MARK: - Merge SetMeasurement

    func mergeSetMeasurement(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let measurementId = record.recordID.recordName
            let existing = try SetMeasurementRow.fetchOne(db, key: measurementId)

            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }

            let setId = self.referenceId(record, "setId") ?? existing?.setId ?? ""
            if setId.isEmpty {
                Logger.shared.error(.sync, "[sync-merge] Skipping SetMeasurement \(measurementId): missing setId FK")
                return false
            }

            // Validate FK: setId must reference an existing session_set or template_set
            let parentType = self.stringField(record, "parentType") ?? existing?.parentType ?? "session"
            let fkTable = parentType == "planned" ? "template_sets" : "session_sets"
            let fkExists = try Row.fetchOne(db, sql: "SELECT 1 FROM \(fkTable) WHERE id = ?", arguments: [setId]) != nil
            if !fkExists && existing == nil {
                Logger.shared.error(.sync, "[sync-merge] Skipping SetMeasurement \(measurementId): setId \(setId) not found in \(fkTable)")
                return false
            }

            let row = SetMeasurementRow(
                id: measurementId,
                setId: setId,
                parentType: parentType,
                role: self.stringField(record, "role") ?? existing?.role ?? "actual",
                kind: self.stringField(record, "kind") ?? existing?.kind ?? "weight",
                value: self.doubleField(record, "value") ?? existing?.value ?? 0,
                unit: self.stringField(record, "unit") ?? existing?.unit,
                groupIndex: self.int64Field(record, "groupIndex").map { Int($0) } ?? existing?.groupIndex ?? 0,
                updatedAt: self.dateToISO(remoteUpdatedAt) ?? existing?.updatedAt
            )
            if existing != nil { try row.update(db) } else { try row.insert(db) }
            return true
        }
    }

    // MARK: - Insert Measurements from CKRecord

    /// Extract measurement fields from a CKRecord and insert into set_measurements.
    /// Handles old-format CKRecords that store target/actual fields directly on the set record.
    func insertMeasurementsFromCKRecord(
        _ record: CKRecord,
        setId: String,
        parentType: String,
        role: String,
        now: String?,
        in db: Database
    ) throws {
        let prefix = role == "target" ? "target" : "actual"

        if let w = doubleField(record, "\(prefix)Weight") {
            let unit = stringField(record, "\(prefix)WeightUnit")
            let mRow = SetMeasurementRow(
                id: IDGenerator.generate(), setId: setId, parentType: parentType,
                role: role, kind: "weight", value: w, unit: unit,
                groupIndex: 0, updatedAt: now
            )
            try mRow.insert(db)
        }
        if let r = int64Field(record, "\(prefix)Reps") {
            let mRow = SetMeasurementRow(
                id: IDGenerator.generate(), setId: setId, parentType: parentType,
                role: role, kind: "reps", value: Double(r), unit: nil,
                groupIndex: 0, updatedAt: now
            )
            try mRow.insert(db)
        }
        if let t = int64Field(record, "\(prefix)Time") {
            let mRow = SetMeasurementRow(
                id: IDGenerator.generate(), setId: setId, parentType: parentType,
                role: role, kind: "time", value: Double(t), unit: "s",
                groupIndex: 0, updatedAt: now
            )
            try mRow.insert(db)
        }
        if let d = doubleField(record, "\(prefix)Distance") {
            let unit = stringField(record, "\(prefix)DistanceUnit")
            let mRow = SetMeasurementRow(
                id: IDGenerator.generate(), setId: setId, parentType: parentType,
                role: role, kind: "distance", value: d, unit: unit,
                groupIndex: 0, updatedAt: now
            )
            try mRow.insert(db)
        }
        if let rpe = doubleField(record, "\(prefix)Rpe") {
            let mRow = SetMeasurementRow(
                id: IDGenerator.generate(), setId: setId, parentType: parentType,
                role: role, kind: "rpe", value: rpe, unit: nil,
                groupIndex: 0, updatedAt: now
            )
            try mRow.insert(db)
        } else if let rpe = int64Field(record, "\(prefix)Rpe") {
            let mRow = SetMeasurementRow(
                id: IDGenerator.generate(), setId: setId, parentType: parentType,
                role: role, kind: "rpe", value: Double(rpe), unit: nil,
                groupIndex: 0, updatedAt: now
            )
            try mRow.insert(db)
        }
    }
}

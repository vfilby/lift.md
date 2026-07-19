import CloudKit
import GRDB

// MARK: - SetMeasurement CKRecord Mapping & Merging

extension CKRecordMapper {

    // MARK: - To CKRecord

    func toCKRecord(_ measurement: SetMeasurementRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: "SetMeasurement",
            recordID: CKRecord.ID(recordName: measurement.id, zoneID: zoneID)
        )
        record["setId"] = makeReference(recordName: measurement.setId, zoneID: zoneID) as CKRecordValue
        record["parentType"] = measurement.parentType as CKRecordValue
        record["role"] = measurement.role as CKRecordValue
        record["kind"] = measurement.kind as CKRecordValue
        record["value"] = measurement.value as CKRecordValue
        if let unit = measurement.unit { record["unit"] = unit as CKRecordValue }
        record["groupIndex"] = Int64(measurement.groupIndex) as CKRecordValue
        if let date = parseDate(measurement.updatedAt) { record["updatedAt"] = date as CKRecordValue }
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

        if let rest = ps.restSeconds { record["restSeconds"] = Int64(rest) as CKRecordValue }
        if let notes = ps.notes { record["notes"] = notes as CKRecordValue }
        if let date = parseDate(ps.updatedAt) { record["updatedAt"] = date as CKRecordValue }
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
        if let value { record[key] = value as CKRecordValue }
    }

    func setOptionalInt(on record: CKRecord, key: String, value: Int?) {
        if let value { record[key] = Int64(value) as CKRecordValue }
    }

    func setOptionalDate(on record: CKRecord, key: String, isoString: String?) {
        if let date = parseDate(isoString) { record[key] = date as CKRecordValue }
    }

    /// Write measurement fields onto a CKRecord for backward compatibility with older devices.
    /// Filters to groupIndex == 0 and writes prefixed fields (e.g., targetWeight, actualReps).
    func writeMeasurementFields(from measurements: [SetMeasurementRow], to record: CKRecord) {
        let groupZero = measurements.filter { $0.groupIndex == 0 }
        for measurement in groupZero {
            let prefix = measurement.role == "target" ? "target" : "actual"
            switch measurement.kind {
            case "weight":
                record["\(prefix)Weight"] = measurement.value as CKRecordValue
                if let unit = measurement.unit { record["\(prefix)WeightUnit"] = unit as CKRecordValue }
            case "reps":
                record["\(prefix)Reps"] = Int64(measurement.value) as CKRecordValue
            case "time":
                record["\(prefix)Time"] = Int64(measurement.value) as CKRecordValue
            case "distance":
                record["\(prefix)Distance"] = measurement.value as CKRecordValue
                if let unit = measurement.unit { record["\(prefix)DistanceUnit"] = unit as CKRecordValue }
            case "rpe":
                record["\(prefix)Rpe"] = measurement.value as CKRecordValue
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
                Logger.shared.error(
                    .sync,
                    "[sync-merge] Skipping SetMeasurement \(measurementId): setId \(setId) not found in \(fkTable)"
                )
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

    // MARK: - Record Lookup

    /// Build a fresh CKRecord for a SetMeasurement row matching the given ID,
    /// or nil if no such row exists.
    func freshMeasurementRecord(id: String, zoneID: CKRecordZone.ID, db: Database) throws -> CKRecord? {
        guard let measurement = try SetMeasurementRow.fetchOne(db, key: id) else { return nil }
        return toCKRecord(measurement, zoneID: zoneID)
    }

    // MARK: - Insert Measurements from CKRecord

    /// Where extracted measurement rows attach: the owning set, its parent type
    /// ("planned"/"session"), the measurement role ("target"/"actual"), and the
    /// updatedAt timestamp to stamp on inserted rows.
    struct MeasurementMergeContext {
        let setId: String
        let parentType: String
        let role: String
        let now: String?
    }

    /// Extract measurement fields from a CKRecord and insert into set_measurements.
    /// Handles old-format CKRecords that store target/actual fields directly on the set record.
    func insertMeasurementsFromCKRecord(
        _ record: CKRecord,
        context: MeasurementMergeContext,
        in db: Database
    ) throws {
        let prefix = context.role == "target" ? "target" : "actual"

        if let weight = doubleField(record, "\(prefix)Weight") {
            let unit = stringField(record, "\(prefix)WeightUnit")
            try insertMeasurement(kind: "weight", value: weight, unit: unit, context: context, in: db)
        }
        if let reps = int64Field(record, "\(prefix)Reps") {
            try insertMeasurement(kind: "reps", value: Double(reps), unit: nil, context: context, in: db)
        }
        if let time = int64Field(record, "\(prefix)Time") {
            try insertMeasurement(kind: "time", value: Double(time), unit: "s", context: context, in: db)
        }
        if let distance = doubleField(record, "\(prefix)Distance") {
            let unit = stringField(record, "\(prefix)DistanceUnit")
            try insertMeasurement(kind: "distance", value: distance, unit: unit, context: context, in: db)
        }
        if let rpe = doubleField(record, "\(prefix)Rpe") {
            try insertMeasurement(kind: "rpe", value: rpe, unit: nil, context: context, in: db)
        } else if let rpe = int64Field(record, "\(prefix)Rpe") {
            try insertMeasurement(kind: "rpe", value: Double(rpe), unit: nil, context: context, in: db)
        }
    }

    /// Insert a single set_measurements row (groupIndex 0) at the given destination.
    private func insertMeasurement(
        kind: String,
        value: Double,
        unit: String?,
        context: MeasurementMergeContext,
        in db: Database
    ) throws {
        let mRow = SetMeasurementRow(
            id: IDGenerator.generate(), setId: context.setId, parentType: context.parentType,
            role: context.role, kind: kind, value: value, unit: unit,
            groupIndex: 0, updatedAt: context.now
        )
        try mRow.insert(db)
    }
}

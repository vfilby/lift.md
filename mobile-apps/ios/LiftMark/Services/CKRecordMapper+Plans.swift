import CloudKit
import GRDB

// MARK: - WorkoutPlan, PlannedExercise & PlannedSet CKRecord Mapping & Merging

extension CKRecordMapper {

    // MARK: - To CKRecord

    func toCKRecord(_ plan: WorkoutPlanRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "WorkoutPlan", recordID: CKRecord.ID(recordName: plan.id, zoneID: zoneID))
        record["name"] = plan.name as CKRecordValue
        record["isFavorite"] = Int64(plan.isFavorite) as CKRecordValue
        if let description = plan.description { record["planDescription"] = description as CKRecordValue }
        if let tags = plan.tags { record["tags"] = tags as CKRecordValue }
        if let unit = plan.defaultWeightUnit { record["defaultWeightUnit"] = unit as CKRecordValue }
        if let markdown = plan.sourceMarkdown { record["sourceMarkdown"] = markdown as CKRecordValue }
        if let date = parseDate(plan.createdAt) { record["createdAt"] = date as CKRecordValue }
        if let date = parseDate(plan.updatedAt) { record["updatedAt"] = date as CKRecordValue }
        return record
    }

    func toCKRecord(_ ex: PlannedExerciseRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "PlannedExercise", recordID: CKRecord.ID(recordName: ex.id, zoneID: zoneID))
        record["workoutPlanId"] = makeReference(recordName: ex.workoutTemplateId, zoneID: zoneID) as CKRecordValue
        record["exerciseName"] = ex.exerciseName as CKRecordValue
        record["orderIndex"] = Int64(ex.orderIndex) as CKRecordValue
        if let notes = ex.notes { record["notes"] = notes as CKRecordValue }
        if let equipmentType = ex.equipmentType { record["equipmentType"] = equipmentType as CKRecordValue }
        if let groupType = ex.groupType { record["groupType"] = groupType as CKRecordValue }
        if let groupName = ex.groupName { record["groupName"] = groupName as CKRecordValue }
        if let parentId = ex.parentExerciseId {
            record["parentExerciseId"] = makeReference(recordName: parentId, zoneID: zoneID) as CKRecordValue
        }
        if let date = parseDate(ex.updatedAt) { record["updatedAt"] = date as CKRecordValue }
        return record
    }

    // MARK: - Merge Routing

    /// Routes an incoming plan-tier CKRecord (WorkoutPlan, PlannedExercise, PlannedSet) to its merge method.
    func mergePlanRecord(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        switch record.recordType {
        case "WorkoutPlan":
            return try mergeWorkoutPlan(record, dbQueue: dbQueue)
        case "PlannedExercise":
            return try mergePlannedExercise(record, dbQueue: dbQueue)
        case "PlannedSet":
            return try mergePlannedSet(record, dbQueue: dbQueue)
        default:
            return logUnknownRecordType(record)
        }
    }

    // MARK: - Merge Methods

    private func mergeWorkoutPlan(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let existing = try WorkoutPlanRow.fetchOne(db, key: record.recordID.recordName)
            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }
            let row = WorkoutPlanRow(
                id: record.recordID.recordName,
                name: self.stringField(record, "name") ?? "Workout",
                description: self.stringField(record, "planDescription"),
                tags: self.stringField(record, "tags"),
                defaultWeightUnit: self.stringField(record, "defaultWeightUnit"),
                sourceMarkdown: self.stringField(record, "sourceMarkdown"),
                createdAt: self.dateToISO(self.dateField(record, "createdAt")) ?? existing?.createdAt
                    ?? self.isoFormatter.string(from: Date()),
                updatedAt: self.dateToISO(remoteUpdatedAt) ?? existing?.updatedAt
                    ?? self.isoFormatter.string(from: Date()),
                isFavorite: Int(self.int64Field(record, "isFavorite") ?? 0)
            )
            if existing != nil { try row.update(db) } else { try row.insert(db) }
            return true
        }
    }

    private func mergePlannedExercise(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let existing = try PlannedExerciseRow.fetchOne(db, key: record.recordID.recordName)
            let fk = self.referenceId(record, "workoutPlanId") ?? existing?.workoutTemplateId ?? ""
            if fk.isEmpty && existing == nil {
                Logger.shared.error(
                    .sync,
                    "[sync-merge] Skipping PlannedExercise \(record.recordID.recordName): missing workoutPlanId FK"
                )
                return false
            }

            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }

            let row = PlannedExerciseRow(
                id: record.recordID.recordName,
                workoutTemplateId: fk,
                exerciseName: self.stringField(record, "exerciseName") ?? existing?.exerciseName ?? "",
                orderIndex: Int(self.int64Field(record, "orderIndex") ?? Int64(existing?.orderIndex ?? 0)),
                notes: self.stringField(record, "notes"),
                equipmentType: self.stringField(record, "equipmentType"),
                groupType: self.stringField(record, "groupType"),
                groupName: self.stringField(record, "groupName"),
                parentExerciseId: self.referenceId(record, "parentExerciseId"),
                updatedAt: self.dateToISO(remoteUpdatedAt) ?? existing?.updatedAt
            )
            if existing != nil {
                try row.update(db)
            } else {
                let duplicate = try PlannedExerciseRow
                    .filter(Column("workout_template_id") == row.workoutTemplateId)
                    .filter(Column("exercise_name") == row.exerciseName)
                    .filter(Column("order_index") == row.orderIndex)
                    .fetchOne(db)
                if duplicate != nil {
                    Logger.shared.warn(
                        .sync,
                        "Skipping duplicate exercise: \(row.exerciseName) at index \(row.orderIndex)"
                    )
                    return false
                }
                try row.insert(db)
            }
            return true
        }
    }

    private func mergePlannedSet(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let setId = record.recordID.recordName
            let existing = try PlannedSetRow.fetchOne(db, key: setId)
            let fk = self.referenceId(record, "plannedExerciseId") ?? existing?.templateExerciseId ?? ""
            if fk.isEmpty && existing == nil {
                Logger.shared.error(.sync, "[sync-merge] Skipping PlannedSet \(setId): missing plannedExerciseId FK")
                return false
            }

            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }

            let attrs = self.stringListField(record, "attributes")
            let now = self.dateToISO(remoteUpdatedAt) ?? existing?.updatedAt
            let row = PlannedSetRow(
                id: setId,
                templateExerciseId: fk,
                orderIndex: Int(self.int64Field(record, "orderIndex") ?? Int64(existing?.orderIndex ?? 0)),
                restSeconds: self.int64Field(record, "restSeconds").map { Int($0) },
                isDropset: attrs.contains("dropset") ? 1 : 0,
                isPerSide: attrs.contains("perSide") ? 1 : 0,
                isAmrap: attrs.contains("amrap") ? 1 : 0,
                notes: self.stringField(record, "notes"),
                updatedAt: now
            )
            if existing != nil {
                try row.update(db)
            } else {
                let duplicate = try PlannedSetRow
                    .filter(Column("template_exercise_id") == row.templateExerciseId)
                    .filter(Column("order_index") == row.orderIndex)
                    .fetchOne(db)
                if duplicate != nil {
                    Logger.shared.warn(.sync, "Skipping duplicate set at index \(row.orderIndex)")
                    return false
                }
                try row.insert(db)
            }

            // Replace measurements from CK record fields (dual-read: old-format CKRecords)
            try db.execute(
                sql: "DELETE FROM set_measurements WHERE set_id = ? AND parent_type = 'planned'",
                arguments: [setId]
            )
            try self.insertMeasurementsFromCKRecord(
                record,
                context: MeasurementMergeContext(setId: setId, parentType: "planned", role: "target", now: now),
                in: db
            )

            return true
        }
    }

    // MARK: - Record Lookup

    /// Build a fresh CKRecord for a plan-tier row (WorkoutPlan, PlannedExercise, PlannedSet)
    /// matching the given ID, or nil if no such row exists.
    func freshPlanTierRecord(id: String, zoneID: CKRecordZone.ID, db: Database) throws -> CKRecord? {
        if let plan = try WorkoutPlanRow.fetchOne(db, key: id) {
            return toCKRecord(plan, zoneID: zoneID)
        }
        if let ex = try PlannedExerciseRow.fetchOne(db, key: id) {
            return toCKRecord(ex, zoneID: zoneID)
        }
        if let ps = try PlannedSetRow.fetchOne(db, key: id) {
            let measurements = try SetMeasurementRow
                .filter(Column("set_id") == id)
                .filter(Column("parent_type") == "planned")
                .fetchAll(db)
            return toCKRecord(ps, measurements: measurements, zoneID: zoneID)
        }
        return nil
    }
}

import CloudKit
import GRDB

// MARK: - WorkoutSession, SessionExercise & SessionSet CKRecord Mapping & Merging

extension CKRecordMapper {

    // MARK: - To CKRecord

    func toCKRecord(_ session: WorkoutSessionRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "WorkoutSession", recordID: CKRecord.ID(recordName: session.id, zoneID: zoneID))
        record["name"] = session.name as CKRecordValue
        record["date"] = session.date as CKRecordValue
        record["status"] = session.status as CKRecordValue
        if let pid = session.workoutTemplateId { record["workoutPlanId"] = pid as CKRecordValue }
        if let date = parseDate(session.startTime) { record["startTime"] = date as CKRecordValue }
        if let date = parseDate(session.endTime) { record["endTime"] = date as CKRecordValue }
        if let dur = session.duration { record["duration"] = Int64(dur) as CKRecordValue }
        if let notes = session.notes { record["notes"] = notes as CKRecordValue }
        if let date = parseDate(session.updatedAt) { record["updatedAt"] = date as CKRecordValue }
        return record
    }

    func toCKRecord(_ se: SessionExerciseRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: "SessionExercise", recordID: CKRecord.ID(recordName: se.id, zoneID: zoneID))
        record["workoutSessionId"] = makeReference(recordName: se.workoutSessionId, zoneID: zoneID) as CKRecordValue
        record["exerciseName"] = se.exerciseName as CKRecordValue
        record["orderIndex"] = Int64(se.orderIndex) as CKRecordValue
        record["status"] = se.status as CKRecordValue
        if let notes = se.notes { record["notes"] = notes as CKRecordValue }
        if let equipmentType = se.equipmentType { record["equipmentType"] = equipmentType as CKRecordValue }
        if let groupType = se.groupType { record["groupType"] = groupType as CKRecordValue }
        if let groupName = se.groupName { record["groupName"] = groupName as CKRecordValue }
        if let parentId = se.parentExerciseId {
            record["parentExerciseId"] = makeReference(recordName: parentId, zoneID: zoneID) as CKRecordValue
        }
        if let date = parseDate(se.updatedAt) { record["updatedAt"] = date as CKRecordValue }
        return record
    }

    // MARK: - Merge Routing

    /// Routes an incoming session-tier CKRecord (WorkoutSession, SessionExercise, SessionSet) to its merge method.
    func mergeSessionRecord(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        switch record.recordType {
        case "WorkoutSession":
            return try mergeWorkoutSession(record, dbQueue: dbQueue)
        case "SessionExercise":
            return try mergeSessionExercise(record, dbQueue: dbQueue)
        case "SessionSet":
            return try mergeSessionSet(record, dbQueue: dbQueue)
        default:
            return logUnknownRecordType(record)
        }
    }

    // MARK: - Merge Methods

    private func mergeWorkoutSession(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let existing = try WorkoutSessionRow.fetchOne(db, key: record.recordID.recordName)

            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }

            // Don't let remote data overwrite a local cancellation
            let remoteStatus = self.stringField(record, "status")
            let mergedStatus: String
            if existing?.status == SessionStatus.canceled.rawValue {
                mergedStatus = SessionStatus.canceled.rawValue
            } else {
                mergedStatus = remoteStatus ?? existing?.status ?? SessionStatus.inProgress.rawValue
            }

            let row = WorkoutSessionRow(
                id: record.recordID.recordName,
                workoutTemplateId: self.stringField(record, "workoutPlanId"),
                name: self.stringField(record, "name") ?? existing?.name ?? "Workout",
                date: self.stringField(record, "date") ?? existing?.date ?? "",
                startTime: self.dateToISO(self.dateField(record, "startTime")),
                endTime: self.dateToISO(self.dateField(record, "endTime")),
                duration: self.int64Field(record, "duration").map { Int($0) },
                notes: self.stringField(record, "notes"),
                status: mergedStatus,
                updatedAt: self.dateToISO(remoteUpdatedAt) ?? existing?.updatedAt
            )
            if existing != nil { try row.update(db) } else { try row.insert(db) }
            return true
        }
    }

    private func mergeSessionExercise(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let existing = try SessionExerciseRow.fetchOne(db, key: record.recordID.recordName)
            let fk = self.referenceId(record, "workoutSessionId") ?? existing?.workoutSessionId ?? ""
            if fk.isEmpty && existing == nil {
                Logger.shared.error(
                    .sync,
                    "[sync-merge] Skipping SessionExercise \(record.recordID.recordName): missing workoutSessionId FK"
                )
                return false
            }

            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }

            let row = SessionExerciseRow(
                id: record.recordID.recordName,
                workoutSessionId: fk,
                exerciseName: self.stringField(record, "exerciseName") ?? existing?.exerciseName ?? "",
                orderIndex: Int(self.int64Field(record, "orderIndex") ?? Int64(existing?.orderIndex ?? 0)),
                notes: self.stringField(record, "notes"),
                equipmentType: self.stringField(record, "equipmentType"),
                groupType: self.stringField(record, "groupType"),
                groupName: self.stringField(record, "groupName"),
                parentExerciseId: self.referenceId(record, "parentExerciseId"),
                status: self.stringField(record, "status") ?? existing?.status ?? ExerciseStatus.pending.rawValue,
                updatedAt: self.dateToISO(remoteUpdatedAt) ?? existing?.updatedAt
            )
            if existing != nil { try row.update(db) } else { try row.insert(db) }
            return true
        }
    }

    private func mergeSessionSet(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let setId = record.recordID.recordName
            let existing = try SessionSetRow.fetchOne(db, key: setId)
            let fk = self.referenceId(record, "sessionExerciseId") ?? existing?.sessionExerciseId ?? ""
            if fk.isEmpty && existing == nil {
                Logger.shared.error(.sync, "[sync-merge] Skipping SessionSet \(setId): missing sessionExerciseId FK")
                return false
            }

            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }

            let attrs = self.stringListField(record, "attributes")
            let now = self.dateToISO(remoteUpdatedAt) ?? existing?.updatedAt
            let row = SessionSetRow(
                id: setId,
                sessionExerciseId: fk,
                orderIndex: Int(self.int64Field(record, "orderIndex") ?? Int64(existing?.orderIndex ?? 0)),
                restSeconds: self.int64Field(record, "restSeconds").map { Int($0) },
                completedAt: self.dateToISO(self.dateField(record, "completedAt")),
                status: self.stringField(record, "status") ?? existing?.status ?? SetStatus.pending.rawValue,
                notes: self.stringField(record, "notes"),
                isDropset: attrs.contains("dropset") ? 1 : 0,
                isPerSide: attrs.contains("perSide") ? 1 : 0,
                isAmrap: attrs.contains("amrap") ? 1 : 0,
                side: self.stringField(record, "side"),
                updatedAt: now
            )
            if existing != nil { try row.update(db) } else { try row.insert(db) }

            // Replace measurements from CK record fields (dual-read: old-format CKRecords)
            try db.execute(
                sql: "DELETE FROM set_measurements WHERE set_id = ? AND parent_type = 'session'",
                arguments: [setId]
            )
            try self.insertMeasurementsFromCKRecord(
                record,
                context: MeasurementMergeContext(setId: setId, parentType: "session", role: "target", now: now),
                in: db
            )
            try self.insertMeasurementsFromCKRecord(
                record,
                context: MeasurementMergeContext(setId: setId, parentType: "session", role: "actual", now: now),
                in: db
            )

            return true
        }
    }

    // MARK: - Record Lookup

    /// Build a fresh CKRecord for a session-tier row (WorkoutSession, SessionExercise, SessionSet)
    /// matching the given ID, or nil if no such row exists.
    func freshSessionTierRecord(id: String, zoneID: CKRecordZone.ID, db: Database) throws -> CKRecord? {
        if let session = try WorkoutSessionRow.fetchOne(db, key: id) {
            return toCKRecord(session, zoneID: zoneID)
        }
        if let se = try SessionExerciseRow.fetchOne(db, key: id) {
            return toCKRecord(se, zoneID: zoneID)
        }
        if let ss = try SessionSetRow.fetchOne(db, key: id) {
            let measurements = try SetMeasurementRow
                .filter(Column("set_id") == id)
                .filter(Column("parent_type") == "session")
                .fetchAll(db)
            return toCKRecord(ss, measurements: measurements, zoneID: zoneID)
        }
        return nil
    }
}

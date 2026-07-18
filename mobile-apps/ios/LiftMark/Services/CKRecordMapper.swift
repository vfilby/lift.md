import CloudKit
import GRDB

/// Handles conversion between GRDB row types and CKRecords, plus merging incoming
/// CKRecords into the local database. Extracted from CloudKitService to support the
/// CKSyncEngine migration.
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

    private func stringListField(_ record: CKRecord, _ key: String) -> [String] {
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
                let recordName = record.recordID.recordName
                let remoteDate = self.dateField(record, "updatedAt")

                // Look up the local updatedAt based on record type
                let localUpdatedAt: String? = try {
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
                }()

                return self.remoteIsNewer(remoteDate: remoteDate, localUpdatedAt: localUpdatedAt)
            }
        } catch {
            // If we can't read the local DB, default to server wins
            Logger.shared.error(.sync, "Failed to read local record for conflict check: \(error.localizedDescription)")
            return true
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

    func toCKRecord(_ settings: UserSettingsRow, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(
            recordType: "UserSettings",
            recordID: CKRecord.ID(recordName: "user-settings", zoneID: zoneID)
        )
        record["defaultWeightUnit"] = settings.defaultWeightUnit as CKRecordValue
        record["enableWorkoutTimer"] = Int64(settings.enableWorkoutTimer) as CKRecordValue
        record["autoStartRestTimer"] = Int64(settings.autoStartRestTimer) as CKRecordValue
        record["theme"] = settings.theme as CKRecordValue
        record["notificationsEnabled"] = Int64(settings.notificationsEnabled) as CKRecordValue
        record["healthKitEnabled"] = Int64(settings.healthkitEnabled) as CKRecordValue
        record["liveActivitiesEnabled"] = Int64(settings.liveActivitiesEnabled) as CKRecordValue
        record["keepScreenAwake"] = Int64(settings.keepScreenAwake) as CKRecordValue
        record["showOpenInClaudeButton"] = Int64(settings.showOpenInClaudeButton) as CKRecordValue
        record["countdownSoundsEnabled"] = Int64(settings.countdownSoundsEnabled) as CKRecordValue
        record["defaultTimerCountdown"] = Int64(settings.defaultTimerCountdown) as CKRecordValue
        record["defaultWeightStepLbs"] = settings.defaultWeightStepLbs as CKRecordValue
        record["aiPromptIncludeFormatPointer"] = Int64(settings.aiPromptIncludeFormatPointer) as CKRecordValue
        record["aiPromptIncludeRecentWorkouts"] = Int64(settings.aiPromptIncludeRecentWorkouts) as CKRecordValue
        record["aiPromptIncludeProgression"] = Int64(settings.aiPromptIncludeProgression) as CKRecordValue
        record["aiPromptIncludeEquipment"] = Int64(settings.aiPromptIncludeEquipment) as CKRecordValue
        if let addition = settings.customPromptAddition {
            record["customPromptAddition"] = addition as CKRecordValue
        }
        if let tiles = settings.homeTiles { record["homeTiles"] = tiles as CKRecordValue }
        if let date = parseDate(settings.updatedAt) { record["updatedAt"] = date as CKRecordValue }
        // Never sync anthropicApiKey
        return record
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
        case "Gym":
            return try mergeGym(record, dbQueue: dbQueue)
        case "GymEquipment":
            return try mergeGymEquipment(record, dbQueue: dbQueue)
        case "WorkoutPlan":
            return try mergeWorkoutPlan(record, dbQueue: dbQueue)
        case "PlannedExercise":
            return try mergePlannedExercise(record, dbQueue: dbQueue)
        case "PlannedSet":
            return try mergePlannedSet(record, dbQueue: dbQueue)
        case "WorkoutSession":
            return try mergeWorkoutSession(record, dbQueue: dbQueue)
        case "SessionExercise":
            return try mergeSessionExercise(record, dbQueue: dbQueue)
        case "SessionSet":
            return try mergeSessionSet(record, dbQueue: dbQueue)
        case "UserSettings":
            return try mergeUserSettings(record, dbQueue: dbQueue)
        case "SetMeasurement":
            return try mergeSetMeasurement(record, dbQueue: dbQueue)
        default:
            Logger.shared.warn(.sync, "Unknown record type for merge: \(record.recordType)")
            return false
        }
    }

    // MARK: - Individual Merge Methods

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
                record, setId: setId, parentType: "planned", role: "target", now: now, in: db
            )

            return true
        }
    }

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
                record, setId: setId, parentType: "session", role: "target", now: now, in: db
            )
            try self.insertMeasurementsFromCKRecord(
                record, setId: setId, parentType: "session", role: "actual", now: now, in: db
            )

            return true
        }
    }

    private func mergeUserSettings(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let existing = try UserSettingsRow.fetchOne(db)
            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }
            if let existing {
                let updatedAt = self.dateToISO(remoteUpdatedAt) ?? existing.updatedAt
                let row = UserSettingsRow(
                    id: existing.id,
                    defaultWeightUnit: self.stringField(record, "defaultWeightUnit") ?? existing.defaultWeightUnit,
                    enableWorkoutTimer: Int(self.int64Field(record, "enableWorkoutTimer")
                        ?? Int64(existing.enableWorkoutTimer)),
                    autoStartRestTimer: Int(self.int64Field(record, "autoStartRestTimer")
                        ?? Int64(existing.autoStartRestTimer)),
                    theme: self.stringField(record, "theme") ?? existing.theme,
                    notificationsEnabled: Int(self.int64Field(record, "notificationsEnabled")
                        ?? Int64(existing.notificationsEnabled)),
                    customPromptAddition: self.stringField(record, "customPromptAddition")
                        ?? existing.customPromptAddition,
                    anthropicApiKeyStatus: existing.anthropicApiKeyStatus, // Never sync
                    healthkitEnabled: Int(self.int64Field(record, "healthKitEnabled")
                        ?? Int64(existing.healthkitEnabled)),
                    liveActivitiesEnabled: Int(self.int64Field(record, "liveActivitiesEnabled")
                        ?? Int64(existing.liveActivitiesEnabled)),
                    keepScreenAwake: Int(self.int64Field(record, "keepScreenAwake") ?? Int64(existing.keepScreenAwake)),
                    showOpenInClaudeButton: Int(self.int64Field(record, "showOpenInClaudeButton")
                        ?? Int64(existing.showOpenInClaudeButton)),
                    developerModeEnabled: existing.developerModeEnabled,
                    countdownSoundsEnabled: Int(self.int64Field(record, "countdownSoundsEnabled")
                        ?? Int64(existing.countdownSoundsEnabled)),
                    hasAcceptedDisclaimer: existing.hasAcceptedDisclaimer, // Never sync — local-only
                    defaultTimerCountdown: Int(self.int64Field(record, "defaultTimerCountdown")
                        ?? Int64(existing.defaultTimerCountdown)),
                    defaultWeightStepLbs: self.doubleField(record, "defaultWeightStepLbs")
                        ?? existing.defaultWeightStepLbs,
                    aiPromptIncludeFormatPointer: Int(self.int64Field(record, "aiPromptIncludeFormatPointer")
                        ?? Int64(existing.aiPromptIncludeFormatPointer)),
                    aiPromptIncludeRecentWorkouts: Int(self.int64Field(record, "aiPromptIncludeRecentWorkouts")
                        ?? Int64(existing.aiPromptIncludeRecentWorkouts)),
                    aiPromptIncludeProgression: Int(self.int64Field(record, "aiPromptIncludeProgression")
                        ?? Int64(existing.aiPromptIncludeProgression)),
                    aiPromptIncludeEquipment: Int(self.int64Field(record, "aiPromptIncludeEquipment")
                        ?? Int64(existing.aiPromptIncludeEquipment)),
                    homeTiles: self.stringField(record, "homeTiles") ?? existing.homeTiles,
                    createdAt: existing.createdAt,
                    updatedAt: updatedAt
                )
                try row.update(db)
                return true
            } else {
                let now = self.isoFormatter.string(from: Date())
                let row = UserSettingsRow(
                    id: IDGenerator.generate(),
                    defaultWeightUnit: self.stringField(record, "defaultWeightUnit") ?? "lbs",
                    enableWorkoutTimer: Int(self.int64Field(record, "enableWorkoutTimer") ?? 1),
                    autoStartRestTimer: Int(self.int64Field(record, "autoStartRestTimer") ?? 1),
                    theme: self.stringField(record, "theme") ?? "auto",
                    notificationsEnabled: Int(self.int64Field(record, "notificationsEnabled") ?? 1),
                    customPromptAddition: self.stringField(record, "customPromptAddition"),
                    anthropicApiKeyStatus: "not_set",
                    healthkitEnabled: Int(self.int64Field(record, "healthKitEnabled") ?? 0),
                    liveActivitiesEnabled: Int(self.int64Field(record, "liveActivitiesEnabled") ?? 1),
                    keepScreenAwake: Int(self.int64Field(record, "keepScreenAwake") ?? 1),
                    showOpenInClaudeButton: Int(self.int64Field(record, "showOpenInClaudeButton") ?? 0),
                    developerModeEnabled: 0,
                    countdownSoundsEnabled: Int(self.int64Field(record, "countdownSoundsEnabled") ?? 1),
                    hasAcceptedDisclaimer: 0, // New device — must accept again
                    defaultTimerCountdown: Int(self.int64Field(record, "defaultTimerCountdown") ?? 0),
                    defaultWeightStepLbs: self.doubleField(record, "defaultWeightStepLbs") ?? 2.5,
                    aiPromptIncludeFormatPointer: Int(self.int64Field(record, "aiPromptIncludeFormatPointer") ?? 1),
                    aiPromptIncludeRecentWorkouts: Int(self.int64Field(record, "aiPromptIncludeRecentWorkouts") ?? 1),
                    aiPromptIncludeProgression: Int(self.int64Field(record, "aiPromptIncludeProgression") ?? 1),
                    aiPromptIncludeEquipment: Int(self.int64Field(record, "aiPromptIncludeEquipment") ?? 1),
                    homeTiles: self.stringField(record, "homeTiles"),
                    createdAt: now,
                    updatedAt: self.dateToISO(remoteUpdatedAt) ?? now
                )
                try row.insert(db)
                return true
            }
        }
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
                if let gym = try GymRow.fetchOne(db, key: id) {
                    if gym.deletedAt != nil { return nil }
                    return self.toCKRecord(gym, zoneID: zoneID)
                }
                if let eq = try GymEquipmentRow.fetchOne(db, key: id) {
                    if eq.deletedAt != nil { return nil }
                    return self.toCKRecord(eq, zoneID: zoneID)
                }
                if let plan = try WorkoutPlanRow.fetchOne(db, key: id) {
                    return self.toCKRecord(plan, zoneID: zoneID)
                }
                if let ex = try PlannedExerciseRow.fetchOne(db, key: id) {
                    return self.toCKRecord(ex, zoneID: zoneID)
                }
                if let ps = try PlannedSetRow.fetchOne(db, key: id) {
                    let measurements = try SetMeasurementRow
                        .filter(Column("set_id") == id)
                        .filter(Column("parent_type") == "planned")
                        .fetchAll(db)
                    return self.toCKRecord(ps, measurements: measurements, zoneID: zoneID)
                }
                if let session = try WorkoutSessionRow.fetchOne(db, key: id) {
                    return self.toCKRecord(session, zoneID: zoneID)
                }
                if let se = try SessionExerciseRow.fetchOne(db, key: id) {
                    return self.toCKRecord(se, zoneID: zoneID)
                }
                if let ss = try SessionSetRow.fetchOne(db, key: id) {
                    let measurements = try SetMeasurementRow
                        .filter(Column("set_id") == id)
                        .filter(Column("parent_type") == "session")
                        .fetchAll(db)
                    return self.toCKRecord(ss, measurements: measurements, zoneID: zoneID)
                }
                if let settings = try UserSettingsRow.fetchOne(db) {
                    if settings.id == id || id == "user-settings" {
                        return self.toCKRecord(settings, zoneID: zoneID)
                    }
                }
                if let measurement = try SetMeasurementRow.fetchOne(db, key: id) {
                    return self.toCKRecord(measurement, zoneID: zoneID)
                }
                return nil
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

    // MARK: - Active Session Protection

    /// IDs belonging to an in-progress workout session that must not be deleted or overwritten by sync.
    struct ActiveSessionProtectedIds {
        let sessionId: String?
        let exerciseIds: Set<String>
        let setIds: Set<String>
        let planId: String?
        let plannedExerciseIds: Set<String>
        let plannedSetIds: Set<String>

        /// All protected IDs keyed by CloudKit record type.
        var byRecordType: [String: Set<String>] {
            var map: [String: Set<String>] = [:]
            if let sid = sessionId { map["WorkoutSession"] = [sid] }
            if !exerciseIds.isEmpty { map["SessionExercise"] = exerciseIds }
            if !setIds.isEmpty { map["SessionSet"] = setIds }
            if let pid = planId { map["WorkoutPlan"] = [pid] }
            if !plannedExerciseIds.isEmpty { map["PlannedExercise"] = plannedExerciseIds }
            if !plannedSetIds.isEmpty { map["PlannedSet"] = plannedSetIds }
            return map
        }

        static let empty = ActiveSessionProtectedIds(
            sessionId: nil, exerciseIds: [], setIds: [],
            planId: nil, plannedExerciseIds: [], plannedSetIds: []
        )
    }

    /// Query the database for the active (in_progress) session and collect all IDs that belong to it,
    /// including the parent WorkoutPlan's PlannedExercise and PlannedSet records.
    func getActiveSessionProtectedIds() -> ActiveSessionProtectedIds {
        do {
            let dbQueue = try dbManager.database()
            return try dbQueue.read { db in
                guard let sessionRow = try Row.fetchOne(
                    db,
                    sql: "SELECT id, workout_template_id FROM workout_sessions WHERE status = 'in_progress' LIMIT 1"
                ),
                      let sessionId: String = sessionRow["id"] else {
                    return .empty
                }

                let exSql = "SELECT id FROM session_exercises WHERE workout_session_id = ?"
                let exerciseRows = try Row.fetchAll(db, sql: exSql, arguments: [sessionId])
                let exerciseIds = Set(exerciseRows.compactMap { $0["id"] as String? })

                var setIds = Set<String>()
                if !exerciseIds.isEmpty {
                    let placeholders = exerciseIds.map { _ in "?" }.joined(separator: ",")
                    let setSql = "SELECT id FROM session_sets WHERE session_exercise_id IN (\(placeholders))"
                    let setRows = try Row.fetchAll(db, sql: setSql, arguments: StatementArguments(Array(exerciseIds)))
                    setIds = Set(setRows.compactMap { $0["id"] as String? })
                }

                let planId: String? = sessionRow["workout_template_id"]
                var plannedExerciseIds = Set<String>()
                var plannedSetIds = Set<String>()

                if let planId, !planId.isEmpty {
                    let peSql = "SELECT id FROM template_exercises WHERE workout_template_id = ?"
                    let peRows = try Row.fetchAll(db, sql: peSql, arguments: [planId])
                    plannedExerciseIds = Set(peRows.compactMap { $0["id"] as String? })

                    if !plannedExerciseIds.isEmpty {
                        let pePlaceholders = plannedExerciseIds.map { _ in "?" }.joined(separator: ",")
                        let psRows = try Row.fetchAll(
                            db,
                            sql: "SELECT id FROM template_sets "
                                + "WHERE template_exercise_id IN (\(pePlaceholders))",
                            arguments: StatementArguments(Array(plannedExerciseIds))
                        )
                        plannedSetIds = Set(psRows.compactMap { $0["id"] as String? })
                    }
                }

                return ActiveSessionProtectedIds(
                    sessionId: sessionId, exerciseIds: exerciseIds, setIds: setIds,
                    planId: planId, plannedExerciseIds: plannedExerciseIds, plannedSetIds: plannedSetIds
                )
            }
        } catch {
            Logger.shared.error(.app, "Failed to query active session for sync protection", error: error)
            return .empty
        }
    }
}

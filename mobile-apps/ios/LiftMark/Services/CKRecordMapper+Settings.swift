import CloudKit
import GRDB

// MARK: - UserSettings CKRecord Mapping & Merging

extension CKRecordMapper {

    // MARK: - To CKRecord

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

    // MARK: - Merge

    func mergeUserSettings(_ record: CKRecord, dbQueue: DatabaseQueue) throws -> Bool {
        let remoteUpdatedAt = dateField(record, "updatedAt")
        return try dbQueue.write { db in
            let existing = try UserSettingsRow.fetchOne(db)
            if let existing, !self.remoteIsNewer(remoteDate: remoteUpdatedAt, localUpdatedAt: existing.updatedAt) {
                return false
            }
            if let existing {
                let row = self.mergedSettingsRow(from: record, existing: existing, remoteUpdatedAt: remoteUpdatedAt)
                try row.update(db)
                return true
            } else {
                let row = self.freshSettingsRow(from: record, remoteUpdatedAt: remoteUpdatedAt)
                try row.insert(db)
                return true
            }
        }
    }

    /// Build the merged UserSettingsRow when a local row already exists — remote fields win
    /// where present, local values are kept otherwise. Local-only fields are never synced.
    private func mergedSettingsRow(
        from record: CKRecord,
        existing: UserSettingsRow,
        remoteUpdatedAt: Date?
    ) -> UserSettingsRow {
        let updatedAt = self.dateToISO(remoteUpdatedAt) ?? existing.updatedAt
        return UserSettingsRow(
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
    }

    /// Build a brand-new UserSettingsRow from a remote record when no local row exists yet.
    /// Local-only fields get new-device defaults.
    private func freshSettingsRow(from record: CKRecord, remoteUpdatedAt: Date?) -> UserSettingsRow {
        let now = self.isoFormatter.string(from: Date())
        return UserSettingsRow(
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
    }

    // MARK: - Record Lookup

    /// Build a fresh CKRecord for the singleton UserSettings row if the given ID addresses it,
    /// or nil otherwise.
    func freshSettingsRecord(id: String, zoneID: CKRecordZone.ID, db: Database) throws -> CKRecord? {
        if let settings = try UserSettingsRow.fetchOne(db) {
            if settings.id == id || id == "user-settings" {
                return toCKRecord(settings, zoneID: zoneID)
            }
        }
        return nil
    }
}

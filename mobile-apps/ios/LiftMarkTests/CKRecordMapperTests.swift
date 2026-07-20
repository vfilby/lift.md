import XCTest
import CloudKit
import GRDB
@testable import LiftMark

/// Tests for CKRecordMapper: roundtrip conversions, merge logic, dependency ordering,
/// and active session protection.
final class CKRecordMapperTests: XCTestCase {

    private var mapper: CKRecordMapper!
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        // Force Logger initialization before any tests run, preventing reentrancy
        // when Logger is first accessed from inside a GRDB write block (e.g., during
        // FK violation logging in merge methods).
        _ = Logger.shared
        mapper = CKRecordMapper()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    // MARK: - Helpers

    private func dbQueue() throws -> DatabaseQueue {
        try DatabaseManager.shared.database()
    }

    private func now() -> String {
        isoFormatter.string(from: Date())
    }

    private func pastDate() -> Date {
        Date(timeIntervalSinceNow: -3600)
    }

    private func futureDate() -> Date {
        Date(timeIntervalSinceNow: 3600)
    }

    // MARK: - Roundtrip: Gym

    func testGymRoundtrip() throws {
        let db = try dbQueue()
        let ts = now()
        let original = GymRow(id: "gym-1", name: "Iron Paradise", isDefault: 1, deletedAt: nil, createdAt: ts,
                              updatedAt: ts)
        try db.write { try original.insert($0) }

        let record = mapper.toCKRecord(original, zoneID: zoneID)
        XCTAssertEqual(record.recordType, "Gym")
        XCTAssertEqual(record["name"] as? String, "Iron Paradise")
        XCTAssertEqual(record["isDefault"] as? Int64, 1)

        // Delete local, merge back from CKRecord
        try db.write { try original.delete($0) }
        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try GymRow.fetchOne($0, key: "gym-1") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Iron Paradise")
        XCTAssertEqual(fetched?.isDefault, 1)
    }

    // MARK: - Roundtrip: GymEquipment

    func testGymEquipmentRoundtrip() throws {
        let db = try dbQueue()
        let ts = now()
        // Need a gym for FK
        try db.write { try GymRow(id: "gym-eq", name: "Gym", isDefault: 0, createdAt: ts, updatedAt: ts).insert($0) }

        let original = GymEquipmentRow(id: "eq-1", name: "Barbell", isAvailable: 1, lastCheckedAt: ts, deletedAt: nil,
                                       createdAt: ts, updatedAt: ts, gymId: "gym-eq")
        try db.write { try original.insert($0) }

        let record = mapper.toCKRecord(original, zoneID: zoneID)
        XCTAssertEqual(record.recordType, "GymEquipment")
        XCTAssertEqual(record["name"] as? String, "Barbell")

        try db.write { try original.delete($0) }
        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try GymEquipmentRow.fetchOne($0, key: "eq-1") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Barbell")
        XCTAssertEqual(fetched?.isAvailable, 1)
        XCTAssertEqual(fetched?.gymId, "gym-eq")
    }

    // MARK: - Roundtrip: WorkoutPlan

    func testWorkoutPlanRoundtrip() throws {
        let db = try dbQueue()
        let ts = now()
        let original = WorkoutPlanRow(
            id: "plan-1", name: "Push Day", description: "Chest & shoulders",
            tags: "[\"strength\",\"upper\"]", defaultWeightUnit: "lbs",
            sourceMarkdown: "# Push Day", createdAt: ts, updatedAt: ts, isFavorite: 1
        )
        try db.write { try original.insert($0) }

        let record = mapper.toCKRecord(original, zoneID: zoneID)
        XCTAssertEqual(record["name"] as? String, "Push Day")
        XCTAssertEqual(record["planDescription"] as? String, "Chest & shoulders")
        XCTAssertEqual(record["isFavorite"] as? Int64, 1)

        try db.write { try original.delete($0) }
        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try WorkoutPlanRow.fetchOne($0, key: "plan-1") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Push Day")
        XCTAssertEqual(fetched?.description, "Chest & shoulders")
        XCTAssertEqual(fetched?.sourceMarkdown, "# Push Day")
        XCTAssertEqual(fetched?.isFavorite, 1)
    }

    // MARK: - Roundtrip: PlannedExercise

    func testPlannedExerciseRoundtrip() throws {
        let db = try dbQueue()
        let ts = now()
        try db.write {
            try WorkoutPlanRow(id: "plan-pe", name: "Plan", createdAt: ts, updatedAt: ts, isFavorite: 0).insert($0)
        }

        let original = PlannedExerciseRow(
            id: "pe-1", workoutTemplateId: "plan-pe", exerciseName: "Bench Press",
            orderIndex: 0, notes: "Warm up first", equipmentType: "barbell",
            groupType: "superset", groupName: "Group A", updatedAt: ts
        )
        try db.write { try original.insert($0) }

        let record = mapper.toCKRecord(original, zoneID: zoneID)
        XCTAssertEqual(record["exerciseName"] as? String, "Bench Press")

        try db.write { try original.delete($0) }
        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try PlannedExerciseRow.fetchOne($0, key: "pe-1") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.exerciseName, "Bench Press")
        XCTAssertEqual(fetched?.workoutTemplateId, "plan-pe")
        XCTAssertEqual(fetched?.notes, "Warm up first")
        XCTAssertEqual(fetched?.equipmentType, "barbell")
        XCTAssertEqual(fetched?.orderIndex, 0)
    }

    // MARK: - Roundtrip: PlannedSet

    func testPlannedSetRoundtrip() throws {
        let db = try dbQueue()
        let ts = now()
        try db.write {
            try WorkoutPlanRow(id: "plan-ps", name: "Plan", createdAt: ts, updatedAt: ts, isFavorite: 0).insert($0)
            try PlannedExerciseRow(id: "pe-ps", workoutTemplateId: "plan-ps", exerciseName: "Squat", orderIndex: 0)
                .insert($0)
        }

        let original = PlannedSetRow(
            id: "ps-1", templateExerciseId: "pe-ps", orderIndex: 0,
            restSeconds: 180, isDropset: 1, isPerSide: 0, isAmrap: 1,
            notes: "Go heavy", updatedAt: ts
        )
        // Insert measurements alongside the set row
        let measurements = [
            SetMeasurementRow(id: "m-ps-w", setId: "ps-1", parentType: "planned", role: "target", kind: "weight",
                              value: 225.0, unit: "lbs", groupIndex: 0, updatedAt: ts),
            SetMeasurementRow(id: "m-ps-r", setId: "ps-1", parentType: "planned", role: "target", kind: "reps",
                              value: 5, unit: nil, groupIndex: 0, updatedAt: ts),
            SetMeasurementRow(id: "m-ps-rpe", setId: "ps-1", parentType: "planned", role: "target", kind: "rpe",
                              value: 8, unit: nil, groupIndex: 0, updatedAt: ts),
        ]
        try db.write { db in
            try original.insert(db)
            for measurement in measurements { try measurement.insert(db) }
        }

        let record = mapper.toCKRecord(original, measurements: measurements, zoneID: zoneID)
        XCTAssertEqual(record["targetWeight"] as? Double, 225.0)
        XCTAssertEqual(record["targetReps"] as? Int64, 5)
        let attrs = record["attributes"] as? [String] ?? []
        XCTAssertTrue(attrs.contains("dropset"))
        XCTAssertTrue(attrs.contains("amrap"))
        XCTAssertFalse(attrs.contains("perSide"))

        try db.write { db in
            try original.delete(db)
            try db.execute(sql: "DELETE FROM set_measurements WHERE set_id = 'ps-1'")
        }
        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try PlannedSetRow.fetchOne($0, key: "ps-1") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.isDropset, 1)
        XCTAssertEqual(fetched?.isAmrap, 1)
        XCTAssertEqual(fetched?.isPerSide, 0)
        XCTAssertEqual(fetched?.restSeconds, 180)
        // Verify measurements were recreated
        let fetchedMeasurements = try db.read {
            try SetMeasurementRow.filter(Column("set_id") == "ps-1").fetchAll($0)
        }
        XCTAssertTrue(fetchedMeasurements.contains { $0.kind == "weight" && $0.value == 225.0 })
        XCTAssertTrue(fetchedMeasurements.contains { $0.kind == "reps" && $0.value == 5.0 })
    }

    // MARK: - Roundtrip: WorkoutSession

    func testWorkoutSessionRoundtrip() throws {
        let db = try dbQueue()
        let ts = now()
        // Create parent plan for FK constraint
        try db.write {
            try WorkoutPlanRow(id: "plan-1", name: "Push Day", createdAt: ts, updatedAt: ts, isFavorite: 0).insert($0)
        }
        let original = WorkoutSessionRow(
            id: "session-1", workoutTemplateId: "plan-1", name: "Push Day",
            date: "2026-03-28", startTime: ts, endTime: nil,
            duration: 3600, notes: "Felt strong", status: "completed", updatedAt: ts
        )
        try db.write { try original.insert($0) }

        let record = mapper.toCKRecord(original, zoneID: zoneID)
        XCTAssertEqual(record["name"] as? String, "Push Day")
        XCTAssertEqual(record["status"] as? String, "completed")
        XCTAssertEqual(record["duration"] as? Int64, 3600)

        try db.write { try original.delete($0) }
        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try WorkoutSessionRow.fetchOne($0, key: "session-1") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Push Day")
        XCTAssertEqual(fetched?.status, "completed")
        XCTAssertEqual(fetched?.duration, 3600)
        XCTAssertEqual(fetched?.notes, "Felt strong")
    }

    // MARK: - Roundtrip: SessionExercise

    func testSessionExerciseRoundtrip() throws {
        let db = try dbQueue()
        let ts = now()
        try db.write {
            try WorkoutSessionRow(id: "session-se", name: "Workout", date: "2026-03-28", status: "in_progress")
                .insert($0)
        }

        let original = SessionExerciseRow(
            id: "se-1", workoutSessionId: "session-se", exerciseName: "Deadlift",
            orderIndex: 2, notes: "Belt on", equipmentType: "barbell",
            groupType: "superset", groupName: "Group B", status: "completed", updatedAt: ts
        )
        try db.write { try original.insert($0) }

        let record = mapper.toCKRecord(original, zoneID: zoneID)
        XCTAssertEqual(record["exerciseName"] as? String, "Deadlift")
        XCTAssertEqual(record["orderIndex"] as? Int64, 2)

        try db.write { try original.delete($0) }
        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try SessionExerciseRow.fetchOne($0, key: "se-1") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.exerciseName, "Deadlift")
        XCTAssertEqual(fetched?.orderIndex, 2)
        XCTAssertEqual(fetched?.notes, "Belt on")
        XCTAssertEqual(fetched?.status, "completed")
    }

    // MARK: - Roundtrip: SessionSet

    private func makeSessionSetMeasurements(ts: String) -> [SetMeasurementRow] {
        [
            SetMeasurementRow(id: "m-ss-tw", setId: "ss-1", parentType: "session", role: "target", kind: "weight",
                              value: 135.0, unit: "lbs", groupIndex: 0, updatedAt: ts),
            SetMeasurementRow(id: "m-ss-tr", setId: "ss-1", parentType: "session", role: "target", kind: "reps",
                              value: 10, unit: nil, groupIndex: 0, updatedAt: ts),
            SetMeasurementRow(id: "m-ss-trpe", setId: "ss-1", parentType: "session", role: "target", kind: "rpe",
                              value: 7, unit: nil, groupIndex: 0, updatedAt: ts),
            SetMeasurementRow(id: "m-ss-aw", setId: "ss-1", parentType: "session", role: "actual", kind: "weight",
                              value: 140.0, unit: "lbs", groupIndex: 0, updatedAt: ts),
            SetMeasurementRow(id: "m-ss-ar", setId: "ss-1", parentType: "session", role: "actual", kind: "reps",
                              value: 9, unit: nil, groupIndex: 0, updatedAt: ts),
            SetMeasurementRow(id: "m-ss-arpe", setId: "ss-1", parentType: "session", role: "actual", kind: "rpe",
                              value: 8, unit: nil, groupIndex: 0, updatedAt: ts),
        ]
    }

    func testSessionSetRoundtrip() throws {
        let db = try dbQueue()
        let ts = now()
        try db.write {
            try WorkoutSessionRow(id: "session-ss", name: "Workout", date: "2026-03-28", status: "in_progress")
                .insert($0)
            try SessionExerciseRow(id: "se-ss", workoutSessionId: "session-ss", exerciseName: "Bench", orderIndex: 0,
                                   status: "pending").insert($0)
        }

        let original = SessionSetRow(
            id: "ss-1", sessionExerciseId: "se-ss", orderIndex: 0,
            restSeconds: 90, completedAt: ts, status: "completed",
            notes: "Easy", isDropset: 0, isPerSide: 1, isAmrap: 0,
            side: "left", updatedAt: ts
        )
        let measurements = makeSessionSetMeasurements(ts: ts)
        try db.write { db in
            try original.insert(db)
            for measurement in measurements { try measurement.insert(db) }
        }

        let record = mapper.toCKRecord(original, measurements: measurements, zoneID: zoneID)
        XCTAssertEqual(record["targetWeight"] as? Double, 135.0)
        XCTAssertEqual(record["actualWeight"] as? Double, 140.0)
        XCTAssertEqual(record["actualReps"] as? Int64, 9)
        XCTAssertEqual(record["side"] as? String, "left")
        let attrs = record["attributes"] as? [String] ?? []
        XCTAssertTrue(attrs.contains("perSide"))
        XCTAssertFalse(attrs.contains("dropset"))

        try db.write { db in
            try original.delete(db)
            try db.execute(sql: "DELETE FROM set_measurements WHERE set_id = 'ss-1'")
        }
        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try SessionSetRow.fetchOne($0, key: "ss-1") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.isPerSide, 1)
        XCTAssertEqual(fetched?.isDropset, 0)
        XCTAssertEqual(fetched?.side, "left")
        XCTAssertEqual(fetched?.status, "completed")
        // Verify measurements were recreated from CK record
        let fetchedMeasurements = try db.read {
            try SetMeasurementRow.filter(Column("set_id") == "ss-1").fetchAll($0)
        }
        XCTAssertTrue(fetchedMeasurements.contains { $0.kind == "weight" && $0.role == "target" && $0.value == 135.0 })
        XCTAssertTrue(fetchedMeasurements.contains { $0.kind == "weight" && $0.role == "actual" && $0.value == 140.0 })
        XCTAssertTrue(fetchedMeasurements.contains { $0.kind == "reps" && $0.role == "actual" && $0.value == 9.0 })
    }

    // MARK: - Roundtrip: UserSettings

    func testUserSettingsRoundtrip() throws {
        let db = try dbQueue()
        let ts = now()
        // Clear any existing settings rows created by Logger or other init code
        try db.write { try $0.execute(sql: "DELETE FROM user_settings") }
        let original = UserSettingsRow(
            id: "settings-1", defaultWeightUnit: "kg", enableWorkoutTimer: 1,
            autoStartRestTimer: 0, theme: "dark", notificationsEnabled: 1,
            customPromptAddition: "Be concise",
            anthropicApiKeyStatus: "valid", healthkitEnabled: 1,
            liveActivitiesEnabled: 0, keepScreenAwake: 1, showOpenInClaudeButton: 1,
            developerModeEnabled: 1, countdownSoundsEnabled: 0,
            hasAcceptedDisclaimer: 1, defaultTimerCountdown: 1,
            defaultWeightStepLbs: 5.0,
            aiPromptIncludeFormatPointer: 0,
            aiPromptIncludeRecentWorkouts: 1,
            aiPromptIncludeProgression: 0,
            aiPromptIncludeEquipment: 1,
            homeTiles: "[\"Squat\"]", createdAt: ts, updatedAt: ts
        )
        try db.write { try original.insert($0) }

        let record = mapper.toCKRecord(original, zoneID: zoneID)
        XCTAssertEqual(record["defaultWeightUnit"] as? String, "kg")
        XCTAssertEqual(record["theme"] as? String, "dark")
        // anthropicApiKey should NOT be in the CKRecord
        XCTAssertNil(record["anthropicApiKey"])

        // Delete local, merge back from CKRecord
        try db.write { try $0.execute(sql: "DELETE FROM user_settings") }
        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try UserSettingsRow.fetchOne($0) }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.defaultWeightUnit, "kg")
        XCTAssertEqual(fetched?.theme, "dark")
        XCTAssertEqual(fetched?.enableWorkoutTimer, 1)
        XCTAssertEqual(fetched?.autoStartRestTimer, 0)
        XCTAssertEqual(fetched?.aiPromptIncludeFormatPointer, 0)
        XCTAssertEqual(fetched?.aiPromptIncludeRecentWorkouts, 1)
        XCTAssertEqual(fetched?.aiPromptIncludeProgression, 0)
        XCTAssertEqual(fetched?.aiPromptIncludeEquipment, 1)
    }

    // MARK: - Merge: Last-Writer-Wins (local newer, remote skipped)

    func testMergeSkipsWhenLocalIsNewer() throws {
        let db = try dbQueue()
        let futureTs = isoFormatter.string(from: futureDate())
        let original = GymRow(id: "gym-lww", name: "Local Gym", isDefault: 0, createdAt: futureTs, updatedAt: futureTs)
        try db.write { try original.insert($0) }

        // Build a CKRecord with an older updatedAt
        let record = CKRecord(recordType: "Gym", recordID: CKRecord.ID(recordName: "gym-lww", zoneID: zoneID))
        record["name"] = "Remote Gym" as CKRecordValue
        record["isDefault"] = Int64(0) as CKRecordValue
        record["updatedAt"] = pastDate() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertFalse(merged)

        let fetched = try db.read { try GymRow.fetchOne($0, key: "gym-lww") }
        XCTAssertEqual(fetched?.name, "Local Gym") // unchanged
    }

    // MARK: - Merge: Last-Writer-Wins (remote newer, local updated)

    func testMergeUpdatesWhenRemoteIsNewer() throws {
        let db = try dbQueue()
        let pastTs = isoFormatter.string(from: pastDate())
        let original = GymRow(id: "gym-lww2", name: "Old Name", isDefault: 0, createdAt: pastTs, updatedAt: pastTs)
        try db.write { try original.insert($0) }

        let record = CKRecord(recordType: "Gym", recordID: CKRecord.ID(recordName: "gym-lww2", zoneID: zoneID))
        record["name"] = "New Name" as CKRecordValue
        record["isDefault"] = Int64(1) as CKRecordValue
        record["updatedAt"] = futureDate() as CKRecordValue
        record["createdAt"] = pastDate() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try GymRow.fetchOne($0, key: "gym-lww2") }
        XCTAssertEqual(fetched?.name, "New Name")
        XCTAssertEqual(fetched?.isDefault, 1)
    }

    // MARK: - Merge: Canceled Status Protection

    func testMergeWorkoutSessionPreservesCanceledStatus() throws {
        let db = try dbQueue()
        let pastTs = isoFormatter.string(from: pastDate())
        let session = WorkoutSessionRow(
            id: "session-cancel", name: "Canceled Workout", date: "2026-03-28",
            status: SessionStatus.canceled.rawValue, updatedAt: pastTs
        )
        try db.write { try session.insert($0) }

        // Remote says "completed" and is newer
        let record = CKRecord(recordType: "WorkoutSession",
                              recordID: CKRecord.ID(recordName: "session-cancel", zoneID: zoneID))
        record["name"] = "Canceled Workout" as CKRecordValue
        record["date"] = "2026-03-28" as CKRecordValue
        record["status"] = "completed" as CKRecordValue
        record["updatedAt"] = futureDate() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try WorkoutSessionRow.fetchOne($0, key: "session-cancel") }
        XCTAssertEqual(fetched?.status, SessionStatus.canceled.rawValue,
                       "Canceled status must be preserved regardless of remote")
    }

    // MARK: - Merge: Soft-Delete Protection

    func testMergeGymDoesNotReInsertSoftDeleted() throws {
        let db = try dbQueue()
        let ts = now()
        let gym = GymRow(id: "gym-sd", name: "Deleted Gym", isDefault: 0, deletedAt: ts, createdAt: ts, updatedAt: ts)
        try db.write { try gym.insert($0) }

        let record = CKRecord(recordType: "Gym", recordID: CKRecord.ID(recordName: "gym-sd", zoneID: zoneID))
        record["name"] = "Deleted Gym" as CKRecordValue
        record["isDefault"] = Int64(0) as CKRecordValue
        record["updatedAt"] = futureDate() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertFalse(merged, "Should not re-insert soft-deleted gym")

        let fetched = try db.read { try GymRow.fetchOne($0, key: "gym-sd") }
        XCTAssertNotNil(fetched?.deletedAt, "deletedAt should still be set")
    }

    func testMergeGymEquipmentDoesNotReInsertSoftDeleted() throws {
        let db = try dbQueue()
        let ts = now()
        try db.write {
            try GymRow(id: "gym-for-eq-sd", name: "Gym", isDefault: 0, createdAt: ts, updatedAt: ts).insert($0)
        }
        let eq = GymEquipmentRow(id: "eq-sd", name: "Deleted Eq", isAvailable: 1, deletedAt: ts,
                                 createdAt: ts, updatedAt: ts, gymId: "gym-for-eq-sd")
        try db.write { try eq.insert($0) }

        let record = CKRecord(recordType: "GymEquipment", recordID: CKRecord.ID(recordName: "eq-sd", zoneID: zoneID))
        record["name"] = "Deleted Eq" as CKRecordValue
        record["isAvailable"] = Int64(1) as CKRecordValue
        record["updatedAt"] = futureDate() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertFalse(merged, "Should not re-insert soft-deleted equipment")
    }

    // MARK: - Merge: UserSettings Local-Only Fields

    func testMergeUserSettingsPreservesLocalOnlyFields() throws {
        let db = try dbQueue()
        let pastTs = isoFormatter.string(from: pastDate())

        // Clear any existing settings rows (may be created by Logger or other init code)
        try db.write { try $0.execute(sql: "DELETE FROM user_settings") }

        // Insert settings with non-default local-only field values
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO user_settings (
                    id, default_weight_unit, enable_workout_timer, auto_start_rest_timer,
                    theme, notifications_enabled,
                    anthropic_api_key_status,
                    healthkit_enabled, live_activities_enabled, keep_screen_awake,
                    show_open_in_claude_button, developer_mode_enabled, countdown_sounds_enabled,
                    has_accepted_disclaimer, created_at, updated_at
                ) VALUES (
                    'settings-lo', 'lbs', 1, 1,
                    'auto', 1,
                    'valid',
                    0, 1, 1,
                    0, 1, 1,
                    1, '\(pastTs)', '\(pastTs)'
                )
            """)
        }

        // Remote changes theme but should not touch local-only fields
        let record = CKRecord(recordType: "UserSettings",
                              recordID: CKRecord.ID(recordName: "settings-lo", zoneID: zoneID))
        record["defaultWeightUnit"] = "kg" as CKRecordValue
        record["enableWorkoutTimer"] = Int64(0) as CKRecordValue
        record["autoStartRestTimer"] = Int64(0) as CKRecordValue
        record["theme"] = "dark" as CKRecordValue
        record["notificationsEnabled"] = Int64(0) as CKRecordValue
        record["healthKitEnabled"] = Int64(1) as CKRecordValue
        record["liveActivitiesEnabled"] = Int64(0) as CKRecordValue
        record["keepScreenAwake"] = Int64(0) as CKRecordValue
        record["showOpenInClaudeButton"] = Int64(1) as CKRecordValue
        record["countdownSoundsEnabled"] = Int64(0) as CKRecordValue
        record["updatedAt"] = futureDate() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try db.read { try UserSettingsRow.fetchOne($0) }
        XCTAssertNotNil(fetched)

        // Synced fields should be updated
        XCTAssertEqual(fetched?.defaultWeightUnit, "kg")
        XCTAssertEqual(fetched?.theme, "dark")

        // Local-only fields must be preserved
        XCTAssertEqual(fetched?.hasAcceptedDisclaimer, 1, "hasAcceptedDisclaimer must never be overwritten")
        XCTAssertEqual(fetched?.developerModeEnabled, 1, "developerModeEnabled must never be overwritten")
        XCTAssertEqual(fetched?.anthropicApiKeyStatus, "valid", "anthropicApiKeyStatus must never be overwritten")
    }

    // MARK: - Merge: FK Violation Handling

    func testMergePlannedExerciseSkipsEmptyFK() throws {
        // Merging a PlannedExercise with no workoutPlanId and no existing record should be skipped
        let record = CKRecord(recordType: "PlannedExercise",
                              recordID: CKRecord.ID(recordName: "pe-nofk", zoneID: zoneID))
        record["exerciseName"] = "Orphan Exercise" as CKRecordValue
        record["orderIndex"] = Int64(0) as CKRecordValue
        // workoutPlanId intentionally omitted
        record["updatedAt"] = Date() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertFalse(merged, "Should skip PlannedExercise with empty FK")
    }

    func testMergePlannedSetSkipsEmptyFK() throws {
        let record = CKRecord(recordType: "PlannedSet", recordID: CKRecord.ID(recordName: "ps-nofk", zoneID: zoneID))
        record["orderIndex"] = Int64(0) as CKRecordValue
        // plannedExerciseId intentionally omitted
        record["updatedAt"] = Date() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertFalse(merged, "Should skip PlannedSet with empty FK")
    }

    func testMergeSessionExerciseSkipsEmptyFK() throws {
        let record = CKRecord(recordType: "SessionExercise",
                              recordID: CKRecord.ID(recordName: "se-nofk", zoneID: zoneID))
        record["exerciseName"] = "Orphan" as CKRecordValue
        record["orderIndex"] = Int64(0) as CKRecordValue
        record["status"] = "pending" as CKRecordValue
        // workoutSessionId intentionally omitted
        record["updatedAt"] = Date() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertFalse(merged, "Should skip SessionExercise with empty FK")
    }

    func testMergeSessionSetSkipsEmptyFK() throws {
        let record = CKRecord(recordType: "SessionSet", recordID: CKRecord.ID(recordName: "ss-nofk", zoneID: zoneID))
        record["orderIndex"] = Int64(0) as CKRecordValue
        record["status"] = "pending" as CKRecordValue
        // sessionExerciseId intentionally omitted
        record["updatedAt"] = Date() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertFalse(merged, "Should skip SessionSet with empty FK")
    }

    // MARK: - Merge: New Record Insertion

    func testMergeInsertsNewGym() throws {
        let record = CKRecord(recordType: "Gym", recordID: CKRecord.ID(recordName: "gym-new", zoneID: zoneID))
        record["name"] = "Brand New Gym" as CKRecordValue
        record["isDefault"] = Int64(0) as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try dbQueue().read { try GymRow.fetchOne($0, key: "gym-new") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Brand New Gym")
    }

    func testMergeInsertsNewWorkoutPlan() throws {
        let record = CKRecord(recordType: "WorkoutPlan", recordID: CKRecord.ID(recordName: "plan-new", zoneID: zoneID))
        record["name"] = "New Plan" as CKRecordValue
        record["isFavorite"] = Int64(1) as CKRecordValue
        record["createdAt"] = Date() as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try dbQueue().read { try WorkoutPlanRow.fetchOne($0, key: "plan-new") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "New Plan")
        XCTAssertEqual(fetched?.isFavorite, 1)
    }

    func testMergeInsertsNewWorkoutSession() throws {
        let record = CKRecord(recordType: "WorkoutSession",
                              recordID: CKRecord.ID(recordName: "session-new", zoneID: zoneID))
        record["name"] = "New Session" as CKRecordValue
        record["date"] = "2026-03-28" as CKRecordValue
        record["status"] = "completed" as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try dbQueue().read { try WorkoutSessionRow.fetchOne($0, key: "session-new") }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "New Session")
        XCTAssertEqual(fetched?.status, "completed")
    }

    func testMergeInsertsNewUserSettings() throws {
        // Clear any existing settings, then verify insert fresh
        let db = try dbQueue()
        try db.write { try $0.execute(sql: "DELETE FROM user_settings") }
        let record = CKRecord(recordType: "UserSettings",
                              recordID: CKRecord.ID(recordName: "user-settings", zoneID: zoneID))
        record["defaultWeightUnit"] = "kg" as CKRecordValue
        record["theme"] = "dark" as CKRecordValue
        record["enableWorkoutTimer"] = Int64(1) as CKRecordValue
        record["autoStartRestTimer"] = Int64(0) as CKRecordValue
        record["notificationsEnabled"] = Int64(1) as CKRecordValue
        record["healthKitEnabled"] = Int64(0) as CKRecordValue
        record["liveActivitiesEnabled"] = Int64(1) as CKRecordValue
        record["keepScreenAwake"] = Int64(1) as CKRecordValue
        record["showOpenInClaudeButton"] = Int64(0) as CKRecordValue
        record["countdownSoundsEnabled"] = Int64(1) as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue

        let merged = try mapper.mergeIncoming(record)
        XCTAssertTrue(merged)

        let fetched = try dbQueue().read { try UserSettingsRow.fetchOne($0) }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.defaultWeightUnit, "kg")
        XCTAssertEqual(fetched?.theme, "dark")
        // New insert should default local-only fields
        XCTAssertEqual(fetched?.hasAcceptedDisclaimer, 0, "New device must re-accept disclaimer")
        XCTAssertEqual(fetched?.developerModeEnabled, 0)
    }

    // MARK: - Merge: Unknown Record Type

    func testMergeReturnsFalseForUnknownType() throws {
        let record = CKRecord(recordType: "UnknownType", recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        let merged = try mapper.mergeIncoming(record)
        XCTAssertFalse(merged)
    }

    // MARK: - Dependency Ordering

    func testMergeOrderHasParentsBeforeChildren() {
        // Access via CKSyncEngineManager is private, so we verify the expected order
        // by checking that parent types come before their children in the merge sequence.
        let expectedOrder = [
            "Gym", "GymEquipment", "WorkoutPlan", "PlannedExercise", "PlannedSet",
            "WorkoutSession", "SessionExercise", "SessionSet", "UserSettings"
        ]

        // Gym before GymEquipment
        let gymIdx = expectedOrder.firstIndex(of: "Gym")!
        let eqIdx = expectedOrder.firstIndex(of: "GymEquipment")!
        XCTAssertLessThan(gymIdx, eqIdx)

        // WorkoutPlan before PlannedExercise before PlannedSet
        let planIdx = expectedOrder.firstIndex(of: "WorkoutPlan")!
        let peIdx = expectedOrder.firstIndex(of: "PlannedExercise")!
        let psIdx = expectedOrder.firstIndex(of: "PlannedSet")!
        XCTAssertLessThan(planIdx, peIdx)
        XCTAssertLessThan(peIdx, psIdx)

        // WorkoutSession before SessionExercise before SessionSet
        let sessionIdx = expectedOrder.firstIndex(of: "WorkoutSession")!
        let seIdx = expectedOrder.firstIndex(of: "SessionExercise")!
        let ssIdx = expectedOrder.firstIndex(of: "SessionSet")!
        XCTAssertLessThan(sessionIdx, seIdx)
        XCTAssertLessThan(seIdx, ssIdx)
    }

    // MARK: - Active Session Protection

    func testGetActiveSessionProtectedIdsIncludesAllRelated() throws {
        let db = try dbQueue()
        let ts = now()

        let planId = "plan-active"
        let peId = "pe-active"
        let psId = "ps-active"
        let sessionId = "session-active"
        let seId = "se-active"
        let ssId = "ss-active"

        try db.write { db in
            try WorkoutPlanRow(id: planId, name: "Active Plan", createdAt: ts, updatedAt: ts, isFavorite: 0).insert(db)
            try PlannedExerciseRow(id: peId, workoutTemplateId: planId, exerciseName: "Squat", orderIndex: 0).insert(db)
            try PlannedSetRow(id: psId, templateExerciseId: peId, orderIndex: 0,
                              isDropset: 0, isPerSide: 0, isAmrap: 0).insert(db)

            try WorkoutSessionRow(id: sessionId, workoutTemplateId: planId, name: "Active Plan", date: "2026-03-28",
                                  status: "in_progress").insert(db)
            try SessionExerciseRow(id: seId, workoutSessionId: sessionId, exerciseName: "Squat", orderIndex: 0,
                                   status: "pending").insert(db)
            try SessionSetRow(id: ssId, sessionExerciseId: seId, orderIndex: 0, status: "pending",
                              isDropset: 0, isPerSide: 0, isAmrap: 0).insert(db)
        }

        let protected = mapper.getActiveSessionProtectedIds()

        XCTAssertEqual(protected.sessionId, sessionId)
        XCTAssertTrue(protected.exerciseIds.contains(seId))
        XCTAssertTrue(protected.setIds.contains(ssId))
        XCTAssertEqual(protected.planId, planId)
        XCTAssertTrue(protected.plannedExerciseIds.contains(peId))
        XCTAssertTrue(protected.plannedSetIds.contains(psId))

        // Verify byRecordType
        let map = protected.byRecordType
        XCTAssertEqual(map["WorkoutSession"], Set([sessionId]))
        XCTAssertEqual(map["SessionExercise"], Set([seId]))
        XCTAssertEqual(map["SessionSet"], Set([ssId]))
        XCTAssertEqual(map["WorkoutPlan"], Set([planId]))
        XCTAssertEqual(map["PlannedExercise"], Set([peId]))
        XCTAssertEqual(map["PlannedSet"], Set([psId]))
    }

    func testGetActiveSessionProtectedIdsEmptyWhenNoActiveSession() {
        let protected = mapper.getActiveSessionProtectedIds()
        XCTAssertNil(protected.sessionId)
        XCTAssertTrue(protected.exerciseIds.isEmpty)
        XCTAssertTrue(protected.setIds.isEmpty)
        XCTAssertNil(protected.planId)
        XCTAssertTrue(protected.byRecordType.isEmpty)
    }

    // MARK: - createCKRecord Lookup

    func testCreateCKRecordLooksUpAllEntityTypes() throws {
        let db = try dbQueue()
        let ts = now()

        try db.write { db in
            try GymRow(id: "lookup-gym", name: "Gym", isDefault: 0, createdAt: ts, updatedAt: ts).insert(db)
            try WorkoutPlanRow(id: "lookup-plan", name: "Plan", createdAt: ts, updatedAt: ts, isFavorite: 0).insert(db)
            try WorkoutSessionRow(id: "lookup-session", name: "Session", date: "2026-03-28", status: "completed")
                .insert(db)
        }

        let gymRecord = mapper.createCKRecord(for: CKRecord.ID(recordName: "lookup-gym", zoneID: zoneID),
                                              zoneID: zoneID)
        XCTAssertNotNil(gymRecord)
        XCTAssertEqual(gymRecord?.recordType, "Gym")

        let planRecord = mapper.createCKRecord(for: CKRecord.ID(recordName: "lookup-plan", zoneID: zoneID),
                                               zoneID: zoneID)
        XCTAssertNotNil(planRecord)
        XCTAssertEqual(planRecord?.recordType, "WorkoutPlan")

        let sessionRecord = mapper.createCKRecord(for: CKRecord.ID(recordName: "lookup-session", zoneID: zoneID),
                                                  zoneID: zoneID)
        XCTAssertNotNil(sessionRecord)
        XCTAssertEqual(sessionRecord?.recordType, "WorkoutSession")

        let missing = mapper.createCKRecord(for: CKRecord.ID(recordName: "nonexistent", zoneID: zoneID), zoneID: zoneID)
        XCTAssertNil(missing)
    }

    // MARK: - deleteLocalRecord

    func testDeleteLocalRecordRemovesFromDB() throws {
        let db = try dbQueue()
        let ts = now()
        try db.write {
            try GymRow(id: "del-gym", name: "To Delete", isDefault: 0, createdAt: ts, updatedAt: ts).insert($0)
        }

        try mapper.deleteLocalRecord(id: "del-gym")

        let fetched = try db.read { try GymRow.fetchOne($0, key: "del-gym") }
        XCTAssertNil(fetched, "Record should be deleted")
    }
}

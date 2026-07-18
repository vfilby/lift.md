import XCTest
import GRDB
@testable import LiftMark

/// Tests for the SetMeasurement data model: SetEntry, EntryValues, measurement rows,
/// backward-compatible computed properties on SessionSet/PlannedSet, and repository round-trips.
final class SetMeasurementTests: XCTestCase {

    private var sessionRepo: SessionRepository!
    private var planRepo: WorkoutPlanRepository!

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
        sessionRepo = SessionRepository()
        planRepo = WorkoutPlanRepository()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    // MARK: - SetEntry.buildEntries

    func testBuildEntriesSingleGroup() {
        let rows = [
            makeRow(kind: "weight", value: 225, unit: "lbs", role: "target", groupIndex: 0),
            makeRow(kind: "reps", value: 5, unit: nil, role: "target", groupIndex: 0),
            makeRow(kind: "weight", value: 230, unit: "lbs", role: "actual", groupIndex: 0),
            makeRow(kind: "reps", value: 4, unit: nil, role: "actual", groupIndex: 0)
        ]

        let entries = SetEntry.buildEntries(from: rows)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].groupIndex, 0)
        XCTAssertEqual(entries[0].target?.weight?.value, 225)
        XCTAssertEqual(entries[0].target?.weight?.unit, .lbs)
        XCTAssertEqual(entries[0].target?.reps, 5)
        XCTAssertEqual(entries[0].actual?.weight?.value, 230)
        XCTAssertEqual(entries[0].actual?.reps, 4)
    }

    func testBuildEntriesMultipleGroupsDropSet() {
        let rows = [
            // Group 0 — heavy
            makeRow(kind: "weight", value: 225, unit: "lbs", role: "target", groupIndex: 0),
            makeRow(kind: "reps", value: 5, unit: nil, role: "target", groupIndex: 0),
            // Group 1 — drop
            makeRow(kind: "weight", value: 185, unit: "lbs", role: "target", groupIndex: 1),
            makeRow(kind: "reps", value: 8, unit: nil, role: "target", groupIndex: 1),
            // Group 2 — drop
            makeRow(kind: "weight", value: 135, unit: "lbs", role: "target", groupIndex: 2),
            makeRow(kind: "reps", value: 12, unit: nil, role: "target", groupIndex: 2)
        ]

        let entries = SetEntry.buildEntries(from: rows)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].groupIndex, 0)
        XCTAssertEqual(entries[0].target?.weight?.value, 225)
        XCTAssertEqual(entries[1].groupIndex, 1)
        XCTAssertEqual(entries[1].target?.weight?.value, 185)
        XCTAssertEqual(entries[2].groupIndex, 2)
        XCTAssertEqual(entries[2].target?.weight?.value, 135)
        XCTAssertEqual(entries[2].target?.reps, 12)
    }

    func testBuildEntriesEmptyArray() {
        let entries = SetEntry.buildEntries(from: [])
        XCTAssertTrue(entries.isEmpty)
    }

    func testBuildEntriesTargetOnlyNoActual() {
        let rows = [
            makeRow(kind: "weight", value: 100, unit: "kg", role: "target", groupIndex: 0),
            makeRow(kind: "reps", value: 10, unit: nil, role: "target", groupIndex: 0)
        ]

        let entries = SetEntry.buildEntries(from: rows)

        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries[0].target)
        XCTAssertNil(entries[0].actual)
        XCTAssertEqual(entries[0].target?.weight?.unit, .kg)
    }

    // MARK: - EntryValues round-trip

    func testEntryValuesRoundTripWeightAndReps() {
        let original = EntryValues(
            weight: MeasuredWeight(value: 225, unit: .lbs),
            reps: 5,
            time: nil,
            distance: nil,
            rpe: 8
        )

        let rows = original.toMeasurementRows(
            setId: "set-1", parentType: "session", role: "target", groupIndex: 0, now: "2026-04-16T00:00:00Z"
        )
        let reconstructed = EntryValues.from(rows)

        XCTAssertEqual(reconstructed.weight?.value, 225)
        XCTAssertEqual(reconstructed.weight?.unit, .lbs)
        XCTAssertEqual(reconstructed.reps, 5)
        XCTAssertEqual(reconstructed.rpe, 8)
        XCTAssertNil(reconstructed.time)
        XCTAssertNil(reconstructed.distance)
    }

    func testEntryValuesRoundTripAllFields() {
        let original = EntryValues(
            weight: MeasuredWeight(value: 100, unit: .kg),
            reps: 10,
            time: 60,
            distance: MeasuredDistance(value: 400, unit: .meters),
            rpe: 7
        )

        let rows = original.toMeasurementRows(
            setId: "set-2", parentType: "planned", role: "target", groupIndex: 0, now: "2026-04-16T00:00:00Z"
        )

        XCTAssertEqual(rows.count, 5, "Should produce one row per non-nil measurement kind")
        XCTAssertTrue(rows.allSatisfy { $0.setId == "set-2" })
        XCTAssertTrue(rows.allSatisfy { $0.parentType == "planned" })
        XCTAssertTrue(rows.allSatisfy { $0.role == "target" })

        let reconstructed = EntryValues.from(rows)

        XCTAssertEqual(reconstructed.weight?.value, 100)
        XCTAssertEqual(reconstructed.weight?.unit, .kg)
        XCTAssertEqual(reconstructed.reps, 10)
        XCTAssertEqual(reconstructed.time, 60)
        XCTAssertEqual(reconstructed.distance?.value, 400)
        XCTAssertEqual(reconstructed.distance?.unit, .meters)
        XCTAssertEqual(reconstructed.rpe, 7)
    }

    func testEntryValuesEmptyProducesNoRows() {
        let empty = EntryValues()
        let rows = empty.toMeasurementRows(
            setId: "set-3", parentType: "session", role: "actual", groupIndex: 0, now: "2026-04-16T00:00:00Z"
        )
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - SessionSet backward-compatible init

    func testSessionSetBackwardCompatibleInit() {
        let set = SessionSet(
            sessionExerciseId: "ex-1",
            orderIndex: 0,
            targetWeight: 225,
            targetWeightUnit: .lbs,
            targetReps: 5,
            targetRpe: 8,
            actualWeight: 230,
            actualWeightUnit: .lbs,
            actualReps: 4,
            actualRpe: 9,
            status: .completed
        )

        // Verify computed properties return correct values
        XCTAssertEqual(set.targetWeight, 225)
        XCTAssertEqual(set.targetWeightUnit, .lbs)
        XCTAssertEqual(set.targetReps, 5)
        XCTAssertEqual(set.targetRpe, 8)
        XCTAssertEqual(set.actualWeight, 230)
        XCTAssertEqual(set.actualWeightUnit, .lbs)
        XCTAssertEqual(set.actualReps, 4)
        XCTAssertEqual(set.actualRpe, 9)

        // Verify entries were built
        XCTAssertEqual(set.entries.count, 1)
        XCTAssertEqual(set.entries[0].groupIndex, 0)
    }

    func testSessionSetBackwardCompatibleInitEmptyFields() {
        let set = SessionSet(
            sessionExerciseId: "ex-1",
            orderIndex: 0,
            status: .pending
        )

        XCTAssertTrue(set.entries.isEmpty)
        XCTAssertNil(set.targetWeight)
        XCTAssertNil(set.targetReps)
        XCTAssertNil(set.actualWeight)
        XCTAssertNil(set.actualReps)
    }

    func testSessionSetBackwardCompatibleInitTargetOnly() {
        let set = SessionSet(
            sessionExerciseId: "ex-1",
            orderIndex: 0,
            targetWeight: 315,
            targetWeightUnit: .kg,
            targetReps: 3
        )

        XCTAssertEqual(set.entries.count, 1)
        XCTAssertNotNil(set.entries[0].target)
        XCTAssertNil(set.entries[0].actual)
        XCTAssertEqual(set.targetWeight, 315)
        XCTAssertEqual(set.targetWeightUnit, .kg)
        XCTAssertEqual(set.targetReps, 3)
    }

    func testSessionSetDeprecatedFieldsReturnNil() {
        let set = SessionSet(
            sessionExerciseId: "ex-1",
            orderIndex: 0,
            targetWeight: 225,
            targetWeightUnit: .lbs,
            targetReps: 5,
            tempo: "3-1-1-0"
        )

        // tempo, parentSetId, dropSequence are deprecated and always nil
        XCTAssertNil(set.tempo)
        XCTAssertNil(set.parentSetId)
        XCTAssertNil(set.dropSequence)
    }

    // MARK: - SessionSet computed setters

    func testSessionSetComputedSettersOnEmpty() {
        var set = SessionSet(
            sessionExerciseId: "ex-1",
            orderIndex: 0,
            status: .pending
        )

        // Empty to start
        XCTAssertTrue(set.entries.isEmpty)

        // Setting targetWeight creates entries
        set.targetWeight = 225
        XCTAssertEqual(set.entries.count, 1)
        XCTAssertEqual(set.targetWeight, 225)
        XCTAssertEqual(set.targetWeightUnit, .lbs) // default

        // Setting targetReps fills into existing entry
        set.targetReps = 5
        XCTAssertEqual(set.entries.count, 1)
        XCTAssertEqual(set.targetReps, 5)

        // Setting actualReps creates actual within same entry
        set.actualReps = 4
        XCTAssertEqual(set.entries.count, 1)
        XCTAssertEqual(set.actualReps, 4)
    }

    func testSessionSetComputedSettersActualWeight() {
        var set = SessionSet(
            sessionExerciseId: "ex-1",
            orderIndex: 0,
            status: .pending
        )

        set.actualWeight = 200
        XCTAssertEqual(set.actualWeight, 200)
        XCTAssertEqual(set.actualWeightUnit, .lbs) // default
    }

    func testSessionSetClearTargetWeight() {
        var set = SessionSet(
            sessionExerciseId: "ex-1",
            orderIndex: 0,
            targetWeight: 225,
            targetWeightUnit: .lbs,
            targetReps: 5
        )

        set.targetWeight = nil
        XCTAssertNil(set.targetWeight)
        XCTAssertNil(set.targetWeightUnit)
        // reps should still be there
        XCTAssertEqual(set.targetReps, 5)
    }

    // MARK: - PlannedSet backward-compatible init

    func testPlannedSetBackwardCompatibleInit() {
        let set = PlannedSet(
            plannedExerciseId: "pex-1",
            orderIndex: 0,
            targetWeight: 225,
            targetWeightUnit: .lbs,
            targetReps: 5,
            targetRpe: 8,
            restSeconds: 180,
            isDropset: true,
            isAmrap: true,
            notes: "Go heavy"
        )

        XCTAssertEqual(set.targetWeight, 225)
        XCTAssertEqual(set.targetWeightUnit, .lbs)
        XCTAssertEqual(set.targetReps, 5)
        XCTAssertEqual(set.targetRpe, 8)
        XCTAssertEqual(set.restSeconds, 180)
        XCTAssertTrue(set.isDropset)
        XCTAssertTrue(set.isAmrap)
        XCTAssertEqual(set.notes, "Go heavy")

        // Entries should contain a single group with target only
        XCTAssertEqual(set.entries.count, 1)
        XCTAssertEqual(set.entries[0].groupIndex, 0)
        XCTAssertNotNil(set.entries[0].target)
        XCTAssertNil(set.entries[0].actual) // PlannedSet has no actuals
    }

    func testPlannedSetBackwardCompatibleInitEmptyFields() {
        let set = PlannedSet(
            plannedExerciseId: "pex-1",
            orderIndex: 0
        )

        XCTAssertTrue(set.entries.isEmpty)
        XCTAssertNil(set.targetWeight)
        XCTAssertNil(set.targetReps)
    }

    func testPlannedSetDeprecatedTempoReturnsNil() {
        let set = PlannedSet(
            plannedExerciseId: "pex-1",
            orderIndex: 0,
            targetWeight: 100,
            tempo: "3-1-1-0"
        )

        XCTAssertNil(set.tempo)
    }

    func testPlannedSetComputedSetters() {
        var set = PlannedSet(
            plannedExerciseId: "pex-1",
            orderIndex: 0
        )

        XCTAssertTrue(set.entries.isEmpty)

        set.targetWeight = 135
        XCTAssertEqual(set.entries.count, 1)
        XCTAssertEqual(set.targetWeight, 135)
        XCTAssertEqual(set.targetWeightUnit, .lbs)

        set.targetReps = 10
        XCTAssertEqual(set.targetReps, 10)
    }

    // MARK: - SessionRepository round-trip (measurements persisted in DB)

    func testSessionRepositoryRoundTripMeasurements() throws {
        let plan = makeMeasurementTestPlan()
        try planRepo.create(plan)

        // Create session from plan
        let (session, _) = try sessionRepo.createFromPlan(plan)

        // Verify targets came through
        XCTAssertEqual(session.exercises[0].sets.count, 2)
        XCTAssertEqual(session.exercises[0].sets[0].targetWeight, 225)
        XCTAssertEqual(session.exercises[0].sets[0].targetReps, 5)
        XCTAssertEqual(session.exercises[0].sets[0].targetRpe, 8)

        // Record actuals on first set
        let setId = session.exercises[0].sets[0].id
        try sessionRepo.updateSessionSet(
            setId,
            actualWeight: 230,
            actualWeightUnit: .lbs,
            actualReps: 4,
            actualTime: nil,
            actualRpe: 9,
            status: .completed
        )

        // Fetch back and verify
        let fetched = try sessionRepo.getById(session.id)
        XCTAssertNotNil(fetched)
        let fetchedSet = fetched!.exercises[0].sets[0]
        XCTAssertEqual(fetchedSet.targetWeight, 225)
        XCTAssertEqual(fetchedSet.targetReps, 5)
        XCTAssertEqual(fetchedSet.targetRpe, 8)
        XCTAssertEqual(fetchedSet.actualWeight, 230)
        XCTAssertEqual(fetchedSet.actualWeightUnit, .lbs)
        XCTAssertEqual(fetchedSet.actualReps, 4)
        XCTAssertEqual(fetchedSet.actualRpe, 9)
        XCTAssertEqual(fetchedSet.status, .completed)
    }

    func testSessionRepositoryMeasurementsStoredInDB() throws {
        let plan = WorkoutPlan(
            name: "DB Check",
            exercises: [
                PlannedExercise(
                    workoutPlanId: "plan-1",
                    exerciseName: "Squat",
                    orderIndex: 0,
                    sets: [
                        PlannedSet(
                            plannedExerciseId: "pex-1",
                            orderIndex: 0,
                            targetWeight: 315,
                            targetWeightUnit: .lbs,
                            targetReps: 3
                        )
                    ]
                )
            ]
        )
        try planRepo.create(plan)
        let (session, _) = try sessionRepo.createFromPlan(plan)
        let setId = session.exercises[0].sets[0].id

        // Verify measurement rows exist in DB
        let dbQueue = try DatabaseManager.shared.database()
        let measurements = try dbQueue.read { db in
            try SetMeasurementRow
                .filter(Column("set_id") == setId)
                .filter(Column("parent_type") == "session")
                .fetchAll(db)
        }

        // Should have weight and reps target rows
        XCTAssertEqual(measurements.count, 2)
        let kinds = Set(measurements.map(\.kind))
        XCTAssertTrue(kinds.contains("weight"))
        XCTAssertTrue(kinds.contains("reps"))
        XCTAssertTrue(measurements.allSatisfy { $0.role == "target" })
    }

    func testSessionRepositoryUpdateTargetMeasurements() throws {
        let plan = WorkoutPlan(
            name: "Target Update",
            exercises: [
                PlannedExercise(
                    workoutPlanId: "plan-1",
                    exerciseName: "Bench Press",
                    orderIndex: 0,
                    sets: [
                        PlannedSet(
                            plannedExerciseId: "pex-1",
                            orderIndex: 0,
                            targetWeight: 225,
                            targetWeightUnit: .lbs,
                            targetReps: 5
                        )
                    ]
                )
            ]
        )
        try planRepo.create(plan)
        let (session, _) = try sessionRepo.createFromPlan(plan)
        let setId = session.exercises[0].sets[0].id

        // Update targets
        try sessionRepo.updateSessionSetTarget(setId, targetWeight: 235, targetReps: 3, targetTime: nil,
                                               restSeconds: nil)

        let fetched = try sessionRepo.getById(session.id)
        let fetchedSet = fetched!.exercises[0].sets[0]
        XCTAssertEqual(fetchedSet.targetWeight, 235)
        XCTAssertEqual(fetchedSet.targetReps, 3)
    }

    // MARK: - SyncSessionGuard measurement protection

    func testSyncSessionGuardSnapshotCapturesMeasurements() throws {
        let dbQueue = try DatabaseManager.shared.database()

        try dbQueue.write { db in
            try makeSession(id: "s1", status: "in_progress").insert(db)
            try makeExercise(id: "e1", sessionId: "s1").insert(db)
            try makeSessionSetRow(id: "set1", exerciseId: "e1").insert(db)
            try makeMeasurement(setId: "set1", kind: "weight", value: 225, unit: "lbs", role: "target").insert(db)
            try makeMeasurement(setId: "set1", kind: "reps", value: 5, unit: nil, role: "target").insert(db)
        }

        let snapshot = SyncSessionGuard.takeSnapshot()

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.measurementRows.count, 2)
    }

    func testSyncSessionGuardRestoresMeasurementsWhenSetsDeleted() throws {
        let dbQueue = try DatabaseManager.shared.database()

        try dbQueue.write { db in
            try makeSession(id: "s1", status: "in_progress").insert(db)
            try makeExercise(id: "e1", sessionId: "s1").insert(db)
            try makeSessionSetRow(id: "set1", exerciseId: "e1").insert(db)
            try makeMeasurement(setId: "set1", kind: "weight", value: 225, unit: "lbs", role: "target").insert(db)
            try makeMeasurement(setId: "set1", kind: "reps", value: 5, unit: nil, role: "target").insert(db)
            try makeMeasurement(setId: "set1", kind: "weight", value: 230, unit: "lbs", role: "actual").insert(db)
        }

        let snapshot = SyncSessionGuard.takeSnapshot()!
        XCTAssertEqual(snapshot.measurementRows.count, 3)

        // Simulate sync deleting the set and its measurements
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM set_measurements WHERE set_id = 'set1'")
            try db.execute(sql: "DELETE FROM session_sets WHERE id = 'set1'")
        }

        let intact = SyncSessionGuard.validateAndRestore(snapshot: snapshot)
        XCTAssertFalse(intact)

        // Verify set was restored
        let restoredSet = try dbQueue.read { db in
            try SessionSetRow.fetchOne(db, key: "set1")
        }
        XCTAssertNotNil(restoredSet)

        // Verify measurements were restored
        let restoredMeasurements = try dbQueue.read { db in
            try SetMeasurementRow
                .filter(Column("set_id") == "set1")
                .fetchAll(db)
        }
        XCTAssertEqual(restoredMeasurements.count, 3)
        let restoredKinds = restoredMeasurements.map { "\($0.role)_\($0.kind)" }
        XCTAssertTrue(restoredKinds.contains("target_weight"))
        XCTAssertTrue(restoredKinds.contains("target_reps"))
        XCTAssertTrue(restoredKinds.contains("actual_weight"))
    }

    func testSyncSessionGuardRestoresEntireSessionWithMeasurements() throws {
        let dbQueue = try DatabaseManager.shared.database()

        try dbQueue.write { db in
            try makeSession(id: "s1", status: "in_progress").insert(db)
            try makeExercise(id: "e1", sessionId: "s1").insert(db)
            try makeSessionSetRow(id: "set1", exerciseId: "e1").insert(db)
            try makeMeasurement(setId: "set1", kind: "weight", value: 225, unit: "lbs", role: "target").insert(db)
            try makeMeasurement(setId: "set1", kind: "reps", value: 5, unit: nil, role: "target").insert(db)
        }

        let snapshot = SyncSessionGuard.takeSnapshot()!

        // Nuke everything
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM set_measurements WHERE set_id = 'set1'")
            try db.execute(sql: "DELETE FROM session_sets WHERE id = 'set1'")
            try db.execute(sql: "DELETE FROM session_exercises WHERE id = 'e1'")
            try db.execute(sql: "DELETE FROM workout_sessions WHERE id = 's1'")
        }

        let intact = SyncSessionGuard.validateAndRestore(snapshot: snapshot)
        XCTAssertFalse(intact)

        // Verify full restoration including measurements
        let measurements = try dbQueue.read { db in
            try SetMeasurementRow
                .filter(Column("set_id") == "set1")
                .fetchAll(db)
        }
        XCTAssertEqual(measurements.count, 2)
    }

    // MARK: - Helpers

    /// One-exercise plan with two target sets (the first also has a target RPE).
    private func makeMeasurementTestPlan() -> WorkoutPlan {
        WorkoutPlan(
            name: "Measurement Test",
            exercises: [
                PlannedExercise(
                    workoutPlanId: "plan-1",
                    exerciseName: "Bench Press",
                    orderIndex: 0,
                    sets: [
                        PlannedSet(
                            plannedExerciseId: "pex-1",
                            orderIndex: 0,
                            targetWeight: 225,
                            targetWeightUnit: .lbs,
                            targetReps: 5,
                            targetRpe: 8
                        ),
                        PlannedSet(
                            plannedExerciseId: "pex-1",
                            orderIndex: 1,
                            targetWeight: 225,
                            targetWeightUnit: .lbs,
                            targetReps: 5
                        )
                    ]
                )
            ]
        )
    }

    /// Create a SetMeasurementRow for in-memory testing (no DB).
    private func makeRow(
        kind: String,
        value: Double,
        unit: String?,
        role: String,
        groupIndex: Int
    ) -> SetMeasurementRow {
        SetMeasurementRow(
            id: UUID().uuidString,
            setId: "set-1",
            parentType: "session",
            role: role,
            kind: kind,
            value: value,
            unit: unit,
            groupIndex: groupIndex,
            updatedAt: nil
        )
    }

    /// Create a SetMeasurementRow for DB insertion.
    private func makeMeasurement(
        setId: String,
        kind: String,
        value: Double,
        unit: String?,
        role: String,
        groupIndex: Int = 0
    ) -> SetMeasurementRow {
        SetMeasurementRow(
            id: UUID().uuidString,
            setId: setId,
            parentType: "session",
            role: role,
            kind: kind,
            value: value,
            unit: unit,
            groupIndex: groupIndex,
            updatedAt: nil
        )
    }

    private func makeSession(id: String, status: String) -> WorkoutSessionRow {
        WorkoutSessionRow(
            id: id, workoutTemplateId: nil, name: "Test Workout",
            date: "2026-04-16", status: status
        )
    }

    private func makeExercise(
        id: String, sessionId: String, orderIndex: Int = 0, name: String = "Bench Press"
    ) -> SessionExerciseRow {
        SessionExerciseRow(
            id: id, workoutSessionId: sessionId, exerciseName: name,
            orderIndex: orderIndex, status: "pending"
        )
    }

    private func makeSessionSetRow(id: String, exerciseId: String, orderIndex: Int = 0) -> SessionSetRow {
        SessionSetRow(
            id: id, sessionExerciseId: exerciseId, orderIndex: orderIndex,
            status: "pending", isDropset: 0, isPerSide: 0, isAmrap: 0
        )
    }

    // MARK: - Drop Set Round-Trip Regression

    func testDropSetFlagSurvivesPlanToSessionRoundTrip() throws {
        let markdown = """
        # Drop Set Test

        ## Lateral Raise
        - 25 lbs x 20 @dropset
        """
        let result = MarkdownParser.parseWorkout(markdown)
        XCTAssertTrue(result.success)
        let parsed = try XCTUnwrap(result.data)

        // Verify parser sets isDropset
        XCTAssertEqual(parsed.exercises.count, 1)
        XCTAssertEqual(parsed.exercises[0].sets.count, 1)
        XCTAssertTrue(parsed.exercises[0].sets[0].isDropset, "Parser should set isDropset=true")

        // Save as plan
        let plan = WorkoutPlan(
            name: parsed.name,
            sourceMarkdown: markdown,
            exercises: parsed.exercises
        )
        let planRepo = WorkoutPlanRepository()
        try planRepo.create(plan)

        // Fetch plan back and verify isDropset survived
        let fetchedPlan = try XCTUnwrap(planRepo.getById(plan.id))
        XCTAssertTrue(fetchedPlan.exercises[0].sets[0].isDropset, "isDropset should survive plan save/fetch")

        // Create session from plan
        let sessionRepo = SessionRepository()
        let (session, _) = try sessionRepo.createFromPlan(fetchedPlan)

        // Verify session set has isDropset
        XCTAssertEqual(session.exercises.count, 1)
        XCTAssertTrue(session.exercises[0].sets[0].isDropset, "isDropset should carry to session set")
    }
}

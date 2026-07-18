import XCTest
import GRDB
@testable import LiftMark

/// Tests for SyncSessionGuard — snapshot, validation, and restore of active workout sessions.
final class SyncSessionGuardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DatabaseManager.shared.deleteDatabase()
    }

    override func tearDown() {
        DatabaseManager.shared.deleteDatabase()
        super.tearDown()
    }

    // MARK: - Snapshot

    func testSnapshotCapturesActiveSessionWithCorrectCounts() throws {
        let dbQueue = try DatabaseManager.shared.database()

        try dbQueue.write { db in
            try makeSession(id: "s1", status: "in_progress").insert(db)
            try makeExercise(id: "e1", sessionId: "s1").insert(db)
            try makeExercise(id: "e2", sessionId: "s1", orderIndex: 1).insert(db)
            try makeSet(id: "set1", exerciseId: "e1").insert(db)
            try makeSet(id: "set2", exerciseId: "e1", orderIndex: 1).insert(db)
            try makeSet(id: "set3", exerciseId: "e2").insert(db)
        }

        let snapshot = SyncSessionGuard.takeSnapshot()

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.sessionRow.id, "s1")
        XCTAssertEqual(snapshot?.exerciseCount, 2)
        XCTAssertEqual(snapshot?.setCount, 3)
        XCTAssertEqual(snapshot?.exerciseIds, Set(["e1", "e2"]))
        XCTAssertEqual(snapshot?.setIds, Set(["set1", "set2", "set3"]))
    }

    func testSnapshotReturnsNilWhenNoActiveSession() throws {
        _ = try DatabaseManager.shared.database()

        let snapshot = SyncSessionGuard.takeSnapshot()
        XCTAssertNil(snapshot)
    }

    func testSnapshotExcludesCompletedSessions() throws {
        let dbQueue = try DatabaseManager.shared.database()

        try dbQueue.write { db in
            try makeSession(id: "done", status: "completed").insert(db)
            try makeExercise(id: "e1", sessionId: "done").insert(db)
            try makeSet(id: "set1", exerciseId: "e1").insert(db)
        }

        let snapshot = SyncSessionGuard.takeSnapshot()
        XCTAssertNil(snapshot)
    }

    // MARK: - Validate

    func testValidateReturnsTrueWhenSessionIntact() throws {
        let dbQueue = try DatabaseManager.shared.database()

        try dbQueue.write { db in
            try makeSession(id: "s1", status: "in_progress").insert(db)
            try makeExercise(id: "e1", sessionId: "s1").insert(db)
            try makeSet(id: "set1", exerciseId: "e1").insert(db)
        }

        let snapshot = SyncSessionGuard.takeSnapshot()!
        let intact = SyncSessionGuard.validateAndRestore(snapshot: snapshot)
        XCTAssertTrue(intact)
    }

    func testValidateDetectsAndRestoresMissingExercises() throws {
        let dbQueue = try DatabaseManager.shared.database()

        try dbQueue.write { db in
            try makeSession(id: "s1", status: "in_progress").insert(db)
            try makeExercise(id: "e1", sessionId: "s1").insert(db)
            try makeExercise(id: "e2", sessionId: "s1", orderIndex: 1).insert(db)
            try makeSet(id: "set1", exerciseId: "e1").insert(db)
        }

        let snapshot = SyncSessionGuard.takeSnapshot()!

        // Simulate sync deleting an exercise
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM session_exercises WHERE id = 'e2'")
        }

        let intact = SyncSessionGuard.validateAndRestore(snapshot: snapshot)
        XCTAssertFalse(intact)

        // Verify exercise was restored
        let restored = try dbQueue.read { db in
            try SessionExerciseRow.fetchOne(db, key: "e2")
        }
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.exerciseName, "Bench Press")
    }

    func testValidateDetectsAndRestoresMissingSets() throws {
        let dbQueue = try DatabaseManager.shared.database()

        try dbQueue.write { db in
            try makeSession(id: "s1", status: "in_progress").insert(db)
            try makeExercise(id: "e1", sessionId: "s1").insert(db)
            try makeSet(id: "set1", exerciseId: "e1").insert(db)
            try makeSet(id: "set2", exerciseId: "e1", orderIndex: 1).insert(db)
        }

        let snapshot = SyncSessionGuard.takeSnapshot()!

        // Simulate sync deleting a set
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM session_sets WHERE id = 'set2'")
        }

        let intact = SyncSessionGuard.validateAndRestore(snapshot: snapshot)
        XCTAssertFalse(intact)

        // Verify set was restored
        let restored = try dbQueue.read { db in
            try SessionSetRow.fetchOne(db, key: "set2")
        }
        XCTAssertNotNil(restored)
    }

    func testRestorePreservesNewlyAddedExercises() throws {
        let dbQueue = try DatabaseManager.shared.database()

        try dbQueue.write { db in
            try makeSession(id: "s1", status: "in_progress").insert(db)
            try makeExercise(id: "e1", sessionId: "s1").insert(db)
            try makeSet(id: "set1", exerciseId: "e1").insert(db)
        }

        let snapshot = SyncSessionGuard.takeSnapshot()!

        // User adds a new exercise during sync
        try dbQueue.write { db in
            try makeExercise(id: "e-new", sessionId: "s1", orderIndex: 1, name: "Squat").insert(db)
            try makeSet(id: "set-new", exerciseId: "e-new").insert(db)
        }

        let intact = SyncSessionGuard.validateAndRestore(snapshot: snapshot)
        XCTAssertTrue(intact)

        // Verify newly added exercise still exists (not deleted by guard)
        let newExercise = try dbQueue.read { db in
            try SessionExerciseRow.fetchOne(db, key: "e-new")
        }
        XCTAssertNotNil(newExercise)
        XCTAssertEqual(newExercise?.exerciseName, "Squat")
    }

    // MARK: - Helpers

    private func makeSession(id: String, status: String) -> WorkoutSessionRow {
        WorkoutSessionRow(
            id: id, workoutTemplateId: nil, name: "Test Workout",
            date: "2026-03-03", status: status
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

    private func makeSet(id: String, exerciseId: String, orderIndex: Int = 0) -> SessionSetRow {
        SessionSetRow(
            id: id, sessionExerciseId: exerciseId, orderIndex: orderIndex,
            status: "pending", isDropset: 0, isPerSide: 0, isAmrap: 0
        )
    }
}

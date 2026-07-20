import Foundation
import GRDB

/// Snapshot of an active workout session's database rows, used to detect and restore
/// data loss caused by sync operations.
struct SessionSnapshot {
    let sessionRow: WorkoutSessionRow
    let exerciseRows: [SessionExerciseRow]
    let setRows: [SessionSetRow]
    let measurementRows: [SetMeasurementRow]

    var exerciseIds: Set<String> { Set(exerciseRows.map(\.id)) }
    var setIds: Set<String> { Set(setRows.map(\.id)) }
    var exerciseCount: Int { exerciseRows.count }
    var setCount: Int { setRows.count }
}

/// Stateless guard that snapshots an active workout session before sync
/// and validates/restores it afterward. Prevents data loss regardless of
/// whether the underlying sync protection logic works correctly.
enum SyncSessionGuard {

    // MARK: - Snapshot

    /// Captures the current in-progress session and all its child rows.
    /// Returns nil if no active session exists.
    static func takeSnapshot() -> SessionSnapshot? {
        do {
            let dbQueue = try DatabaseManager.shared.database()
            let snapshot = try dbQueue.read { db -> SessionSnapshot? in
                guard let session = try WorkoutSessionRow
                    .filter(Column("status") == "in_progress")
                    .fetchOne(db)
                else {
                    return nil
                }

                let exercises = try SessionExerciseRow
                    .filter(Column("workout_session_id") == session.id)
                    .fetchAll(db)

                let exerciseIds = exercises.map(\.id)
                var sets: [SessionSetRow] = []
                var measurements: [SetMeasurementRow] = []
                if !exerciseIds.isEmpty {
                    sets = try SessionSetRow
                        .filter(exerciseIds.contains(Column("session_exercise_id")))
                        .fetchAll(db)
                    let setIds = sets.map(\.id)
                    if !setIds.isEmpty {
                        measurements = try SetMeasurementRow
                            .filter(setIds.contains(Column("set_id")))
                            .filter(Column("parent_type") == "session")
                            .fetchAll(db)
                    }
                }

                return SessionSnapshot(
                    sessionRow: session,
                    exerciseRows: exercises,
                    setRows: sets,
                    measurementRows: measurements
                )
            }

            // Log OUTSIDE the db read block to avoid reentrancy (Logger writes to the same DB)
            if let snapshot {
                Logger.shared.debug(.sync,
                    "[sync-guard] Snapshot: session=\(snapshot.sessionRow.id), " +
                        "exercises=\(snapshot.exerciseCount), sets=\(snapshot.setCount)")
            } else {
                Logger.shared.debug(.sync, "[sync-guard] No active session, skipping snapshot")
            }

            return snapshot
        } catch {
            Logger.shared.error(.sync, "[sync-guard] Failed to take snapshot: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Validate & Restore

    /// Compares current database state against the snapshot. If any exercise or set IDs
    /// from the snapshot are missing, restores them. Returns true if session was intact.
    @discardableResult
    static func validateAndRestore(snapshot: SessionSnapshot) -> Bool {
        do {
            let dbQueue = try DatabaseManager.shared.database()

            // Use a single write transaction for both validation and restore
            // to prevent user writes from interleaving between check and restore.
            let result: (missing: Bool, exerciseCount: Int, setCount: Int) = try dbQueue.write { db in
                try checkAndRestore(db: db, snapshot: snapshot)
            }

            // Log OUTSIDE db block to avoid reentrancy (Logger writes to the same DB)
            if result.missing {
                if result.exerciseCount > 0 || result.setCount > 0 {
                    Logger.shared.error(.sync,
                        "[sync-guard] DATA LOSS detected and RESTORED \(result.exerciseCount) exercises, " +
                            "\(result.setCount) sets")
                    let dataLossError = NSError(
                        domain: "LiftMark.SyncSessionGuard",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Data loss detected and restored"]
                    )
                    CrashReporter.shared.captureError(dataLossError, category: .sync, metadata: ["tag": "data_loss"])
                }
                return false
            } else {
                Logger.shared.debug(.sync,
                    "[sync-guard] Intact after sync: exercises=\(snapshot.exerciseCount), sets=\(snapshot.setCount)")
                return true
            }

        } catch {
            Logger.shared.error(.sync, "[sync-guard] RESTORE FAILED: \(error.localizedDescription)")
            CrashReporter.shared.captureError(error, category: .sync, metadata: ["tag": "data_loss_restore_failed"])
            return false
        }
    }

    // MARK: - Private (all run inside the single validate/restore write transaction)

    /// Validates the snapshot against the current database state and restores any missing
    /// rows. The comparison/decision order is behavior — preserved exactly: session gone →
    /// full restore; session canceled → no restore; otherwise restore missing exercises,
    /// then sets, then their measurements.
    private static func checkAndRestore(
        db: Database,
        snapshot: SessionSnapshot
    ) throws -> (missing: Bool, exerciseCount: Int, setCount: Int) {
        // Check session still exists
        let currentSession = try WorkoutSessionRow.fetchOne(db, key: snapshot.sessionRow.id)
        guard let currentSession else {
            try restoreEntireSession(db: db, snapshot: snapshot)
            return (missing: true, exerciseCount: snapshot.exerciseRows.count, setCount: snapshot.setRows.count)
        }

        // If the session was canceled since the snapshot was taken,
        // don't restore anything — the user intentionally discarded it.
        if currentSession.status == SessionStatus.canceled.rawValue {
            return (missing: false, exerciseCount: 0, setCount: 0)
        }

        // Find current exercise IDs
        let exerciseRows = try Row.fetchAll(
            db,
            sql: "SELECT id FROM session_exercises WHERE workout_session_id = ?",
            arguments: [snapshot.sessionRow.id]
        )
        let currentExIds = Set(exerciseRows.compactMap { $0["id"] as String? })
        let missingExercises = snapshot.exerciseRows.filter { !currentExIds.contains($0.id) }

        let missingSets = try findMissingSets(db: db, snapshot: snapshot)

        if missingExercises.isEmpty && missingSets.isEmpty {
            return (missing: false, exerciseCount: 0, setCount: 0)
        }

        try restoreMissingRows(db: db, snapshot: snapshot, exercises: missingExercises, sets: missingSets)
        return (missing: true, exerciseCount: missingExercises.count, setCount: missingSets.count)
    }

    /// Session row itself is gone — restore everything including measurements.
    private static func restoreEntireSession(db: Database, snapshot: SessionSnapshot) throws {
        try snapshot.sessionRow.insert(db)
        for exercise in snapshot.exerciseRows {
            try exercise.insert(db)
        }
        for set in snapshot.setRows {
            try set.insert(db)
        }
        for measurement in snapshot.measurementRows {
            try measurement.insert(db)
        }
    }

    /// Find current set IDs under the snapshot's exercises; returns the snapshot sets
    /// whose IDs are no longer present.
    private static func findMissingSets(db: Database, snapshot: SessionSnapshot) throws -> [SessionSetRow] {
        let snapshotExerciseIds = snapshot.exerciseRows.map(\.id)
        guard !snapshotExerciseIds.isEmpty else { return [] }
        let placeholders = snapshotExerciseIds.map { _ in "?" }.joined(separator: ",")
        let setRows = try Row.fetchAll(
            db,
            sql: "SELECT id FROM session_sets WHERE session_exercise_id IN (\(placeholders))",
            arguments: StatementArguments(snapshotExerciseIds)
        )
        let currentSetIds = Set(setRows.compactMap { $0["id"] as String? })
        return snapshot.setRows.filter { !currentSetIds.contains($0.id) }
    }

    /// Restore missing rows within this same transaction.
    /// Use snapshot values (pre-sync) which preserves the user's local changes.
    private static func restoreMissingRows(
        db: Database,
        snapshot: SessionSnapshot,
        exercises missingExercises: [SessionExerciseRow],
        sets missingSets: [SessionSetRow]
    ) throws {
        for exercise in missingExercises {
            try exercise.insert(db)
        }
        let missingSetIds = Set(missingSets.map(\.id))
        for set in missingSets {
            try set.insert(db)
        }
        // Restore measurements for any restored sets
        let missingMeasurements = snapshot.measurementRows.filter { missingSetIds.contains($0.setId) }
        for measurement in missingMeasurements {
            try measurement.insert(db)
        }
    }
}

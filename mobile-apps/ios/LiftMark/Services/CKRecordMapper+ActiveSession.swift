import CloudKit
import GRDB

// MARK: - Active Session Protection

extension CKRecordMapper {

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

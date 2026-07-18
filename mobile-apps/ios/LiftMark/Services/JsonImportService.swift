import Foundation
import GRDB

/// Errors thrown during JSON import operations.
enum JsonImportError: LocalizedError {
    case invalidFormat(String)
    case unsupportedVersion(String)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let reason):
            return "Invalid import file: \(reason)"
        case .unsupportedVersion(let version):
            return "Unsupported format version: \(version)"
        case .importFailed(let reason):
            return "Import failed: \(reason)"
        }
    }
}

/// Bundles the JSON key names used to extract measurement values from set data.
struct MeasurementKeyMap {
    let weightKey: String
    let weightUnitKey: String
    let repsKey: String
    let timeKey: String
    let rpeKey: String

    static let targetKeys = MeasurementKeyMap(
        weightKey: "targetWeight", weightUnitKey: "targetWeightUnit",
        repsKey: "targetReps", timeKey: "targetTime", rpeKey: "targetRpe"
    )

    static let actualKeys = MeasurementKeyMap(
        weightKey: "actualWeight", weightUnitKey: "actualWeightUnit",
        repsKey: "actualReps", timeKey: "actualTime", rpeKey: "actualRpe"
    )
}

/// Bundles the identity and classification context for a set measurement.
struct MeasurementContext {
    let setId: String
    let parentType: String
    let role: String
}

/// Service for importing unified JSON exports into the database.
/// Uses merge semantics: skips duplicates by name+date for sessions, name for plans.
struct JsonImportService {

    struct ImportResult {
        var plansImported: Int = 0
        var plansSkipped: Int = 0
        var sessionsImported: Int = 0
        var sessionsSkipped: Int = 0
        var gymsImported: Int = 0
        var gymsSkipped: Int = 0

        var summary: String {
            var parts: [String] = []
            if plansImported > 0 { parts.append("\(plansImported) plans imported") }
            if plansSkipped > 0 { parts.append("\(plansSkipped) plans skipped (duplicates)") }
            if sessionsImported > 0 { parts.append("\(sessionsImported) sessions imported") }
            if sessionsSkipped > 0 { parts.append("\(sessionsSkipped) sessions skipped (duplicates)") }
            if gymsImported > 0 { parts.append("\(gymsImported) gyms imported") }
            if gymsSkipped > 0 { parts.append("\(gymsSkipped) gyms skipped (duplicates)") }
            return parts.isEmpty ? "No data to import." : parts.joined(separator: "\n")
        }
    }

    /// Validate and import a unified JSON file.
    func importUnifiedJson(from url: URL) throws -> ImportResult {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JsonImportError.invalidFormat("File is not valid JSON.")
        }

        // Check format version if present
        if let version = json["formatVersion"] as? String, version != "1.0" {
            throw JsonImportError.unsupportedVersion(version)
        }

        var result = ImportResult()

        try DatabaseManager.shared.database().write { db in
            // Import plans
            if let plans = json["plans"] as? [[String: Any]] {
                for planData in plans {
                    try importPlan(planData, into: db, result: &result)
                }
            }

            // Import sessions
            if let sessions = json["sessions"] as? [[String: Any]] {
                for sessionData in sessions {
                    try importSession(sessionData, into: db, result: &result)
                }
            }

            // Also handle single session format (from single-session exports)
            if let sessionData = json["session"] as? [String: Any] {
                try importSession(sessionData, into: db, result: &result)
            }

            // Import gyms
            if let gyms = json["gyms"] as? [[String: Any]] {
                for gymData in gyms {
                    try importGym(gymData, into: db, result: &result)
                }
            }
        }

        return result
    }

    /// Check if a file at the given URL is a valid LiftMark JSON export.
    func validateJsonFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        // Must have at least one of: plans, sessions, session
        return json["plans"] != nil || json["sessions"] != nil || json["session"] != nil
    }

    // MARK: - Private Import Helpers

    private func importPlan(_ data: [String: Any], into db: Database, result: inout ImportResult) throws {
        guard let name = data["name"] as? String else { return }

        // Check for duplicate by name
        let existingCount = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM workout_templates WHERE name = ?", arguments: [name]) ?? 0
        if existingCount > 0 {
            result.plansSkipped += 1
            return
        }

        let planId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let tags = (data["tags"] as? [String]) ?? []
        let tagsJson = (try? JSONSerialization.data(withJSONObject: tags))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try db.execute(sql: """
            INSERT INTO workout_templates (id, name, description, tags, default_weight_unit, \
            source_markdown, created_at, updated_at, is_favorite)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                planId,
                name,
                data["description"] as? String,
                tagsJson,
                data["defaultWeightUnit"] as? String,
                data["sourceMarkdown"] as? String,
                now,
                now,
                (data["isFavorite"] as? Bool) == true ? 1 : 0
            ])

        // Import exercises
        if let exercises = data["exercises"] as? [[String: Any]] {
            // First pass: create exercises and track ID mapping for parent references
            var exerciseIdMap: [Int: String] = [:] // orderIndex -> new ID
            for exerciseData in exercises {
                let exerciseId = UUID().uuidString
                let orderIndex = exerciseData["orderIndex"] as? Int ?? 0
                exerciseIdMap[orderIndex] = exerciseId

                try db.execute(sql: """
                    INSERT INTO template_exercises (id, workout_template_id, exercise_name, order_index, notes, \
                    equipment_type, group_type, group_name, parent_exercise_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        exerciseId,
                        planId,
                        exerciseData["exerciseName"] as? String ?? "Unknown",
                        orderIndex,
                        exerciseData["notes"] as? String,
                        exerciseData["equipmentType"] as? String,
                        exerciseData["groupType"] as? String,
                        exerciseData["groupName"] as? String,
                        nil as String? // parent resolved in second pass
                    ])

                // Import sets
                if let sets = exerciseData["sets"] as? [[String: Any]] {
                    for setData in sets {
                        let setId = UUID().uuidString
                        try db.execute(sql: """
                            INSERT INTO template_sets (id, template_exercise_id, order_index,
                                rest_seconds, is_dropset, is_per_side, is_amrap, notes, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [
                                setId,
                                exerciseId,
                                setData["orderIndex"] as? Int ?? 0,
                                setData["restSeconds"] as? Int,
                                (setData["isDropset"] as? Bool) == true ? 1 : 0,
                                (setData["isPerSide"] as? Bool) == true ? 1 : 0,
                                (setData["isAmrap"] as? Bool) == true ? 1 : 0,
                                setData["notes"] as? String,
                                now
                            ])

                        // Insert target measurements into set_measurements
                        let context = MeasurementContext(setId: setId, parentType: "planned", role: "target")
                        try insertMeasurementsFromJson(setData, into: db, context: context, keyMap: .targetKeys)
                    }
                }
            }
        }

        result.plansImported += 1
    }

    private func importSession(_ data: [String: Any], into db: Database, result: inout ImportResult) throws {
        guard let name = data["name"] as? String,
              let date = data["date"] as? String else { return }

        // Check for duplicate by name + date
        let existingCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM workout_sessions WHERE name = ? AND date = ?",
            arguments: [name, date]
        ) ?? 0
        if existingCount > 0 {
            result.sessionsSkipped += 1
            return
        }

        let sessionId = UUID().uuidString

        try db.execute(sql: """
            INSERT INTO workout_sessions (id, workout_template_id, name, date, start_time, end_time, duration, \
            notes, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                sessionId,
                nil as String?,
                name,
                date,
                data["startTime"] as? String,
                data["endTime"] as? String,
                data["duration"] as? Int,
                data["notes"] as? String,
                data["status"] as? String ?? "completed"
            ])

        // Import exercises
        if let exercises = data["exercises"] as? [[String: Any]] {
            for exerciseData in exercises {
                let exerciseId = UUID().uuidString

                try db.execute(sql: """
                    INSERT INTO session_exercises (id, workout_session_id, exercise_name, order_index, notes, \
                    equipment_type, group_type, group_name, parent_exercise_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        exerciseId,
                        sessionId,
                        exerciseData["exerciseName"] as? String ?? "Unknown",
                        exerciseData["orderIndex"] as? Int ?? 0,
                        exerciseData["notes"] as? String,
                        exerciseData["equipmentType"] as? String,
                        exerciseData["groupType"] as? String,
                        exerciseData["groupName"] as? String,
                        nil as String?
                    ])

                // Import sets
                if let sets = exerciseData["sets"] as? [[String: Any]] {
                    for setData in sets {
                        let setId = UUID().uuidString
                        try db.execute(sql: """
                            INSERT INTO session_sets (id, session_exercise_id, order_index,
                                rest_seconds, completed_at, status, notes, is_dropset, is_per_side,
                                is_amrap, side, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [
                                setId,
                                exerciseId,
                                setData["orderIndex"] as? Int ?? 0,
                                setData["restSeconds"] as? Int,
                                setData["completedAt"] as? String,
                                setData["status"] as? String ?? "completed",
                                setData["notes"] as? String,
                                (setData["isDropset"] as? Bool) == true ? 1 : 0,
                                (setData["isPerSide"] as? Bool) == true ? 1 : 0,
                                (setData["isAmrap"] as? Bool) == true ? 1 : 0,
                                setData["side"] as? String,
                                ISO8601DateFormatter().string(from: Date())
                            ])

                        // Insert target measurements into set_measurements
                        let targetCtx = MeasurementContext(setId: setId, parentType: "session", role: "target")
                        try insertMeasurementsFromJson(setData, into: db, context: targetCtx, keyMap: .targetKeys)

                        // Insert actual measurements into set_measurements
                        let actualCtx = MeasurementContext(setId: setId, parentType: "session", role: "actual")
                        try insertMeasurementsFromJson(setData, into: db, context: actualCtx, keyMap: .actualKeys)
                    }
                }
            }
        }

        result.sessionsImported += 1
    }

    private func importGym(_ data: [String: Any], into db: Database, result: inout ImportResult) throws {
        guard let name = data["name"] as? String else { return }

        // Check for duplicate by name
        let existingCount = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM gyms WHERE name = ?", arguments: [name]) ?? 0
        if existingCount > 0 {
            result.gymsSkipped += 1
            return
        }

        let now = ISO8601DateFormatter().string(from: Date())
        try db.execute(sql: """
            INSERT INTO gyms (id, name, is_default, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                UUID().uuidString,
                name,
                0, // Not default
                now,
                now
            ])

        result.gymsImported += 1
    }

    /// Insert measurement rows from JSON set data into set_measurements.
    /// Each non-nil measurement value (weight, reps, time, rpe) gets its own row.
    private func insertMeasurementsFromJson(
        _ setData: [String: Any],
        into db: Database,
        context: MeasurementContext,
        keyMap: MeasurementKeyMap
    ) throws {
        if let weight = setData[keyMap.weightKey] as? Double {
            let unit = setData[keyMap.weightUnitKey] as? String
            try insertMeasurement(into: db, setId: context.setId, parentType: context.parentType,
                                  role: context.role, kind: "weight", value: weight, unit: unit)
        }
        if let reps = setData[keyMap.repsKey] as? Int {
            try insertMeasurement(into: db, setId: context.setId, parentType: context.parentType,
                                  role: context.role, kind: "reps", value: Double(reps), unit: nil)
        }
        if let time = setData[keyMap.timeKey] as? Int {
            try insertMeasurement(into: db, setId: context.setId, parentType: context.parentType,
                                  role: context.role, kind: "time", value: Double(time), unit: "s")
        }
        if let rpe = setData[keyMap.rpeKey] as? Int {
            try insertMeasurement(into: db, setId: context.setId, parentType: context.parentType,
                                  role: context.role, kind: "rpe", value: Double(rpe), unit: nil)
        }
    }

    private func insertMeasurement(
        into db: Database,
        setId: String,
        parentType: String,
        role: String,
        kind: String,
        value: Double,
        unit: String?
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO set_measurements (id, set_id, parent_type, role, kind, value, unit, group_index, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
                """,
            arguments: [UUID().uuidString, setId, parentType, role, kind, value, unit,
                        ISO8601DateFormatter().string(from: Date())]
        )
    }
}

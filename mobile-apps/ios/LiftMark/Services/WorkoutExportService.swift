import Foundation
import GRDB

/// Errors thrown during workout export operations.
enum ExportError: LocalizedError, Equatable {
    case noCompletedWorkouts
    case noMarkdownSource
    case fileWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCompletedWorkouts:
            return "No completed workouts to export."
        case .noMarkdownSource:
            return "No markdown source available."
        case .fileWriteFailed(let reason):
            return "Failed to write export file: \(reason)"
        }
    }
}

/// Service for exporting workout sessions as portable JSON files.
/// Strips internal database IDs to produce clean, shareable data.
struct WorkoutExportService {
    private let repository = SessionRepository()

    /// Export all completed sessions to a single JSON file.
    /// Returns the file URL for sharing.
    func exportSessionsAsJson() throws -> URL {
        let sessions = try repository.getCompleted()

        guard !sessions.isEmpty else {
            throw ExportError.noCompletedWorkouts
        }

        let exportData: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": appVersion(),
            "sessions": sessions.map { stripSession($0) }
        ]

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .replacingOccurrences(of: "Z", with: "")
        let fileName = "liftmark_workouts_\(timestamp).json"

        return try writeExportFile(exportData, fileName: fileName)
    }

    /// Export a single workout session as a portable JSON file.
    /// Returns the file URL for sharing.
    func exportSingleSessionAsJson(_ session: WorkoutSession) throws -> URL {
        let fileName = buildSessionFileName(name: session.name, date: session.date)
        return try writeExportFile(buildSingleSessionPayload(session), fileName: fileName)
    }

    /// Single-session payload as an in-memory dictionary — the same shape
    /// `exportSingleSessionAsJson` writes to disk. Used by OutboxPusherService
    /// to POST a completed session to the server outbox without round-tripping
    /// through the filesystem. See `spec/services/workout-outbox.md`.
    func buildSingleSessionPayload(_ session: WorkoutSession) -> [String: Any] {
        return [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": appVersion(),
            "session": stripSession(session)
        ]
    }

    /// Sanitize a display name into a filename-safe slug:
    /// lowercase, accents stripped, special chars removed, spaces → hyphens,
    /// truncated to 50 chars.
    func sanitizeName(_ name: String) -> String {
        var sanitized = name.lowercased()
        sanitized = sanitized.folding(options: .diacriticInsensitive, locale: .current)
        sanitized = sanitized.replacingOccurrences(
            of: "[^a-z0-9\\s-]",
            with: "",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: "\\s+",
            with: "-",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression
        )
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if sanitized.count > 50 {
            sanitized = String(sanitized.prefix(50))
        }
        return sanitized
    }

    /// Build a sanitized file name: workout-{name}-{date}.json
    func buildSessionFileName(name: String, date: String) -> String {
        let sanitized = sanitizeName(name)
        let datePart = date.split(separator: "T").first.map(String.init)
            ?? ISO8601DateFormatter().string(from: Date()).split(separator: "T").first.map(String.init)
            ?? "unknown"
        let namePart = sanitized.isEmpty ? "workout" : sanitized

        return "workout-\(namePart)-\(datePart).json"
    }

    /// Build a sanitized file name for a plan markdown export: plan-{name}.md
    func buildPlanFileName(name: String) -> String {
        let sanitized = sanitizeName(name)
        let namePart = sanitized.isEmpty ? "workout" : sanitized
        return "plan-\(namePart).md"
    }

    /// Export a workout plan's original LMWF markdown source as a `.md` file.
    /// Returns the file URL for sharing. Throws `ExportError.noMarkdownSource`
    /// when the plan has no `sourceMarkdown` (e.g. it was built without an
    /// original markdown source). See `spec/services/export.md`.
    func exportPlanAsMarkdown(_ plan: WorkoutPlan) throws -> URL {
        guard let markdown = plan.sourceMarkdown, !markdown.isEmpty else {
            throw ExportError.noMarkdownSource
        }
        let fileName = buildPlanFileName(name: plan.name)
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw ExportError.fileWriteFailed("Cache directory is unavailable")
        }
        let fileURL = cacheDir.appendingPathComponent(fileName)
        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.fileWriteFailed(error.localizedDescription)
        }
        return fileURL
    }

    /// Export all app data as a unified JSON file for backup/transfer.
    /// Includes plans, sessions, gyms, and safe settings (no API keys).
    func exportUnifiedJson() throws -> URL {
        let planRepo = WorkoutPlanRepository()
        let plans = try planRepo.getAll()
        let sessions = try repository.getCompleted()

        // Read gyms directly from database
        let gyms: [[String: Any]] = (try? DatabaseManager.shared.database().read { db -> [[String: Any]] in
            let tableExists = try Bool.fetchOne(
                db, sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='gyms'") ?? false
            guard tableExists else { return [] }

            let rows = try Row.fetchAll(db, sql: "SELECT * FROM gyms")
            return rows.map { row in
                var dict: [String: Any] = [
                    "name": (row["name"] as? String) ?? "",
                    "isDefault": ((row["is_default"] as? Int) ?? 0) == 1
                ]
                if let createdAt = row["created_at"] as? String { dict["createdAt"] = createdAt }
                return dict
            }
        }) ?? []

        // Read settings (strip sensitive data)
        let settings: [String: Any] = (try? DatabaseManager.shared.database().read { db in
            // Check if settings table exists
            let tableExists = try Bool.fetchOne(
                db, sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='settings'") ?? false
            guard tableExists else { return [:] as [String: Any] }

            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM settings LIMIT 1") else {
                return [:] as [String: Any]
            }
            var dict: [String: Any] = [:]
            if let unit = row["default_weight_unit"] as? String { dict["defaultWeightUnit"] = unit }
            if let flag = row["enable_workout_timer"] as? Int { dict["enableWorkoutTimer"] = flag == 1 }
            if let flag = row["auto_start_rest_timer"] as? Int { dict["autoStartRestTimer"] = flag == 1 }
            if let theme = row["theme"] as? String { dict["theme"] = theme }
            if let flag = row["keep_screen_awake"] as? Int { dict["keepScreenAwake"] = flag == 1 }
            if let prompt = row["custom_prompt_addition"] as? String { dict["customPromptAddition"] = prompt }
            return dict
        }) ?? [:]

        let exportData: [String: Any] = [
            "formatVersion": "1.0",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": appVersion(),
            "plans": plans.map { stripPlan($0) },
            "sessions": sessions.map { stripSession($0) },
            "gyms": gyms,
            "settings": settings
        ]

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .replacingOccurrences(of: "Z", with: "")
        let fileName = "liftmark_export_\(timestamp).json"

        return try writeExportFile(exportData, fileName: fileName)
    }

    // MARK: - Private

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private func writeExportFile(_ data: [String: Any], fileName: String) throws -> URL {
        let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw ExportError.fileWriteFailed("Cache directory is unavailable")
        }
        let fileURL = cacheDir.appendingPathComponent(fileName)
        try jsonData.write(to: fileURL)
        return fileURL
    }

    private func stripPlan(_ plan: WorkoutPlan) -> [String: Any] {
        var dict: [String: Any] = [
            "name": plan.name,
            "exercises": plan.exercises.filter { !$0.sets.isEmpty || $0.groupType != nil }
                .map { stripPlannedExercise($0) }
        ]
        if let desc = plan.description { dict["description"] = desc }
        if !plan.tags.isEmpty { dict["tags"] = plan.tags }
        if let unit = plan.defaultWeightUnit { dict["defaultWeightUnit"] = unit.rawValue }
        if let md = plan.sourceMarkdown { dict["sourceMarkdown"] = md }
        dict["isFavorite"] = plan.isFavorite
        return dict
    }

    private func stripPlannedExercise(_ exercise: PlannedExercise) -> [String: Any] {
        var dict: [String: Any] = [
            "exerciseName": exercise.exerciseName,
            "orderIndex": exercise.orderIndex,
            "sets": exercise.sets.map { stripPlannedSet($0) }
        ]
        if let notes = exercise.notes { dict["notes"] = notes }
        if let equip = exercise.equipmentType { dict["equipmentType"] = equip }
        if let gt = exercise.groupType { dict["groupType"] = gt.rawValue }
        if let gn = exercise.groupName { dict["groupName"] = gn }
        return dict
    }

    private func stripPlannedSet(_ set: PlannedSet) -> [String: Any] {
        var dict: [String: Any] = [
            "orderIndex": set.orderIndex,
            "isDropset": set.isDropset,
            "isPerSide": set.isPerSide,
            "isAmrap": set.isAmrap
        ]
        addMeasurements(set.entries.first?.target, keys: .targetKeys, into: &dict)
        if let rest = set.restSeconds { dict["restSeconds"] = rest }
        if let notes = set.notes { dict["notes"] = notes }
        return dict
    }

    private func stripSession(_ session: WorkoutSession) -> [String: Any] {
        var dict: [String: Any] = [
            "name": session.name,
            "date": session.date,
            "status": session.status.rawValue,
            "exercises": session.exercises.map { stripExercise($0) }
        ]
        if let startTime = session.startTime { dict["startTime"] = startTime }
        if let endTime = session.endTime { dict["endTime"] = endTime }
        if let duration = session.duration { dict["duration"] = duration }
        if let notes = session.notes { dict["notes"] = notes }
        return dict
    }

    private func stripExercise(_ exercise: SessionExercise) -> [String: Any] {
        var dict: [String: Any] = [
            "exerciseName": exercise.exerciseName,
            "orderIndex": exercise.orderIndex,
            "status": exercise.status.rawValue,
            "sets": exercise.sets.map { stripSet($0) }
        ]
        if let notes = exercise.notes { dict["notes"] = notes }
        if let equipmentType = exercise.equipmentType { dict["equipmentType"] = equipmentType }
        if let groupType = exercise.groupType { dict["groupType"] = groupType.rawValue }
        if let groupName = exercise.groupName { dict["groupName"] = groupName }
        return dict
    }

    private func stripSet(_ set: SessionSet) -> [String: Any] {
        let entry = set.entries.first

        var dict: [String: Any] = [
            "orderIndex": set.orderIndex,
            "status": set.status.rawValue,
            "isDropset": set.isDropset,
            "isPerSide": set.isPerSide
        ]
        addMeasurements(entry?.target, keys: .targetKeys, into: &dict)
        if let rest = set.restSeconds { dict["restSeconds"] = rest }
        addMeasurements(entry?.actual, keys: .actualKeys, into: &dict)
        if let completedAt = set.completedAt { dict["completedAt"] = completedAt }
        if let notes = set.notes { dict["notes"] = notes }
        return dict
    }

    /// Merge one role's measurement values (weight/reps/time/rpe) into an export
    /// dictionary under the JSON keys named by `keys` (target* or actual*).
    private func addMeasurements(_ values: EntryValues?, keys: MeasurementKeyMap, into dict: inout [String: Any]) {
        guard let values else { return }
        if let weight = values.weight?.value { dict[keys.weightKey] = weight }
        if let unit = values.weight?.unit { dict[keys.weightUnitKey] = unit.rawValue }
        if let reps = values.reps { dict[keys.repsKey] = reps }
        if let time = values.time { dict[keys.timeKey] = time }
        if let rpe = values.rpe { dict[keys.rpeKey] = rpe }
    }
}

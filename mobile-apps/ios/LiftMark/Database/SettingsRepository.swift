import Foundation
import GRDB

/// Repository for UserSettings CRUD operations.
struct SettingsRepository {
    private let dbManager: DatabaseManager

    init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    // MARK: - Read

    func get() throws -> UserSettings? {
        let dbQueue = try dbManager.database()
        let row = try dbQueue.read { db in
            try UserSettingsRow.fetchOne(db)
        }
        guard let row else { return nil }
        return assembleSettings(from: row)
    }

    // MARK: - Write

    func update(_ settings: UserSettings) throws {
        let dbQueue = try dbManager.database()
        let arguments = Self.updateArguments(for: settings)
        try dbQueue.write { db in
            try db.execute(sql: Self.updateSQL, arguments: arguments)
        }
    }

    private static let updateSQL = """
        UPDATE user_settings SET
            default_weight_unit = ?,
            enable_workout_timer = ?,
            auto_start_rest_timer = ?,
            theme = ?,
            notifications_enabled = ?,
            custom_prompt_addition = ?,
            anthropic_api_key_status = ?,
            healthkit_enabled = ?,
            live_activities_enabled = ?,
            keep_screen_awake = ?,
            show_open_in_claude_button = ?,
            developer_mode_enabled = ?,
            countdown_sounds_enabled = ?,
            has_accepted_disclaimer = ?,
            default_timer_countdown = ?,
            default_weight_step_lbs = ?,
            ai_prompt_include_format_pointer = ?,
            ai_prompt_include_recent_workouts = ?,
            ai_prompt_include_progression = ?,
            ai_prompt_include_equipment = ?,
            home_tiles = ?,
            updated_at = ?
        WHERE id = ?
    """

    /// Builds the positional arguments for `updateSQL` — order must match the
    /// SET clause column order exactly.
    private static func updateArguments(for settings: UserSettings) -> StatementArguments {
        let now = ISO8601DateFormatter().string(from: Date())
        let homeTilesJSON = settings.homeTiles.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        return [
            settings.defaultWeightUnit.rawValue,
            settings.enableWorkoutTimer ? 1 : 0,
            settings.autoStartRestTimer ? 1 : 0,
            settings.theme.rawValue,
            settings.notificationsEnabled ? 1 : 0,
            settings.customPromptAddition,
            settings.anthropicApiKeyStatus?.rawValue,
            settings.healthKitEnabled ? 1 : 0,
            settings.liveActivitiesEnabled ? 1 : 0,
            settings.keepScreenAwake ? 1 : 0,
            settings.showOpenInClaudeButton ? 1 : 0,
            settings.developerModeEnabled ? 1 : 0,
            settings.countdownSoundsEnabled ? 1 : 0,
            settings.hasAcceptedDisclaimer ? 1 : 0,
            settings.defaultTimerCountdown ? 1 : 0,
            settings.defaultWeightStepLbs,
            settings.aiPromptIncludeFormatPointer ? 1 : 0,
            settings.aiPromptIncludeRecentWorkouts ? 1 : 0,
            settings.aiPromptIncludeProgression ? 1 : 0,
            settings.aiPromptIncludeEquipment ? 1 : 0,
            homeTilesJSON,
            now,
            settings.id
        ]
    }

    // MARK: - Assembly

    private func assembleSettings(from row: UserSettingsRow) -> UserSettings {
        UserSettings(
            id: row.id,
            defaultWeightUnit: WeightUnit(rawValue: row.defaultWeightUnit) ?? .lbs,
            enableWorkoutTimer: row.enableWorkoutTimer != 0,
            autoStartRestTimer: row.autoStartRestTimer != 0,
            theme: AppTheme(rawValue: row.theme) ?? .auto,
            notificationsEnabled: row.notificationsEnabled != 0,
            customPromptAddition: row.customPromptAddition,
            anthropicApiKey: nil, // Stored in Keychain
            anthropicApiKeyStatus: row.anthropicApiKeyStatus.flatMap { ApiKeyStatus(rawValue: $0) },
            healthKitEnabled: row.healthkitEnabled != 0,
            liveActivitiesEnabled: row.liveActivitiesEnabled != 0,
            keepScreenAwake: row.keepScreenAwake != 0,
            showOpenInClaudeButton: row.showOpenInClaudeButton != 0,
            developerModeEnabled: row.developerModeEnabled != 0,
            countdownSoundsEnabled: row.countdownSoundsEnabled != 0,
            hasAcceptedDisclaimer: row.hasAcceptedDisclaimer != 0,
            defaultTimerCountdown: row.defaultTimerCountdown != 0,
            defaultWeightStepLbs: row.defaultWeightStepLbs,
            aiPromptIncludeFormatPointer: row.aiPromptIncludeFormatPointer != 0,
            aiPromptIncludeRecentWorkouts: row.aiPromptIncludeRecentWorkouts != 0,
            aiPromptIncludeProgression: row.aiPromptIncludeProgression != 0,
            aiPromptIncludeEquipment: row.aiPromptIncludeEquipment != 0,
            homeTiles: row.homeTiles.flatMap { data in
                (try? JSONDecoder().decode([String].self, from: Data(data.utf8)))
            },
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }
}

import Foundation

extension DatabaseSeeds {

    // MARK: - Synthetic future (v18) — used to verify early-return behavior
    //
    // File is named V14SyntheticSeed.swift for historical reasons; the seed now
    // represents a "from the future" DB at schema_version=18. DDL matches the
    // current head (v17, which added outbox_pending_queue) so the shape is
    // valid — only the version marker is ahead.

    static let v17SyntheticDDL: String = #"""
    CREATE TABLE workout_templates (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT, tags TEXT,
        default_weight_unit TEXT, source_markdown TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, is_favorite INTEGER DEFAULT 0
    );
    CREATE TABLE template_exercises (
        id TEXT PRIMARY KEY, workout_template_id TEXT NOT NULL, exercise_name TEXT NOT NULL,
        order_index INTEGER NOT NULL, notes TEXT, equipment_type TEXT, group_type TEXT,
        group_name TEXT, parent_exercise_id TEXT, updated_at TEXT,
        FOREIGN KEY (workout_template_id) REFERENCES workout_templates(id) ON DELETE CASCADE,
        FOREIGN KEY (parent_exercise_id) REFERENCES template_exercises(id) ON DELETE CASCADE
    );
    CREATE TABLE template_sets (
        id TEXT PRIMARY KEY, template_exercise_id TEXT NOT NULL, order_index INTEGER NOT NULL,
        rest_seconds INTEGER,
        is_dropset INTEGER DEFAULT 0, is_per_side INTEGER DEFAULT 0, is_amrap INTEGER DEFAULT 0,
        notes TEXT, updated_at TEXT,
        FOREIGN KEY (template_exercise_id) REFERENCES template_exercises(id) ON DELETE CASCADE
    );
    CREATE TABLE user_settings (
        id TEXT PRIMARY KEY, default_weight_unit TEXT NOT NULL DEFAULT 'lbs',
        enable_workout_timer INTEGER DEFAULT 1, auto_start_rest_timer INTEGER DEFAULT 1,
        theme TEXT DEFAULT 'auto', notifications_enabled INTEGER DEFAULT 1,
        custom_prompt_addition TEXT,
        anthropic_api_key_status TEXT DEFAULT 'not_set',
        healthkit_enabled INTEGER DEFAULT 0, live_activities_enabled INTEGER DEFAULT 1,
        keep_screen_awake INTEGER DEFAULT 1, show_open_in_claude_button INTEGER DEFAULT 0,
        home_tiles TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        developer_mode_enabled INTEGER DEFAULT 0,
        countdown_sounds_enabled INTEGER DEFAULT 1,
        has_accepted_disclaimer INTEGER DEFAULT 0,
        default_timer_countdown INTEGER DEFAULT 0,
        default_weight_step_lbs REAL DEFAULT 2.5,
        ai_prompt_include_format_pointer INTEGER DEFAULT 1,
        ai_prompt_include_recent_workouts INTEGER DEFAULT 1,
        ai_prompt_include_progression INTEGER DEFAULT 1,
        ai_prompt_include_equipment INTEGER DEFAULT 1
    );
    CREATE TABLE gyms (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, is_default INTEGER DEFAULT 0,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
    );
    CREATE TABLE gym_equipment (
        id TEXT PRIMARY KEY, name TEXT NOT NULL,
        is_available INTEGER DEFAULT 1, last_checked_at TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        gym_id TEXT, deleted_at TEXT,
        FOREIGN KEY (gym_id) REFERENCES gyms(id) ON DELETE CASCADE,
        UNIQUE (gym_id, name)
    );
    CREATE TABLE workout_sessions (
        id TEXT PRIMARY KEY, workout_template_id TEXT, name TEXT NOT NULL, date TEXT NOT NULL,
        start_time TEXT, end_time TEXT, duration INTEGER, notes TEXT,
        status TEXT NOT NULL DEFAULT 'in_progress', updated_at TEXT,
        FOREIGN KEY (workout_template_id) REFERENCES workout_templates(id) ON DELETE SET NULL
    );
    CREATE TABLE session_exercises (
        id TEXT PRIMARY KEY, workout_session_id TEXT NOT NULL, exercise_name TEXT NOT NULL,
        order_index INTEGER NOT NULL, notes TEXT, equipment_type TEXT, group_type TEXT,
        group_name TEXT, parent_exercise_id TEXT, status TEXT NOT NULL DEFAULT 'pending', updated_at TEXT,
        FOREIGN KEY (workout_session_id) REFERENCES workout_sessions(id) ON DELETE CASCADE,
        FOREIGN KEY (parent_exercise_id) REFERENCES session_exercises(id) ON DELETE CASCADE
    );
    CREATE TABLE session_sets (
        id TEXT PRIMARY KEY, session_exercise_id TEXT NOT NULL, order_index INTEGER NOT NULL,
        rest_seconds INTEGER, completed_at TEXT, status TEXT NOT NULL DEFAULT 'pending',
        notes TEXT,
        is_dropset INTEGER DEFAULT 0, is_per_side INTEGER DEFAULT 0, is_amrap INTEGER DEFAULT 0,
        side TEXT, updated_at TEXT,
        FOREIGN KEY (session_exercise_id) REFERENCES session_exercises(id) ON DELETE CASCADE
    );
    CREATE TABLE set_measurements (
        id TEXT PRIMARY KEY, set_id TEXT NOT NULL, parent_type TEXT NOT NULL,
        role TEXT NOT NULL, kind TEXT NOT NULL, value REAL NOT NULL, unit TEXT,
        group_index INTEGER NOT NULL DEFAULT 0, updated_at TEXT
    );
    CREATE TABLE sync_metadata (
        id TEXT PRIMARY KEY, device_id TEXT NOT NULL, last_sync_date TEXT,
        server_change_token TEXT, sync_enabled INTEGER DEFAULT 0,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        last_uploaded INTEGER DEFAULT 0, last_downloaded INTEGER DEFAULT 0, last_conflicts INTEGER DEFAULT 0
    );
    CREATE TABLE sync_engine_state (
        id TEXT PRIMARY KEY DEFAULT 'default', data BLOB NOT NULL
    );
    CREATE TABLE workout_inbox (
        inbox_id TEXT PRIMARY KEY NOT NULL, fetched_at TEXT NOT NULL,
        created_at_server TEXT NOT NULL, source_token_id TEXT,
        lmwf_text TEXT NOT NULL, workout_json TEXT NOT NULL,
        summary_name TEXT NOT NULL,
        summary_exercise_count INTEGER NOT NULL DEFAULT 0,
        summary_set_count INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE schema_version (version INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX idx_template_exercises_workout ON template_exercises(workout_template_id);
    CREATE INDEX idx_template_sets_exercise ON template_sets(template_exercise_id);
    CREATE INDEX idx_workout_templates_favorite ON workout_templates(is_favorite);
    CREATE INDEX idx_session_exercises_session ON session_exercises(workout_session_id);
    CREATE INDEX idx_session_exercises_name ON session_exercises(exercise_name);
    CREATE INDEX idx_session_exercises_parent ON session_exercises(parent_exercise_id);
    CREATE INDEX idx_session_sets_exercise ON session_sets(session_exercise_id);
    CREATE INDEX idx_template_exercises_parent ON template_exercises(parent_exercise_id);
    CREATE INDEX idx_workout_sessions_status ON workout_sessions(status);
    CREATE INDEX idx_workout_sessions_date ON workout_sessions(date DESC);
    CREATE INDEX idx_gym_equipment_name ON gym_equipment(name);
    CREATE INDEX idx_gym_equipment_gym ON gym_equipment(gym_id);
    CREATE INDEX idx_gyms_default ON gyms(is_default);
    CREATE INDEX idx_set_measurements_set ON set_measurements(set_id, parent_type);
    CREATE INDEX idx_set_measurements_group ON set_measurements(set_id, group_index);
    """#

    static let v17SyntheticData: String = #"""
    INSERT INTO user_settings
      (id, default_weight_unit, enable_workout_timer, auto_start_rest_timer, theme, notifications_enabled,
       anthropic_api_key_status, healthkit_enabled, live_activities_enabled, keep_screen_awake,
       show_open_in_claude_button, created_at, updated_at,
       developer_mode_enabled, countdown_sounds_enabled, has_accepted_disclaimer, default_timer_countdown,
       default_weight_step_lbs)
    VALUES
      ('\#(userSettingsId)', 'lbs', 1, 1, 'auto', 1,
       'not_set', 0, 1, 1,
       0, '\#(ts1)', '\#(ts1)',
       0, 1, 0, 0,
       2.5);

    INSERT INTO gyms (id, name, is_default, created_at, updated_at, deleted_at) VALUES
      ('\#(gymHome)', 'Home Gym', 1, '\#(ts1)', '\#(ts1)', NULL);

    INSERT INTO schema_version (version) VALUES (18);
    """#
}

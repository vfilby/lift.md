import Foundation

extension DatabaseSeeds {

    // MARK: - v12 DDL and data (post-reshape)

    static let v12DDL: String = #"""
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
        has_accepted_disclaimer INTEGER DEFAULT 0
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

    /// v12 data — post-reshape; set_measurements populated; reduced session_sets / template_sets.
    /// Includes every (kind × role × parent_type) combo plus diverse units.
    static let v12Data: String = #"""
    INSERT INTO workout_templates
      (id, name, default_weight_unit, created_at, updated_at, is_favorite)
    VALUES
      ('\#(templatePushId)', 'Push Day', 'lbs', '\#(ts1)', '\#(ts1)', 1);

    INSERT INTO template_exercises
      (id, workout_template_id, exercise_name, order_index, equipment_type, updated_at)
    VALUES
      ('\#(tplExBench)', '\#(templatePushId)', 'Bench Press', 0, 'barbell', '\#(ts1)');

    INSERT INTO template_sets
      (id, template_exercise_id, order_index, rest_seconds, is_dropset, is_per_side, is_amrap, updated_at)
    VALUES
      ('\#(tplSet1)', '\#(tplExBench)', 0, 180, 0, 0, 0, '\#(ts1)');

    INSERT INTO user_settings
      (id, default_weight_unit, enable_workout_timer, auto_start_rest_timer, theme, notifications_enabled,
       anthropic_api_key_status, healthkit_enabled, live_activities_enabled, keep_screen_awake,
       show_open_in_claude_button, created_at, updated_at,
       developer_mode_enabled, countdown_sounds_enabled, has_accepted_disclaimer)
    VALUES
      ('\#(userSettingsId)', 'lbs', 1, 1, 'auto', 1,
       'not_set', 0, 1, 1,
       0, '\#(ts1)', '\#(ts1)',
       0, 1, 0);

    INSERT INTO gyms (id, name, is_default, created_at, updated_at, deleted_at) VALUES
      ('\#(gymHome)', 'Home Gym', 1, '\#(ts1)', '\#(ts1)', NULL);

    INSERT INTO gym_equipment
      (id, name, is_available, last_checked_at, created_at, updated_at, gym_id, deleted_at)
    VALUES
      ('\#(equipBarbell)', 'Barbell', 1, NULL, '\#(ts1)', '\#(ts1)', '\#(gymHome)', NULL);

    INSERT INTO workout_sessions
      (id, workout_template_id, name, date, start_time, end_time, duration, status, updated_at)
    VALUES
      ('\#(sessionDoneId)', '\#(templatePushId)', 'Push Day', '\#(tsDate)',
       '2024-01-15T08:00:00Z', '2024-01-15T09:05:00Z', 3900, 'completed', '\#(ts1)');

    INSERT INTO session_exercises
      (id, workout_session_id, exercise_name, order_index, status, updated_at)
    VALUES
      ('\#(sesExBench)', '\#(sessionDoneId)', 'Bench Press', 0, 'completed', '\#(ts1)');

    INSERT INTO session_sets
      (id, session_exercise_id, order_index, rest_seconds, completed_at, status, notes,
       is_dropset, is_per_side, is_amrap, side, updated_at)
    VALUES
      ('\#(sesSet1)', '\#(sesExBench)', 0, 180, '2024-01-15T08:12:00Z', 'completed', NULL,
       0, 0, 0, NULL, '\#(ts1)');

    -- set_measurements covers every kind×role×parent_type combo + diverse units
    INSERT INTO set_measurements
      (id, set_id, parent_type, role, kind, value, unit, group_index, updated_at)
    VALUES
      ('dddddddd-dddd-dddd-dddd-000000000001', '\#(sesSet1)',
       'session', 'target', 'weight',   135.0, 'lbs', 0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-000000000002', '\#(sesSet1)',
       'session', 'target', 'reps',      5.0, NULL,  0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-000000000003', '\#(sesSet1)',
       'session', 'target', 'time',     60.0, 's',   0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-000000000004', '\#(sesSet1)',
       'session', 'target', 'distance',  1.0, 'km',  0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-000000000005', '\#(sesSet1)',
       'session', 'target', 'rpe',       8.0, NULL,  0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-000000000006', '\#(sesSet1)',
       'session', 'actual', 'weight',   60.0, 'kg',  0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-000000000007', '\#(sesSet1)',
       'session', 'actual', 'reps',      5.0, NULL,  0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-000000000008', '\#(sesSet1)',
       'session', 'actual', 'time',     60.0, 's',   0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-000000000009', '\#(sesSet1)',
       'session', 'actual', 'distance',  1.0, 'km',  0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-00000000000a', '\#(sesSet1)',
       'session', 'actual', 'rpe',       9.0, NULL,  0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-00000000000b', '\#(tplSet1)',
       'planned', 'target', 'weight',  135.0, 'lbs', 0, '\#(ts1)'),
      ('dddddddd-dddd-dddd-dddd-00000000000c', '\#(tplSet1)',
       'planned', 'target', 'reps',     5.0, NULL,  0, '\#(ts1)');

    INSERT INTO sync_metadata (id, device_id, created_at, updated_at)
    VALUES ('\#(syncMetaId)', 'device-ABC', '\#(ts1)', '\#(ts1)');

    INSERT INTO schema_version (version) VALUES (12);
    """#
}

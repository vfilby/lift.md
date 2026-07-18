import Foundation

/// Golden shapes: hand-authored expectations about the post-migration world.
///
/// Unlike the DDL cross-check (which diffs seed vs live), these describe the *observable*
/// invariants the migration suite guarantees. Tests compare live-migrated DB state against
/// these constants — drift here signals a behavioral regression, not a schema typo.
enum MigrationGoldenShapes {

    /// Tables that must exist after migrating any valid seed up to head.
    /// Ordered alphabetically so it also serves as the expected set when compared against
    /// the live DB's `sqlite_master` table listing (excluding GRDB's `grdb_migrations`
    /// bookkeeping table). The legacy `schema_version` table is dropped at v20.
    static let expectedTablesAtHead: [String] = [
        "ck_record_metadata",
        "gym_equipment",
        "gyms",
        "outbox_pending_queue",
        "session_exercises",
        "session_sets",
        "set_measurements",
        "sync_engine_state",
        "sync_metadata",
        "template_exercises",
        "template_sets",
        "user_settings",
        "workout_inbox",
        "workout_sessions",
        "workout_templates",
    ]

    /// Named indexes (`origin='c'`) that must exist after migrating any valid seed up to head.
    /// Excludes automatic indexes created by `PRIMARY KEY` and `UNIQUE` constraints.
    static let expectedIndexesAtHead: [String] = [
        "idx_gym_equipment_gym",
        "idx_gym_equipment_name",
        "idx_gyms_default",
        "idx_session_exercises_name",
        "idx_session_exercises_parent",
        "idx_session_exercises_session",
        "idx_session_sets_exercise",
        "idx_set_measurements_group",
        "idx_set_measurements_set",
        "idx_template_exercises_parent",
        "idx_template_exercises_workout",
        "idx_template_sets_exercise",
        "idx_workout_sessions_date",
        "idx_workout_sessions_status",
        "idx_workout_templates_favorite",
    ]

    /// Columns that v12's fan-out **removes** from pre-v12 schemas.
    /// If any of these survive past migration to v12+, the migration is broken.
    static let columnsRemovedAtV12: [(table: String, column: String)] = [
        ("template_sets", "target_weight"),
        ("template_sets", "target_weight_unit"),
        ("template_sets", "target_reps"),
        ("template_sets", "target_time"),
        ("template_sets", "target_rpe"),
        ("template_sets", "tempo"),
        ("session_sets", "parent_set_id"),
        ("session_sets", "drop_sequence"),
        ("session_sets", "tempo"),
    ]

    /// Tables silently dropped at v9 (anthropic purge) — SR4 from the spec.
    /// These must NOT exist at head.
    static let tablesRemovedAtV9: [String] = ["sync_queue", "sync_conflicts"]

}

// Frozen DDL + data seeds for upgrade-path migration tests.
//
// These strings are **authoritative**. Mirrors under `test-fixtures/db-seeds/` exist for human review,
// but the Swift constants in this file are what the tests actually load. If you update a seed, update
// both — the README in that directory notes this.
//
// DDL strings were initially captured by running the migrator up to version N and dumping
// `sqlite_master`. The cross-check test (`testVNSeedMatchesLiveMigrateToVN`) guards against future drift
// by diffing PRAGMA table_info + index names between live migrations and the seed.
//
// Data fixtures use hard-coded UUIDs and ISO-8601 timestamps. Rule: **no clock reads, no `UUID()`**.
// Determinism is load-bearing for reproducibility across CI runs and local debugging.
//
// Per-version DDL and data constants live in sibling `V*Seed.swift` files as extensions on this enum.

import Foundation

enum DatabaseSeeds {

    // MARK: - Deterministic IDs and timestamps
    //
    // UUIDs are UUID4-style but hand-generated so parent/child references remain stable.
    // Timestamp convention: 2024-01-XX to keep them well clear of "today".

    // Templates
    static let templatePushId = "11111111-1111-1111-1111-000000000001"
    static let templatePullId = "11111111-1111-1111-1111-000000000002"

    // Template exercises
    static let tplExBench = "22222222-2222-2222-2222-000000000001"
    static let tplExBenchChild = "22222222-2222-2222-2222-000000000002"   // superset child of tplExBench
    static let tplExRow = "22222222-2222-2222-2222-000000000003"
    static let tplExCurl = "22222222-2222-2222-2222-000000000004"

    // Template sets
    static let tplSet1 = "33333333-3333-3333-3333-000000000001"  // weight/reps
    static let tplSet2 = "33333333-3333-3333-3333-000000000002"  // time only
    static let tplSet3 = "33333333-3333-3333-3333-000000000003"  // rpe set, dropset
    static let tplSet4 = "33333333-3333-3333-3333-000000000004"  // per-side
    static let tplSet5 = "33333333-3333-3333-3333-000000000005"  // amrap
    static let tplSet6 = "33333333-3333-3333-3333-000000000006"  // NULL rest, populated tempo
    static let tplSet7 = "33333333-3333-3333-3333-000000000007"
    static let tplSet8 = "33333333-3333-3333-3333-000000000008"

    // Sessions
    static let sessionDoneId = "44444444-4444-4444-4444-000000000001"
    static let sessionInProgressId = "44444444-4444-4444-4444-000000000002"

    // Session exercises
    static let sesExBench = "55555555-5555-5555-5555-000000000001"
    static let sesExBenchChild = "55555555-5555-5555-5555-000000000002"  // superset child
    static let sesExRow = "55555555-5555-5555-5555-000000000003"

    // Session sets — six rows with diverse measurement shapes
    static let sesSet1 = "66666666-6666-6666-6666-000000000001"  // unstarted target only
    static let sesSet2 = "66666666-6666-6666-6666-000000000002"  // complete
    static let sesSet3 = "66666666-6666-6666-6666-000000000003"  // dropset parent
    static let sesSet4 = "66666666-6666-6666-6666-000000000004"  // dropset child (parent_set_id = sesSet3)
    static let sesSet5 = "66666666-6666-6666-6666-000000000005"  // time only
    static let sesSet6 = "66666666-6666-6666-6666-000000000006"  // distance-only

    // Gyms / equipment
    static let gymHome = "77777777-7777-7777-7777-000000000001"
    static let gymWork = "77777777-7777-7777-7777-000000000002"
    static let gymAnother = "77777777-7777-7777-7777-000000000003"  // v4-two-defaults variant
    static let equipBarbell = "88888888-8888-8888-8888-000000000001"
    static let equipBench = "88888888-8888-8888-8888-000000000002"
    static let equipRack = "88888888-8888-8888-8888-000000000003"

    // User settings
    static let userSettingsId = "99999999-9999-9999-9999-000000000001"

    // Sync
    static let syncMetaId = "aaaaaaaa-aaaa-aaaa-aaaa-000000000001"
    static let syncQ1 = "bbbbbbbb-bbbb-bbbb-bbbb-000000000001"
    static let syncQ2 = "bbbbbbbb-bbbb-bbbb-bbbb-000000000002"
    static let syncQ3 = "bbbbbbbb-bbbb-bbbb-bbbb-000000000003"
    static let syncConflict1 = "cccccccc-cccc-cccc-cccc-000000000001"

    static let ts1 = "2024-01-15T10:00:00Z"
    static let ts2 = "2024-01-15T11:00:00Z"
    static let ts3 = "2024-01-15T12:34:56Z"  // v8 seed distinctive value
    static let tsDate = "2024-01-15"
}

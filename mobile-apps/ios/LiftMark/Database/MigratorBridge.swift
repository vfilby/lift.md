import Foundation
import GRDB

/// One-time adapter that translates legacy `schema_version`-tracked databases into
/// GRDB's `grdb_migrations` identifier-row bookkeeping.
///
/// Called from `DatabaseManager.database()` before the legacy `runMigrations` path.
/// See `spec/services/migrator.md` for the full contract.
enum MigratorBridge {

    // MARK: - Feature flag

    /// Compile-time (source-level) feature flag. Set to `false` in a hotfix build
    /// to cut a rollback TestFlight — when `false`, the bridge short-circuits and the
    /// legacy `DatabaseManager.runMigrations` path runs unchanged.
    ///
    /// Declared `var` so unit tests can flip it; in production nothing modifies this at
    /// runtime. `nonisolated(unsafe)` silences the Swift 6 global-state warning — tests
    /// save/restore the value under a single-threaded XCTest harness.
    nonisolated(unsafe) static var isEnabled: Bool = true

    // MARK: - Identifiers

    /// Canonical identifier list — wire-level contract. Must not reorder or rename.
    /// See `spec/services/migrator.md` §1.1.
    static let identifiers: [String] = [
        "v1_bootstrap",
        "v2_sync_metadata_stats",
        "v3_developer_mode",
        "v4_soft_delete_gyms",
        "v5_countdown_sounds",
        "v6_session_set_side",
        "v7_accepted_disclaimer",
        "v8_updated_at_cksync",
        "v9_api_key_fk_indexes",
        "v10_distance_columns",
        "v11_gym_unique_fk_indexes",
        "v12_set_measurements",
        "v13_default_timer_countdown",
        "v14_default_weight_step_lbs",
        "v15_ai_prompt_toggles",
        "v16_workout_inbox"
    ]

    /// Highest bridge version == number of registered migrations.
    static let currentVersion = 16

    // MARK: - Outcome

    enum Outcome: Equatable {
        case skippedFreshInstall
        case skippedAlreadyBridged
        case skippedFeatureFlagDisabled
        case skippedFutureVersion(version: Int)
        case bridged(fromVersion: Int, rowsInserted: Int)
    }

    // MARK: - Entry point

    /// Run the bridge if needed. Safe to call on every app launch — idempotent.
    /// Throws `MigratorBridgeBackup.BackupError` on pre-flight/backup failure, or
    /// `MigratorBridgeError` on bridge-write/migrator failure.
    @discardableResult
    static func runIfNeeded(
        on dbQueue: DatabaseQueue,
        liveDBURL: URL
    ) throws -> Outcome {
        guard isEnabled else {
            return .skippedFeatureFlagDisabled
        }

        incrementPostSuccessfulLaunchIfAppropriate()

        let initialState = try readInitialState(dbQueue)

        // Fresh install — no legacy DB, no bridge table. Migrator runs from scratch.
        if initialState.isFreshInstall {
            CrashReporter.shared.addBreadcrumb(
                "migrator_bridge_skipped_fresh_install",
                category: .database
            )
            let migrator = Self.migrator
            try migrator.migrate(dbQueue)
            try writeSchemaVersion(dbQueue, version: currentVersion)
            emitSuccessIfFirstTime(
                fromVersion: 0,
                rowsInserted: 0,
                durationMs: 0
            )
            MigratorBridgeFailure.clearPersisted()
            return .skippedFreshInstall
        }

        // Future-version refusal — DB was written by a newer build.
        if initialState.legacyVersion > currentVersion {
            CrashReporter.shared.captureMigratorEvent(
                "migrator_bridge_refused_future_version",
                level: .error,
                metadata: [
                    "fromVersion": String(initialState.legacyVersion)
                ],
                dataIntegrityRisk: true
            )
            MigratorBridgeFailure.persist(
                .futureVersion,
                context: .init(fromVersion: initialState.legacyVersion)
            )
            throw MigratorBridgeError.refusedFutureVersion(version: initialState.legacyVersion)
        }

        // Already bridged.
        if initialState.bridgeAlreadyPopulated {
            // Compound case: bridge populated AND schema_version > 13 -> refuse.
            if initialState.legacyVersion > currentVersion {
                CrashReporter.shared.captureMigratorEvent(
                    "migrator_bridge_refused_future_version",
                    level: .error,
                    metadata: ["fromVersion": String(initialState.legacyVersion)],
                    dataIntegrityRisk: true
                )
                MigratorBridgeFailure.persist(
                    .futureVersion,
                    context: .init(fromVersion: initialState.legacyVersion)
                )
                throw MigratorBridgeError.refusedFutureVersion(version: initialState.legacyVersion)
            }
            CrashReporter.shared.addBreadcrumb(
                "migrator_bridge_skipped_already_done",
                category: .database,
                metadata: ["buildNumber": currentBuildNumber()]
            )
            // Informational build-transition event. Fires for any build change since
            // the last successful bridge — upgrade, downgrade, or non-numeric change.
            // The downgrade case (§3.g) is what motivates the breadcrumb; the others
            // are recorded for completeness.
            let lastSuccessKey = MigratorBridgeBackup.UserDefaultsKey.lastSuccessBuildNumber
            if let lastSuccess = UserDefaults.standard.string(forKey: lastSuccessKey),
               lastSuccess != currentBuildNumber()
            {
                CrashReporter.shared.addBreadcrumb(
                    "migrator_bridge_build_number_changed",
                    category: .database,
                    metadata: [
                        "buildNumber": currentBuildNumber(),
                        "lastSuccessBuildNumber": lastSuccess,
                        "direction": buildNumberDirection(from: lastSuccess, to: currentBuildNumber())
                    ]
                )
            }
            // Migrator may apply newly-registered versions on a previously-bridged DB.
            // Update schema_version to match so the legacy `DatabaseManager.runMigrations`
            // catch-up pass doesn't re-run the same ALTER TABLE and blow up on a
            // duplicate column.
            let migrator = Self.migrator
            try migrator.migrate(dbQueue)
            try writeSchemaVersion(dbQueue, version: currentVersion)
            MigratorBridgeFailure.clearPersisted()
            return .skippedAlreadyBridged
        }

        // Existing unbridged user at 1 ≤ N ≤ 13. Run the full pre-flight/backup/bridge path.
        return try executeBridge(on: dbQueue, liveDBURL: liveDBURL, fromVersion: initialState.legacyVersion)
    }

    // MARK: - Core bridge path

    private static func executeBridge(
        on dbQueue: DatabaseQueue,
        liveDBURL: URL,
        fromVersion: Int
    ) throws -> Outcome {
        let startedAt = Date()
        let dbSize = (try? MigratorBridgeBackup.dbSizeBytes(at: liveDBURL)) ?? 0

        try runPreflight(on: dbQueue, liveDBURL: liveDBURL, dbSize: dbSize)

        CrashReporter.shared.captureMigratorEvent(
            "migrator_bridge_attempted",
            metadata: [
                "fromVersion": String(fromVersion),
                "dbSizeBytes": String(dbSize)
            ]
        )

        let backup = try runBackup(on: dbQueue, liveDBURL: liveDBURL, startedAt: startedAt)

        let rowsInserted = try runBridgeWrite(
            on: dbQueue,
            liveDBURL: liveDBURL,
            fromVersion: fromVersion,
            backupURL: backup.url
        )

        try runMigratorHandoff(on: dbQueue, liveDBURL: liveDBURL, backupURL: backup.url)

        // Keep schema_version aligned for downgrade safety.
        try writeSchemaVersion(dbQueue, version: currentVersion)

        let totalDurationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        emitSuccessIfFirstTime(
            fromVersion: fromVersion,
            rowsInserted: rowsInserted,
            durationMs: totalDurationMs
        )
        UserDefaults.standard.set(
            currentBuildNumber(),
            forKey: MigratorBridgeBackup.UserDefaultsKey.lastSuccessBuildNumber
        )
        MigratorBridgeFailure.clearPersisted()

        return .bridged(fromVersion: fromVersion, rowsInserted: rowsInserted)
    }

    // MARK: - Core bridge phases

    private static func runPreflight(
        on dbQueue: DatabaseQueue,
        liveDBURL: URL,
        dbSize: Int64
    ) throws {
        CrashReporter.shared.addBreadcrumb("bridge.preflight.begin", category: .database)
        do {
            try MigratorBridgeBackup.preflight(liveDBURL: liveDBURL, liveDbQueue: dbQueue)
        } catch MigratorBridgeBackup.BackupError.diskFull(let free, _) {
            CrashReporter.shared.captureMigratorEvent(
                "migrator_bridge_skipped_disk_full",
                level: .error,
                metadata: [
                    "dbSizeBytes": String(dbSize),
                    "freeBytes": String(free)
                ],
                dataIntegrityRisk: true
            )
            MigratorBridgeFailure.persist(
                .diskFull,
                context: .init(requiredBytes: dbSize * 2, dbSizeBytes: dbSize)
            )
            throw MigratorBridgeError.preflightFailed(reason: "disk_full")
        } catch MigratorBridgeBackup.BackupError.sourceIntegrityFailed(let output) {
            CrashReporter.shared.captureMigratorEvent(
                "migrator_bridge_skipped_integrity_failed",
                level: .error,
                metadata: [
                    "integrityCheckOutput": String(output.prefix(2 * 1024))
                ],
                dataIntegrityRisk: true
            )
            MigratorBridgeFailure.persist(.integrityFailed)
            throw MigratorBridgeError.preflightFailed(reason: "integrity_failed")
        }
        CrashReporter.shared.addBreadcrumb("bridge.preflight.end", category: .database)
    }

    private static func runBackup(
        on dbQueue: DatabaseQueue,
        liveDBURL: URL,
        startedAt: Date
    ) throws -> (url: URL, sizeBytes: Int64) {
        CrashReporter.shared.addBreadcrumb("bridge.backup.begin", category: .database)
        let backup: (url: URL, sizeBytes: Int64)
        do {
            backup = try MigratorBridgeBackup.create(from: dbQueue, liveDBURL: liveDBURL)
        } catch MigratorBridgeBackup.BackupError.verificationFailed(let step, let detail) {
            CrashReporter.shared.captureMigratorEvent(
                "migrator_bridge_backup_failed",
                level: .error,
                metadata: [
                    "verificationStep": step.rawValue,
                    "integrityCheckOutput": String(detail.prefix(2 * 1024))
                ],
                dataIntegrityRisk: true
            )
            MigratorBridgeFailure.persist(.backupFailed)
            throw MigratorBridgeError.backupFailed(reason: "verification:\(step.rawValue)")
        } catch {
            CrashReporter.shared.captureMigratorEvent(
                "migrator_bridge_backup_failed",
                level: .error,
                metadata: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": String((error as NSError).code)
                ],
                dataIntegrityRisk: true
            )
            MigratorBridgeFailure.persist(.backupFailed)
            throw MigratorBridgeError.backupFailed(reason: "write_error")
        }
        CrashReporter.shared.addBreadcrumb("bridge.backup.end", category: .database)

        let backupDurationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        // Informational milestone — backup completing isn't an error and doesn't
        // need to count against the Sentry event cap. The end-of-bridge
        // `migrator_bridge_succeeded` event still records the overall outcome.
        CrashReporter.shared.addBreadcrumb(
            "migrator_bridge_backup_succeeded",
            category: .database,
            metadata: [
                "backupSizeBytes": String(backup.sizeBytes),
                "backupPath": backup.url.path,
                "durationMs": String(backupDurationMs)
            ]
        )
        return backup
    }

    private static func runBridgeWrite(
        on dbQueue: DatabaseQueue,
        liveDBURL: URL,
        fromVersion: Int,
        backupURL: URL
    ) throws -> Int {
        CrashReporter.shared.addBreadcrumb("bridge.write.begin", category: .database)
        let rowsInserted: Int
        do {
            rowsInserted = try writeBridgeRows(dbQueue: dbQueue, fromVersion: fromVersion)
        } catch {
            let nsError = error as NSError
            CrashReporter.shared.captureMigratorEvent(
                "migrator_bridge_write_failed",
                level: .error,
                metadata: [
                    "errorDomain": nsError.domain,
                    "errorCode": String(nsError.code),
                    "lastIdentifier": String(fromVersion)
                ],
                dataIntegrityRisk: true
            )
            MigratorBridgeFailure.persist(.bridgeWriteFailed)
            // Transaction rollback is primary defense; restore is the safety belt.
            attemptRestore(backupURL: backupURL, liveDBURL: liveDBURL)
            throw MigratorBridgeError.bridgeWriteFailed(underlying: error)
        }
        CrashReporter.shared.addBreadcrumb("bridge.write.end", category: .database)
        return rowsInserted
    }

    private static func runMigratorHandoff(
        on dbQueue: DatabaseQueue,
        liveDBURL: URL,
        backupURL: URL
    ) throws {
        do {
            let migrator = Self.migrator
            try migrator.migrate(dbQueue)
        } catch {
            let classified = classifyMigratorError(error)
            if classified.isFkViolation {
                CrashReporter.shared.captureMigratorEvent(
                    "migrator_post_bridge_fk_violation",
                    level: .error,
                    metadata: [
                        "errorDomain": classified.domain,
                        "errorCode": String(classified.code)
                    ],
                    dataIntegrityRisk: true
                )
                MigratorBridgeFailure.persist(.fkViolation)
            } else {
                CrashReporter.shared.captureMigratorEvent(
                    "migrator_post_bridge_migration_failed",
                    level: .error,
                    metadata: [
                        "errorDomain": classified.domain,
                        "errorCode": String(classified.code),
                        "failedIdentifier": identifiers.last ?? ""
                    ],
                    dataIntegrityRisk: true
                )
                MigratorBridgeFailure.persist(.postBridgeMigrationFailed)
            }
            attemptRestore(backupURL: backupURL, liveDBURL: liveDBURL)
            throw MigratorBridgeError.postBridgeMigrationFailed(underlying: error)
        }
    }

    private static func classifyMigratorError(_ error: Error) -> (isFkViolation: Bool, domain: String, code: Int) {
        if let dbError = error as? DatabaseError {
            return (
                isFkViolation: dbError.resultCode == .SQLITE_CONSTRAINT,
                domain: "GRDB.DatabaseError",
                code: Int(dbError.resultCode.rawValue)
            )
        }
        let nsError = error as NSError
        return (isFkViolation: false, domain: nsError.domain, code: nsError.code)
    }

    // MARK: - Bridge write

    private static func writeBridgeRows(dbQueue: DatabaseQueue, fromVersion: Int) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS grdb_migrations (
                    identifier TEXT PRIMARY KEY NOT NULL
                )
            """)
            var inserted = 0
            // Write identifiers v1..vN (1..fromVersion). fromVersion is 1-based schema_version value.
            for (index, identifier) in identifiers.enumerated() where index < fromVersion {
                let before = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: [identifier]
                ) ?? 0
                try db.execute(
                    sql: "INSERT OR IGNORE INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier]
                )
                if before == 0 {
                    inserted += 1
                }
            }
            return inserted
        }
    }

    private static func writeSchemaVersion(_ dbQueue: DatabaseQueue, version: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS schema_version (
                    version INTEGER NOT NULL DEFAULT 0
                )
            """)
            let existing = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_version") ?? 0
            if existing == 0 {
                try db.execute(sql: "INSERT INTO schema_version (version) VALUES (?)", arguments: [version])
            } else {
                try db.execute(sql: "UPDATE schema_version SET version = ?", arguments: [version])
            }
        }
    }

    // MARK: - Pre-read

    private struct InitialState {
        let legacyVersion: Int           // 0 if table absent
        let bridgeAlreadyPopulated: Bool

        var isFreshInstall: Bool {
            legacyVersion == 0 && !bridgeAlreadyPopulated
        }
    }

    private static func readInitialState(_ dbQueue: DatabaseQueue) throws -> InitialState {
        try dbQueue.read { db in
            let hasSchemaVersion = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='schema_version'"
            ) ?? 0 > 0
            let legacyVersion: Int
            if hasSchemaVersion {
                legacyVersion = try Int.fetchOne(db, sql: "SELECT version FROM schema_version LIMIT 1") ?? 0
            } else {
                legacyVersion = 0
            }

            let hasBridgeTable = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='grdb_migrations'"
            ) ?? 0 > 0
            let bridgePopulated: Bool
            if hasBridgeTable {
                bridgePopulated = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0) > 0
            } else {
                bridgePopulated = false
            }

            return InitialState(
                legacyVersion: legacyVersion,
                bridgeAlreadyPopulated: bridgePopulated
            )
        }
    }

    // MARK: - Restore helper

    private static func attemptRestore(backupURL: URL, liveDBURL: URL) {
        DatabaseManager.shared.close()
        do {
            try MigratorBridgeBackup.restore(backupURL: backupURL, liveDBURL: liveDBURL)
            CrashReporter.shared.captureMigratorEvent(
                "migrator_bridge_restore_succeeded",
                metadata: ["backupPath": backupURL.path]
            )
        } catch {
            let nsError = error as NSError
            CrashReporter.shared.captureMigratorEvent(
                "migrator_bridge_restore_failed",
                level: .fatal,
                metadata: [
                    "errorDomain": nsError.domain,
                    "errorCode": String(nsError.code),
                    "backupPath": backupURL.path
                ],
                dataIntegrityRisk: true,
                dataLossTag: true
            )
        }
    }

    // MARK: - Success emission (exactly-once)

    private static func emitSuccessIfFirstTime(
        fromVersion: Int,
        rowsInserted: Int,
        durationMs: Int
    ) {
        let defaults = UserDefaults.standard
        let alreadySent = defaults.bool(forKey: MigratorBridgeBackup.UserDefaultsKey.succeededEventSent)
        if alreadySent { return }
        CrashReporter.shared.captureMigratorEvent(
            "migrator_bridge_succeeded",
            metadata: [
                "fromVersion": String(fromVersion),
                "toIdentifier": identifiers.last ?? "",
                "bridgedIdentifierCount": String(rowsInserted),
                "durationMs": String(durationMs),
                "buildNumber": currentBuildNumber()
            ]
        )
        defaults.set(true, forKey: MigratorBridgeBackup.UserDefaultsKey.succeededEventSent)
    }

    private static func incrementPostSuccessfulLaunchIfAppropriate() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: MigratorBridgeBackup.UserDefaultsKey.succeededEventSent) else { return }
        let current = defaults.integer(forKey: MigratorBridgeBackup.UserDefaultsKey.postSuccessfulLaunchCount)
        defaults.set(current + 1, forKey: MigratorBridgeBackup.UserDefaultsKey.postSuccessfulLaunchCount)
    }

    private static func currentBuildNumber() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    /// Classifies a build-number transition. Returns `"upgrade"` / `"downgrade"` if
    /// both sides parse as integers, `"changed"` otherwise (non-numeric build strings).
    static func buildNumberDirection(from previous: String, to current: String) -> String {
        guard let prev = Int(previous), let curr = Int(current) else { return "changed" }
        if curr > prev { return "upgrade" }
        if curr < prev { return "downgrade" }
        return "changed"
    }
}

// MARK: - Errors

enum MigratorBridgeError: LocalizedError {
    case refusedFutureVersion(version: Int)
    case preflightFailed(reason: String)
    case backupFailed(reason: String)
    case bridgeWriteFailed(underlying: Error)
    case postBridgeMigrationFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .refusedFutureVersion(let version):
            return "Migrator bridge refused to run: database schema_version=\(version) "
                + "is newer than this build (max=\(MigratorBridge.currentVersion))."
        case .preflightFailed(let reason):
            return "Migrator bridge pre-flight failed: \(reason)."
        case .backupFailed(let reason):
            return "Migrator bridge backup failed: \(reason)."
        case .bridgeWriteFailed(let underlying):
            return "Migrator bridge write failed: \(underlying.localizedDescription)"
        case .postBridgeMigrationFailed(let underlying):
            return "Post-bridge migration failed: \(underlying.localizedDescription)"
        }
    }
}

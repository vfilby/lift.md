import Foundation

/// User-facing failure cases for the GRDB migrator bridge.
///
/// One case per row of `spec/services/migrator.md` §5.2 that surfaces a message to the user.
/// Purely informational cases (`3.g`, `3.h`, `3.i`) are not included — they do not set
/// `lastAttemptFailed` and never produce an alert.
///
/// Message copy lives here as the single source of truth; keep in sync with the spec.
enum MigratorBridgeFailure: String, CaseIterable {
    case diskFull = "disk_full"                              // 3.a
    case integrityFailed = "integrity_failed"                // 3.b
    case backupFailed = "backup_failed"                      // 3.c
    case bridgeWriteFailed = "bridge_write_failed"           // 3.d (auto-restored)
    case postBridgeMigrationFailed = "post_bridge_migration_failed" // 3.e.1
    case futureVersion = "future_version"                    // 3.e.2
    case fkViolation = "fk_violation"                        // 3.f

    /// Title shown in the alert header. Kept short.
    var alertTitle: String {
        switch self {
        case .diskFull: return "Storage Full"
        case .integrityFailed: return "Database Needs Attention"
        case .backupFailed: return "Backup Couldn't Be Created"
        case .bridgeWriteFailed: return "Upgrade Couldn't Complete"
        case .postBridgeMigrationFailed, .fkViolation: return "Upgrade Rolled Back"
        case .futureVersion: return "Update Required"
        }
    }

    /// Alert body. Matches `spec/services/migrator.md` §5.2 verbatim, with numeric
    /// substitutions for disk-full only. Do not alter without updating the spec.
    func alertMessage(context: MigratorBridgeFailureContext) -> String {
        switch self {
        case .diskFull:
            let needed = context.requiredMegabytes ?? 0
            return "Free up ~\(needed) MB and relaunch."
        case .integrityFailed:
            return """
            Your local workout database reports an inconsistency. lift.md will not upgrade \
            until this is resolved. Tap here to export a copy for support.
            """
        case .backupFailed:
            return "lift.md couldn't create a safety backup. Your data is unchanged. Please try again."
        case .bridgeWriteFailed:
            return "Database upgrade couldn't complete. Your data has been restored from backup. Please try again."
        case .postBridgeMigrationFailed, .fkViolation:
            return "Database upgrade failed and has been rolled back. Your data is unchanged."
        case .futureVersion:
            return "This database was written by a newer version of lift.md. Update the app to continue."
        }
    }

    /// True when the app must stall on launch without touching the database.
    /// Per spec §5.2 — cases 3.a, 3.b, 3.e.2 refuse to proceed.
    var isBootBlocking: Bool {
        switch self {
        case .diskFull, .integrityFailed, .futureVersion:
            return true
        case .backupFailed, .bridgeWriteFailed, .postBridgeMigrationFailed, .fkViolation:
            return false
        }
    }

    /// True when the alert exposes a "share DB for support" action.
    /// Per spec §5.2 3.b only.
    var offersSupportExport: Bool {
        self == .integrityFailed
    }
}

/// Numeric context captured when a failure is persisted, used for message substitution
/// and (optionally) support diagnostics. Any field may be `nil`.
struct MigratorBridgeFailureContext: Equatable {
    var requiredBytes: Int64?
    var dbSizeBytes: Int64?
    var fromVersion: Int?

    /// Bytes rounded up to the next whole megabyte for user-facing messages.
    /// Uses binary MiB (1024²) because the on-device "Storage" UI does the same.
    var requiredMegabytes: Int? {
        guard let required = requiredBytes else { return nil }
        let mib: Int64 = 1024 * 1024
        let rounded = (required + mib - 1) / mib
        return Int(rounded)
    }
}

// MARK: - Persistence

/// UserDefaults keys for the last-failure record. These piggyback on
/// `MigratorBridgeBackup.UserDefaultsKey.lastAttemptFailed` — when that flag is true,
/// `lastFailureCase` identifies which §5.2 case to surface.
extension MigratorBridgeFailure {
    enum PersistenceKey {
        static let lastFailureCase = "migrator.bridge.lastFailureCase"
        static let lastFailureRequiredBytes = "migrator.bridge.lastFailureRequiredBytes"
        static let lastFailureDbSizeBytes = "migrator.bridge.lastFailureDbSizeBytes"
        static let lastFailureFromVersion = "migrator.bridge.lastFailureFromVersion"
    }

    /// Persist this failure case and context. Also sets the shared
    /// `lastAttemptFailed` flag so the launch-time reader has a single boolean to check.
    static func persist(
        _ failure: MigratorBridgeFailure,
        context: MigratorBridgeFailureContext = .init(),
        defaults: UserDefaults = .standard
    ) {
        defaults.set(true, forKey: MigratorBridgeBackup.UserDefaultsKey.lastAttemptFailed)
        defaults.set(failure.rawValue, forKey: PersistenceKey.lastFailureCase)
        if let value = context.requiredBytes {
            defaults.set(NSNumber(value: value), forKey: PersistenceKey.lastFailureRequiredBytes)
        } else {
            defaults.removeObject(forKey: PersistenceKey.lastFailureRequiredBytes)
        }
        if let value = context.dbSizeBytes {
            defaults.set(NSNumber(value: value), forKey: PersistenceKey.lastFailureDbSizeBytes)
        } else {
            defaults.removeObject(forKey: PersistenceKey.lastFailureDbSizeBytes)
        }
        if let value = context.fromVersion {
            defaults.set(value, forKey: PersistenceKey.lastFailureFromVersion)
        } else {
            defaults.removeObject(forKey: PersistenceKey.lastFailureFromVersion)
        }
    }

    /// Load the persisted failure case and its context. Returns `nil` when
    /// `lastAttemptFailed` is clear or the case key is missing/unrecognized.
    static func loadPersisted(
        defaults: UserDefaults = .standard
    ) -> (failure: MigratorBridgeFailure, context: MigratorBridgeFailureContext)? {
        guard defaults.bool(forKey: MigratorBridgeBackup.UserDefaultsKey.lastAttemptFailed) else {
            return nil
        }
        guard
            let raw = defaults.string(forKey: PersistenceKey.lastFailureCase),
            let failure = MigratorBridgeFailure(rawValue: raw)
        else {
            return nil
        }
        var context = MigratorBridgeFailureContext()
        if let number = defaults.object(forKey: PersistenceKey.lastFailureRequiredBytes) as? NSNumber {
            context.requiredBytes = number.int64Value
        }
        if let number = defaults.object(forKey: PersistenceKey.lastFailureDbSizeBytes) as? NSNumber {
            context.dbSizeBytes = number.int64Value
        }
        if defaults.object(forKey: PersistenceKey.lastFailureFromVersion) != nil {
            context.fromVersion = defaults.integer(forKey: PersistenceKey.lastFailureFromVersion)
        }
        return (failure, context)
    }

    /// Clear the persisted failure, typically after the user dismisses the alert or the
    /// bridge succeeds on a later launch.
    static func clearPersisted(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: MigratorBridgeBackup.UserDefaultsKey.lastAttemptFailed)
        defaults.removeObject(forKey: PersistenceKey.lastFailureCase)
        defaults.removeObject(forKey: PersistenceKey.lastFailureRequiredBytes)
        defaults.removeObject(forKey: PersistenceKey.lastFailureDbSizeBytes)
        defaults.removeObject(forKey: PersistenceKey.lastFailureFromVersion)
    }
}

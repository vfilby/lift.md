import Foundation
import GRDB

// MARK: - DatabaseBackupService

enum DatabaseBackupService {

    private static let dbName = "liftmark.db"

    private static let requiredTables = [
        "workout_templates",
        "template_exercises",
        "template_sets",
        "user_settings",
        "gyms",
        "gym_equipment",
        "workout_sessions",
        "session_exercises",
        "session_sets"
    ]

    // MARK: - Database Path

    /// Get the file path to the current SQLite database file.
    static func getDatabasePath() throws -> URL {
        let documentsURL = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return documentsURL
            .appendingPathComponent("SQLite", isDirectory: true)
            .appendingPathComponent(dbName)
    }

    // MARK: - Export

    /// Export a clean, fully-consistent copy of the current database to the cache
    /// directory. Returns the URL of the exported backup.
    ///
    /// The copy is produced with `VACUUM INTO` via the live GRDB connection
    /// (`DatabaseManager.vacuumInto`), NOT a raw `FileManager.copyItem` of the
    /// main DB file. GRDB runs SQLite in WAL mode, so committed data — and on a
    /// freshly-migrated DB, whole tables — can still reside in the `liftmark.db-wal`
    /// sidecar until a checkpoint folds them into the main file. A plain file copy
    /// of only `liftmark.db` could therefore omit recent writes or entire tables.
    /// `VACUUM INTO` emits a single, self-contained, sidecar-free file reflecting
    /// the complete current state regardless of WAL position. See spec/services/backup.md.
    static func exportDatabase() throws -> URL {
        let dbPath = try getDatabasePath()

        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw BackupError.databaseNotFound
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .replacingOccurrences(of: "Z", with: "")
        let exportFileName = "liftmark_backup_\(timestamp).db"

        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw BackupError.cacheDirectoryUnavailable
        }
        let exportURL = cacheDir.appendingPathComponent(exportFileName)

        // VACUUM INTO requires the destination not already exist; clear any stale file.
        try? FileManager.default.removeItem(at: exportURL)

        try DatabaseManager.shared.vacuumInto(exportURL)

        return exportURL
    }

    // MARK: - Validate

    /// Validate that a file is a legitimate SQLite database suitable for import.
    static func validateDatabaseFile(at fileURL: URL) -> Bool {
        let fileManager = FileManager.default

        // Check file exists
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }

        // Check file size (at least 1024 bytes)
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int,
              fileSize >= 1024 else {
            return false
        }

        // Check SQLite magic header (first 16 bytes)
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        let headerData = fileHandle.readData(ofLength: 16)
        fileHandle.closeFile()

        let expectedHeader: [UInt8] = [
            0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
            0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00
        ]

        guard headerData.count == 16 else { return false }

        for (i, byte) in headerData.enumerated() where byte != expectedHeader[i] {
            return false
        }

        // Check required tables
        do {
            let dbQueue = try DatabaseQueue(path: fileURL.path)
            let tables = try dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            }

            for required in requiredTables where !tables.contains(required) {
                return false
            }
        } catch {
            return false
        }

        return true
    }

    // MARK: - Import

    /// Replace the current database with the contents of an imported database file.
    /// WARNING: This is a destructive operation that replaces all existing data.
    static func importDatabase(from fileURL: URL) throws {
        let dbPath = try getDatabasePath()
        let fileManager = FileManager.default

        // Create safety backup
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw BackupError.cacheDirectoryUnavailable
        }
        let backupURL = cacheDir.appendingPathComponent("backup_before_import.db")

        if fileManager.fileExists(atPath: dbPath.path) {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: dbPath, to: backupURL)
        }

        do {
            // Close current database connection. This synchronously tears down
            // the SQLite handle (and its vnode-watcher dispatch source) so the
            // file replacement below doesn't trigger `SQLITE_IOERR_VNODE` on a
            // still-open connection. See GH #104.
            DatabaseManager.shared.close()

            // Delete current database AND any SQLite sidecar files. Leftover
            // -wal / -shm / -journal files from the old DB would otherwise be
            // picked up by SQLite when it opens the freshly-imported file and
            // could corrupt its view of the data.
            try removeDatabaseFiles(at: dbPath, fileManager: fileManager)

            // Copy imported file to database location
            try fileManager.copyItem(at: fileURL, to: dbPath)

            // Reopen database to verify
            _ = try DatabaseManager.shared.database()

            // Clean up safety backup
            try? fileManager.removeItem(at: backupURL)
        } catch {
            // Attempt to restore from safety backup
            if fileManager.fileExists(atPath: backupURL.path) {
                do {
                    // Close again in case `database()` reopened on the partially-
                    // copied file before we got here.
                    DatabaseManager.shared.close()
                    try removeDatabaseFiles(at: dbPath, fileManager: fileManager)
                    try fileManager.copyItem(at: backupURL, to: dbPath)
                    _ = try DatabaseManager.shared.database()
                } catch {
                    Logger.shared.error(.database, "Failed to restore backup after import failure", error: error)
                }
            }

            throw BackupError.importFailed(error.localizedDescription)
        }
    }

    /// Remove the SQLite database file and any associated sidecar files
    /// (`-wal`, `-shm`, `-journal`). The connection MUST already be closed.
    private static func removeDatabaseFiles(at dbPath: URL, fileManager: FileManager) throws {
        let suffixes = ["", "-wal", "-shm", "-journal"]
        for suffix in suffixes {
            let url = suffix.isEmpty
                ? dbPath
                : dbPath.deletingLastPathComponent().appendingPathComponent(dbPath.lastPathComponent + suffix)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }
}

// MARK: - Errors

enum BackupError: LocalizedError {
    case databaseNotFound
    case cacheDirectoryUnavailable
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "Database file not found. Please restart the app."
        case .cacheDirectoryUnavailable:
            return "Cache directory is unavailable. Please restart the app."
        case .importFailed(let reason):
            return "Import failed: \(reason). Your original data is intact."
        }
    }
}

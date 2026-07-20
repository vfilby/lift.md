import Foundation
import GRDB

// MARK: - Persistence

/// Thread-safe SQLite-backed log store. This is the persistence layer behind
/// both the swift-log `SQLiteLogHandler` and the `Logger.shared` facade.
/// Extracted from the original monolithic `Logger` so the handler can be
/// constructed per-label without duplicating I/O state.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let logRetentionDays = 7
    private let deviceInfo: DeviceInfo
    private let stateLock = NSLock()
    private var didEnsureSchema = false
    private var didClean = false
    /// Dedicated serial queue for async database writes, preventing reentrant access
    /// when the logger is called from inside a GRDB read/write closure.
    private let writeQueue = DispatchQueue(label: "com.liftmark.logger.write", qos: .utility)

    private init() {
        self.deviceInfo = Self.getDeviceInfo()
    }

    // MARK: - Device Info

    private static func getDeviceInfo() -> DeviceInfo {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        #if DEBUG
        let buildType = "development"
        #else
        let buildType = "production"
        #endif

        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif

        return DeviceInfo(
            platform: "ios",
            osVersion: osVersionString,
            appVersion: appVersion,
            buildType: buildType,
            isSimulator: isSimulator,
            deviceModel: nil
        )
    }

    func getDeviceInformation() -> DeviceInfo { deviceInfo }

    // MARK: - Database

    /// Ensures the `app_logs` table and its indexes exist. Runs inside the caller's
    /// write transaction. Idempotent by design (`CREATE TABLE IF NOT EXISTS`) so
    /// repeat invocations after test-suite DB resets are cheap.
    private func ensureSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS app_logs (
                id TEXT PRIMARY KEY,
                timestamp TEXT NOT NULL,
                level TEXT NOT NULL,
                category TEXT NOT NULL,
                message TEXT NOT NULL,
                metadata TEXT,
                stack_trace TEXT,
                device_info TEXT,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON app_logs(timestamp DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_logs_level ON app_logs(level)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_logs_category ON app_logs(category)")
    }

    private func generateId() -> String {
        "log_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(9).lowercased())"
    }

    func writeLog(_ entry: LogEntry) {
        // Prepare serializable values on the calling thread
        let id = entry.id ?? generateId()
        let metadataJSON: String? = entry.metadata.flatMap { dict in
            guard let data = try? JSONEncoder().encode(dict) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let deviceInfoJSON: String? = {
            guard let data = try? JSONEncoder().encode(self.deviceInfo) else { return nil }
            return String(data: data, encoding: .utf8)
        }()

        // Dispatch the database write asynchronously on a dedicated serial queue.
        // This prevents reentrant GRDB access when the logger is called from inside
        // a dbQueue.read { } or dbQueue.write { } closure.
        writeQueue.async { [weak self] in
            self?.performWrite(id: id, entry: entry, metadataJSON: metadataJSON, deviceInfoJSON: deviceInfoJSON)
        }
    }

    /// Executes the queued database write. Runs on `writeQueue` only.
    ///
    /// Schema creation + retention cleanup happen lazily on the first successful
    /// write rather than in init(). Init-time migration failures in unrelated
    /// tables (e.g. test suites that leave the main DB in a mid-migration state)
    /// must not strand logs in an unflushable in-memory queue.
    private func performWrite(id: String, entry: LogEntry, metadataJSON: String?, deviceInfoJSON: String?) {
        do {
            let db = try DatabaseManager.shared.database()
            try db.write { db in
                self.stateLock.lock()
                let needsSchema = !self.didEnsureSchema
                self.stateLock.unlock()
                if needsSchema {
                    try self.ensureSchema(db)
                    self.stateLock.lock()
                    self.didEnsureSchema = true
                    self.stateLock.unlock()
                }
                try db.execute(
                    sql: """
                        INSERT INTO app_logs (id, timestamp, level, category, message, metadata, \
                    stack_trace, device_info)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id,
                        entry.timestamp,
                        entry.level.rawValue,
                        entry.category.rawValue,
                        entry.message,
                        metadataJSON,
                        entry.stackTrace,
                        deviceInfoJSON
                    ]
                )
            }

            // One-shot retention sweep after the first successful write.
            self.stateLock.lock()
            let needsClean = !self.didClean
            self.didClean = true
            self.stateLock.unlock()
            if needsClean { self.cleanOldLogs() }
        } catch {
            // Next call will retry ensureSchema because we only flip the flag on success.
            self.stateLock.lock()
            self.didEnsureSchema = false
            self.stateLock.unlock()
            print("[Logger] Failed to write log: \(error)")
        }
    }

    private func cleanOldLogs() {
        do {
            let db = try DatabaseManager.shared.database()
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -logRetentionDays, to: Date()) ?? Date()
            let cutoffString = ISO8601DateFormatter().string(from: cutoffDate)

            try db.write { db in
                try db.execute(sql: "DELETE FROM app_logs WHERE timestamp < ?", arguments: [cutoffString])
            }
        } catch {
            print("[Logger] Failed to clean old logs: \(error)")
        }
    }

    // MARK: - Retrieval

    func getLogs(limit: Int = 100, level: LogLevel? = nil, category: LogCategory? = nil) -> [LogEntry] {
        do {
            let db = try DatabaseManager.shared.database()
            return try db.read { db in
                var sql = "SELECT * FROM app_logs WHERE 1=1"
                var arguments: [DatabaseValueConvertible] = []

                if let level {
                    sql += " AND level = ?"
                    arguments.append(level.rawValue)
                }
                if let category {
                    sql += " AND category = ?"
                    arguments.append(category.rawValue)
                }

                sql += " ORDER BY timestamp DESC LIMIT ?"
                arguments.append(limit)

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                return rows.map { row in
                    let metadataString: String? = row["metadata"]
                    let metadata: [String: String]? = metadataString.flatMap {
                        try? JSONDecoder().decode([String: String].self, from: Data($0.utf8))
                    }
                    return LogEntry(
                        id: row["id"],
                        timestamp: row["timestamp"],
                        level: LogLevel(rawValue: row["level"]) ?? .info,
                        category: LogCategory(rawValue: row["category"]) ?? .app,
                        message: row["message"],
                        metadata: metadata,
                        stackTrace: row["stack_trace"]
                    )
                }
            }
        } catch {
            print("[Logger] Failed to get logs: \(error)")
            return []
        }
    }

    func exportLogs() -> String {
        let logs = getLogs(limit: 1000)
        let exportData: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "logs": logs.map { [
                "id": $0.id ?? "",
                "timestamp": $0.timestamp,
                "level": $0.level.rawValue,
                "category": $0.category.rawValue,
                "message": $0.message
            ] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted) {
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return "{}"
    }

    func clearLogs() {
        do {
            let db = try DatabaseManager.shared.database()
            try db.write { db in
                try db.execute(sql: "DELETE FROM app_logs")
            }
        } catch {
            print("[Logger] Failed to clear logs: \(error)")
        }
    }
}

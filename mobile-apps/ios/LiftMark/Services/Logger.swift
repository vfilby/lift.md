import Foundation
import GRDB
import Logging

// MARK: - Types

enum LogLevel: String, Codable, CaseIterable {
    case debug
    case info
    case warn
    case error

    fileprivate var swiftLogLevel: Logging.Logger.Level {
        switch self {
        case .debug: return .debug
        case .info:  return .info
        case .warn:  return .warning
        case .error: return .error
        }
    }

    fileprivate init(swiftLogLevel: Logging.Logger.Level) {
        switch swiftLogLevel {
        case .trace, .debug:       self = .debug
        case .info, .notice:       self = .info
        case .warning:             self = .warn
        case .error, .critical:    self = .error
        }
    }
}

enum LogCategory: String, Codable, CaseIterable {
    case navigation
    case routing
    case app
    case database
    case network
    case userAction = "user_action"
    case errorBoundary = "error_boundary"
    case logger
    case sync

    /// Stable label used as the swift-log `Logger` label. The `SQLiteLogHandler`
    /// parses this back into a `LogCategory` when persisting entries so the
    /// round-trip matches the existing SQLite schema (`category` column).
    var loggerLabel: String { "liftmark.\(rawValue)" }

    fileprivate static let labelPrefix = "liftmark."

    /// Parse a swift-log label back into a category. Returns `.app` for
    /// unrecognized labels so foreign handlers (e.g. third-party libraries
    /// that bootstrap a `Logger(label: "foo")`) still land in the SQLite
    /// store under a sensible bucket.
    fileprivate static func fromLabel(_ label: String) -> LogCategory {
        guard label.hasPrefix(labelPrefix) else { return .app }
        let raw = String(label.dropFirst(labelPrefix.count))
        return LogCategory(rawValue: raw) ?? .app
    }
}

struct LogEntry: Identifiable, Codable, Hashable {
    var id: String?
    var timestamp: String
    var level: LogLevel
    var category: LogCategory
    var message: String
    var metadata: [String: String]?
    var stackTrace: String?
}

struct DeviceInfo: Codable {
    var platform: String
    var osVersion: String
    var appVersion: String
    var buildType: String
    var isSimulator: Bool
    var deviceModel: String?
}

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
        //
        // Schema creation + retention cleanup happen lazily on the first successful
        // write rather than in init(). Init-time migration failures in unrelated
        // tables (e.g. test suites that leave the main DB in a mid-migration state)
        // must not strand logs in an unflushable in-memory queue.
        writeQueue.async { [weak self] in
            guard let self else { return }
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

// MARK: - SQLiteLogHandler

/// A `swift-log` handler that persists entries to the LiftMark `app_logs`
/// SQLite table via `LogStore.shared`.
///
/// The handler extracts the `LogCategory` from its label (`liftmark.<category>`)
/// so call sites can use idiomatic swift-log (`Logger(label: .database)`) while
/// the existing `DebugLogsView` category/level filters keep working against
/// the untouched SQLite schema.
struct SQLiteLogHandler: LogHandler {
    let label: String
    private let category: LogCategory

    var logLevel: Logging.Logger.Level = .debug
    var metadata: Logging.Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    init(label: String) {
        self.label = label
        self.category = LogCategory.fromLabel(label)
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        // Merge handler-level metadata with call-site metadata.
        var merged: [String: String] = [:]
        for (k, v) in self.metadata { merged[k] = v.stringValue }
        if let metadata {
            for (k, v) in metadata { merged[k] = v.stringValue }
        }
        merged["source"] = source
        merged["file"] = (file as NSString).lastPathComponent
        merged["function"] = function
        merged["line"] = String(line)

        // Preserve the original label as a discoverable field — useful when the
        // label doesn't round-trip to a known `LogCategory` (third-party handlers).
        if category == .app, label != LogCategory.app.loggerLabel {
            merged["logger_label"] = label
        }

        let stackTrace = merged.removeValue(forKey: "error")

        let entry = LogEntry(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            level: LogLevel(swiftLogLevel: level),
            category: category,
            message: message.description,
            metadata: merged.isEmpty ? nil : merged,
            stackTrace: stackTrace
        )

        #if DEBUG
        let prefix = "[\(category.rawValue)]"
        switch entry.level {
        case .error: print("\(prefix) ERROR: \(entry.message)", merged)
        case .warn:  print("\(prefix) WARN: \(entry.message)", merged)
        default:     print("\(prefix) \(entry.message)", merged)
        }
        #endif

        LogStore.shared.writeLog(entry)
    }
}

private extension Logging.Logger.MetadataValue {
    var stringValue: String {
        switch self {
        case .string(let s):          return s
        case .stringConvertible(let c): return c.description
        case .dictionary(let d):      return String(describing: d)
        case .array(let a):           return String(describing: a)
        }
    }
}

// MARK: - Bootstrap

enum LiftMarkLogging {
    private static let bootstrapLock = NSLock()
    nonisolated(unsafe) private static var didBootstrap = false

    /// Install `SQLiteLogHandler` as the process-wide swift-log backend.
    ///
    /// Idempotent: safe to call from both `LiftMarkApp.init()` (production) and
    /// test setUp (tests never call `LoggingSystem.bootstrap` themselves).
    /// `LoggingSystem.bootstrap` itself can only be called once per process —
    /// subsequent calls are a hard crash in swift-log, so we guard with a flag.
    static func bootstrap() {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }
        guard !didBootstrap else { return }
        LoggingSystem.bootstrap { label in
            SQLiteLogHandler(label: label)
        }
        didBootstrap = true
    }

    /// Obtain a category-scoped swift-log `Logger`. Prefer this at call sites
    /// over constructing one manually so the label convention stays consistent.
    static func logger(_ category: LogCategory) -> Logging.Logger {
        Logging.Logger(label: category.loggerLabel)
    }
}

// MARK: - Logger Facade (legacy API)

/// Backwards-compatible facade over swift-log. Existing call sites continue to
/// call `Logger.shared.info(.app, "msg")`; internally the call is routed
/// through swift-log so the backend is a drop-in `LogHandler` swap.
///
/// New code should prefer `LiftMarkLogging.logger(.database)` for idiomatic
/// swift-log usage.
final class Logger: @unchecked Sendable {
    static let shared = Logger()

    private let loggers: [LogCategory: Logging.Logger]

    private init() {
        LiftMarkLogging.bootstrap()
        var map: [LogCategory: Logging.Logger] = [:]
        for category in LogCategory.allCases {
            var logger = Logging.Logger(label: category.loggerLabel)
            logger.logLevel = .debug
            map[category] = logger
        }
        self.loggers = map
    }

    private func logger(for category: LogCategory) -> Logging.Logger {
        loggers[category] ?? Logging.Logger(label: category.loggerLabel)
    }

    private func metadata(from dict: [String: String]?) -> Logging.Logger.Metadata? {
        guard let dict, !dict.isEmpty else { return nil }
        var out: Logging.Logger.Metadata = [:]
        for (k, v) in dict { out[k] = .string(v) }
        return out
    }

    // MARK: - Public Logging Methods

    func debug(_ category: LogCategory, _ message: String, metadata: [String: String]? = nil) {
        logger(for: category).debug(.init(stringLiteral: message), metadata: self.metadata(from: metadata))
    }

    func info(_ category: LogCategory, _ message: String, metadata: [String: String]? = nil) {
        logger(for: category).info(.init(stringLiteral: message), metadata: self.metadata(from: metadata))
    }

    func warn(_ category: LogCategory, _ message: String, metadata: [String: String]? = nil) {
        logger(for: category).warning(.init(stringLiteral: message), metadata: self.metadata(from: metadata))
    }

    func error(_ category: LogCategory, _ message: String, error: Error? = nil, metadata: [String: String]? = nil) {
        var meta = metadata ?? [:]
        if let error {
            // Passed through the handler into the SQLite `stack_trace` column.
            meta["error"] = String(describing: error)
        }
        logger(for: category).error(.init(stringLiteral: message), metadata: self.metadata(from: meta))
    }

    // MARK: - Retrieval / Export (delegated to LogStore)

    func getLogs(limit: Int = 100, level: LogLevel? = nil, category: LogCategory? = nil) -> [LogEntry] {
        LogStore.shared.getLogs(limit: limit, level: level, category: category)
    }

    func exportLogs() -> String { LogStore.shared.exportLogs() }

    func clearLogs() {
        LogStore.shared.clearLogs()
        info(.logger, "All logs cleared")
    }

    func getDeviceInformation() -> DeviceInfo { LogStore.shared.getDeviceInformation() }
}

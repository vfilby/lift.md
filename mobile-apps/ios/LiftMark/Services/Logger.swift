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

    /// The 7-parameter signature is fixed by the swift-log `LogHandler`
    /// protocol and cannot be regrouped. The `#file`/`#function`/`#line`
    /// defaults (legal on a protocol witness, ignored by protocol dispatch —
    /// swift-log always passes all seven arguments) make direct calls
    /// ergonomic, mirroring swift-log's own `Logger` API.
    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String = #file,
        function: String = #function,
        line: UInt = #line
    ) {
        // Merge handler-level metadata with call-site metadata.
        var merged: [String: String] = [:]
        for (key, value) in self.metadata { merged[key] = value.stringValue }
        if let metadata {
            for (key, value) in metadata { merged[key] = value.stringValue }
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
        case .string(let string): return string
        case .stringConvertible(let convertible): return convertible.description
        case .dictionary(let dictionary): return String(describing: dictionary)
        case .array(let array): return String(describing: array)
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
        for (key, value) in dict { out[key] = .string(value) }
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

import Foundation
import Sentry

/// Thin wrapper over SentrySDK for crash reports and non-fatal error capture.
///
/// The rest of the app only talks to this type — keeps Sentry imports in one
/// place and enforces the privacy allowlist centrally. Safe to call before
/// `start()` (no-ops) and when the DSN is missing (no-ops).
final class CrashReporter: @unchecked Sendable {
    static let shared = CrashReporter()

    /// Master toggle. Opt-out: default true. When false, nothing leaves the device.
    static let crashReportingEnabledKey = "privacy.crashReportingEnabled"

    /// Nested toggle. Opt-in: default false. Only consulted for parse-class errors.
    static let includeContentInErrorReportsKey = "privacy.includeContentInErrorReports"

    /// Keys permitted on sync-class error events. Anything else is dropped.
    private static let syncMetadataAllowlist: Set<String> = [
        "recordType",
        "recordFields",
        "errorCode",
        "errorDomain",
        "zoneName",
        "fieldName",
        "fkTable",
        "partialFailureCount",
        "tag",
        "reason",
        "status",
        "clientSessionId"
    ]

    /// Keys permitted on parse-class error events.
    private static let parseMetadataAllowlist: Set<String> = [
        "line",
        "column",
        "tokenType",
        "expected",
        "got",
        "byteCount",
        "lineCount",
        "source",
        "rawContent"
    ]

    private var isStarted = false

    /// Test seam — when set, every `captureError` invocation is recorded here
    /// (with the allowlist-filtered metadata) regardless of whether Sentry is
    /// initialized. Only set from unit tests. Lets us assert on capture sites
    /// without standing up the real SentrySDK.
    nonisolated(unsafe) static var captureErrorRecorder: ((Error, LogCategory, [String: String]) -> Void)?

    /// Test seam — when set, every `addBreadcrumb` invocation is recorded here
    /// regardless of whether Sentry is initialized. Only set from unit tests.
    nonisolated(unsafe) static var breadcrumbRecorder: ((String, LogCategory, [String: String]) -> Void)?

    private init() {
        // Default master toggle to true on first launch.
        if UserDefaults.standard.object(forKey: Self.crashReportingEnabledKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.crashReportingEnabledKey)
        }
    }

    // MARK: - Lifecycle

    static var isCrashReportingEnabled: Bool {
        UserDefaults.standard.bool(forKey: crashReportingEnabledKey)
    }

    func start() {
        guard !isStarted else { return }
        guard Self.isCrashReportingEnabled else {
            Logger.shared.info(.sync, "CrashReporter: disabled in Settings, skipping Sentry init")
            return
        }

        // Skip Sentry on simulator and DEBUG builds to preserve the event quota —
        // dev testing shouldn't count against prod. Override with
        // LIFTMARK_SENTRY_FORCE=1 when you explicitly want to exercise Sentry locally.
        let forceEnabled = ProcessInfo.processInfo.environment["LIFTMARK_SENTRY_FORCE"] == "1"
        if !forceEnabled {
            #if targetEnvironment(simulator)
            Logger.shared.info(.sync, "CrashReporter: simulator build, skipping Sentry init")
            return
            #elseif DEBUG
            Logger.shared.info(.sync, "CrashReporter: DEBUG build, skipping Sentry init")
            return
            #endif
        }

        let dsn = SentryConfig.dsn
        guard !dsn.isEmpty, dsn.hasPrefix("https://") else {
            Logger.shared.info(.sync, "CrashReporter: no DSN configured, skipping Sentry init")
            return
        }

        let environment: String = {
            #if DEBUG
            return "debug"
            #else
            if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
                return "testflight"
            }
            return "release"
            #endif
        }()

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.enableAutoSessionTracking = true
            options.tracesSampleRate = 0.1
            options.beforeSend = { event in
                CrashReporter.sanitize(event: event)
            }
        }

        isStarted = true
    }

    /// Called when the user flips the master toggle in Settings.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.crashReportingEnabledKey)
        if enabled {
            start()
        } else if isStarted {
            SentrySDK.close()
            isStarted = false
        }
    }

    // MARK: - Capture

    /// Report a sync-class non-fatal error. Only allowlisted metadata keys are forwarded.
    func captureError(_ error: Error, category: LogCategory, metadata: [String: String]? = nil) {
        let filtered = Self.filter(metadata: metadata, allowlist: Self.syncMetadataAllowlist)
        Self.captureErrorRecorder?(error, category, filtered)
        guard isStarted, Self.isCrashReportingEnabled else { return }
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: category.rawValue, key: "category")
            for (key, value) in filtered {
                scope.setExtra(value: value, key: key)
            }
        }
    }

    /// Report a parse-class error. Structural info is always sent.
    /// `rawContent` is only attached if the user has enabled the opt-in.
    func captureParseError(_ error: Error, structural: [String: String], rawContent: String? = nil) {
        guard isStarted, Self.isCrashReportingEnabled else { return }
        let filtered = Self.filter(metadata: structural, allowlist: Self.parseMetadataAllowlist)
        let includeContent = UserDefaults.standard.bool(forKey: Self.includeContentInErrorReportsKey)
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: LogCategory.errorBoundary.rawValue, key: "category")
            for (key, value) in filtered {
                scope.setExtra(value: value, key: key)
            }
            if includeContent, let rawContent {
                scope.setExtra(value: Self.truncate(rawContent), key: "rawContent")
            }
        }
    }

    /// Capture a chronic-condition error at most once per build per device.
    ///
    /// Some failure conditions re-fire on every sync/flush cycle until an
    /// external fix lands (a schema promotion, the user re-authenticating).
    /// The first call with `key` on the current build performs a full
    /// `captureError`; repeats on the same build emit `breadcrumb` instead so
    /// the condition still annotates any other event the device sends. The
    /// seen-key set resets when the build number changes, so every release
    /// re-captures once per affected device and the Sentry issue stays alive
    /// for as long as any device is still affected.
    /// See spec/services/sentry.md "Once-per-build capture throttling".
    func captureErrorOncePerBuild(
        key: String,
        error: Error,
        breadcrumb: String,
        category: LogCategory,
        metadata: [String: String]? = nil
    ) {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        if Self.shouldCapture(key: key, build: build) {
            captureError(error, category: category, metadata: metadata)
        } else {
            addBreadcrumb(breadcrumb, category: category, metadata: metadata)
        }
    }

    private static let capturedOnceKeysDefault = "sentry-captured-once-keys"
    private static let capturedOnceBuildDefault = "sentry-captured-once-build"
    private static let capturedOnceLock = NSLock()

    /// Returns true the first time `key` is seen for `build`, recording it.
    /// Internal (not private) so the throttle logic is unit-testable without
    /// varying the real bundle build number.
    static func shouldCapture(key: String, build: String) -> Bool {
        let defaults = UserDefaults.standard
        capturedOnceLock.lock()
        defer { capturedOnceLock.unlock() }

        var captured: Set<String>
        if defaults.string(forKey: capturedOnceBuildDefault) == build {
            captured = Set(defaults.stringArray(forKey: capturedOnceKeysDefault) ?? [])
        } else {
            captured = []
            defaults.set(build, forKey: capturedOnceBuildDefault)
        }
        guard !captured.contains(key) else { return false }
        captured.insert(key)
        defaults.set(Array(captured), forKey: capturedOnceKeysDefault)
        return true
    }

    /// Test seam — clears the once-per-build throttle state so each test
    /// starts fresh (the state persists in UserDefaults.standard).
    static func resetOncePerBuildThrottle() {
        capturedOnceLock.lock()
        defer { capturedOnceLock.unlock() }
        UserDefaults.standard.removeObject(forKey: capturedOnceKeysDefault)
        UserDefaults.standard.removeObject(forKey: capturedOnceBuildDefault)
    }

    func addBreadcrumb(_ message: String, category: LogCategory, metadata: [String: String]? = nil) {
        Self.breadcrumbRecorder?(message, category, metadata ?? [:])
        guard isStarted, Self.isCrashReportingEnabled else { return }
        let crumb = Breadcrumb()
        crumb.message = message
        crumb.category = category.rawValue
        crumb.level = .info
        if let metadata {
            crumb.data = metadata.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        }
        SentrySDK.addBreadcrumb(crumb)
    }

    // MARK: - Internal helpers (unit-testable, do not touch SentrySDK)

    static func filter(metadata: [String: String]?, allowlist: Set<String>) -> [String: String] {
        guard let metadata else { return [:] }
        return metadata.filter { allowlist.contains($0.key) }
    }

    static func truncate(_ content: String, limit: Int = 16 * 1024) -> String {
        if content.utf8.count <= limit { return content }
        let prefix = String(content.utf8.prefix(limit)) ?? String(content.prefix(limit))
        return prefix + "\n…[truncated]"
    }

    /// beforeSend hook — defense in depth. Strips any extras not on any allowlist.
    private static func sanitize(event: Event) -> Event? {
        if var extras = event.extra {
            let allAllowed = syncMetadataAllowlist
                .union(parseMetadataAllowlist)
            extras = extras.filter { allAllowed.contains($0.key) }
            event.extra = extras
        }
        return event
    }
}

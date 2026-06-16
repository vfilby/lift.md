import SwiftUI

@main
struct LiftMarkApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var planStore = WorkoutPlanStore()
    @State private var sessionStore = SessionStore()
    @State private var settingsStore = SettingsStore()
    @State private var gymStore = GymStore()
    @State private var equipmentStore = EquipmentStore()
    @State private var syncStatusStore = SyncStatusStore()
    @State private var authStore: AuthenticationStore
    @State private var inboxPoller: InboxPollerService
    @State private var outboxPusher: OutboxPusherService
    @State private var featureFlags: FeatureFlagsStore
    @State private var pendingImportContent: String? = Self.importContentFromLaunchArgs()

    init() {
        // Wire swift-log to the SQLite-backed handler before anything else logs.
        // Must precede Logger.shared access so the one-shot LoggingSystem.bootstrap
        // happens here rather than from whichever call site logs first.
        LiftMarkLogging.bootstrap()

        // Reset data before ANY store initializes (test isolation). This MUST
        // precede the AuthenticationStore construction below: that init
        // synchronously rehydrates `currentUser` from the Keychain access
        // token, so clearing tokens *after* it would leave a previous
        // scenario's seeded session live in memory — the device renders
        // signed-in even though the Keychain is now empty. Under the BetaE2E
        // plan, `testBetaLogin` (--reset-data) runs after the seeded
        // `testBetaInbox`, which is exactly that case. See GH #277 / #137.
        if ProcessInfo.processInfo.arguments.contains("--reset-data") {
            DatabaseManager.shared.deleteDatabase()
            // Clear SwiftUI navigation state restoration so stale navigation
            // paths (e.g., WorkoutDetailView for a deleted plan) don't persist.
            if let bundleId = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleId)
            }
            // Clear Keychain auth tokens too, so each scenario starts signed
            // out — the DB + UserDefaults wipe above doesn't touch the Keychain,
            // and under --live-backend a surviving session would auto-restore.
            // No-op for scenarios that never sign in.
            TokenStore().clear()
        }

        // Build auth + inbox-poller from a single APIClient + TokenStore so
        // they share session state. Initializing here (rather than as
        // property-initializer defaults) keeps the wiring obvious and lets
        // the poller observe the same AuthenticationStore the rest of the
        // app drives via login/logout.
        let api = APIClient(baseURL: nil)
        let tokens = TokenStore()
        let auth = AuthenticationStore(api: api, tokenStore: tokens)
        let flags = FeatureFlagsStore()
        _authStore = State(initialValue: auth)
        _featureFlags = State(initialValue: flags)
        _inboxPoller = State(initialValue: InboxPollerService(
            authStore: auth,
            apiClient: api,
            featureFlags: flags
        ))
        let pusher = OutboxPusherService(
            authStore: auth,
            apiClient: api
        )
        _outboxPusher = State(initialValue: pusher)

        // On a successful (re-)login, drain any completed-but-unsynced workouts
        // immediately rather than waiting for the next foreground transition.
        // This is the recovery half of GH #143. `auth` retains `pusher` via this
        // closure, but `auth` lives for the whole app lifetime so there is no
        // leak concern.
        auth.onAuthenticated = { [weak pusher] in
            Task { @MainActor in await pusher?.flushIfAuthenticated() }
        }

        // Seed a session straight into the Keychain (runs AFTER --reset-data so
        // it isn't wiped). Lets the Layer-3 beta e2e scenarios that exercise
        // inbox/outbox start already signed in, bypassing the flaky login sheet
        // — the login UI itself is covered by its own scenario. Combined with
        // --live-backend, restoreSession() rehydrates these tokens on launch.
        // See spec/services/ios-e2e-beta.md.
        Self.seedSessionFromLaunchArgs()

        Self.seedMigratorFailureFromLaunchArgs()

        #if DEBUG
        // Runs after --reset-data (clean DB) so seeded rows survive. Drives the
        // auth-sync banner UI tests (GH #143 banner fix).
        Self.seedAuthSyncBannerFromLaunchArgs(auth: auth, pusher: pusher)
        if ProcessInfo.processInfo.arguments.contains("--seed-sample-plans") {
            Self.seedSamplePlans()
        }
        if ProcessInfo.processInfo.arguments.contains("--seed-screenshots") {
            ScreenshotSeed.seed()
        }
        #endif

        if !Self.isRunningTests {
            CrashReporter.shared.start()
        }
    }

    #if DEBUG
    /// Dev-only seeder: reads every `.md` file from `Documents/SampleFixtures/`,
    /// parses via `MarkdownParser`, and saves via `WorkoutPlanRepository`. Intended
    /// to be paired with `--reset-data` to quickly populate a simulator.
    private static func seedSamplePlans() {
        guard let documentsURL = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        let fixturesDir = documentsURL.appendingPathComponent("SampleFixtures", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: fixturesDir, includingPropertiesForKeys: nil
        ) else { return }

        let repository = WorkoutPlanRepository()
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension.lowercased() == "md" {
            guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let result = MarkdownParser.parseWorkout(markdown)
            guard result.success, let plan = result.data else { continue }
            _ = try? repository.create(plan)
        }
    }
    #endif

    #if DEBUG
    /// Test seam for the auth-sync banner (GH #143 banner fix).
    /// `--seed-outbox-pending <n>` seeds `n` stranded outbox rows;
    /// `--seed-session-expired` flips the lapsed-session flag. Together they
    /// render the banner. The pending arg ALONE simulates a never-signed-in user
    /// (sessionExpired stays false) and must NOT render the banner — the
    /// regression this fix is about. Never compiled into release builds.
    private static func seedAuthSyncBannerFromLaunchArgs(
        auth: AuthenticationStore,
        pusher: OutboxPusherService
    ) {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "--seed-outbox-pending"),
           idx + 1 < args.count,
           let n = Int(args[idx + 1]) {
            pusher.seedPendingForTesting(count: n)
        }
        if args.contains("--seed-session-expired") {
            auth.seedSessionExpiredForTesting()
        }
    }
    #endif

    /// Test seam: `--seed-migrator-failure <case>` lets UI tests pre-populate the
    /// migrator bridge's failure state so the boot-time alert/stall flow is exercisable
    /// without triggering a real failure. `<case>` is a `MigratorBridgeFailure` raw value.
    /// Optional companion args `--seed-required-bytes <Int>` and `--seed-from-version <Int>`
    /// set numeric context used by message substitution.
    private static func seedMigratorFailureFromLaunchArgs() {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--seed-migrator-failure"),
              idx + 1 < args.count,
              let failure = MigratorBridgeFailure(rawValue: args[idx + 1]) else {
            return
        }
        var context = MigratorBridgeFailureContext()
        if let rIdx = args.firstIndex(of: "--seed-required-bytes"),
           rIdx + 1 < args.count,
           let bytes = Int64(args[rIdx + 1]) {
            context.requiredBytes = bytes
        }
        if let vIdx = args.firstIndex(of: "--seed-from-version"),
           vIdx + 1 < args.count,
           let version = Int(args[vIdx + 1]) {
            context.fromVersion = version
        }
        MigratorBridgeFailure.persist(failure, context: context)
        // Prevent the real bridge from running and clearing the seeded failure.
        // This arg is strictly for UI-test harness use.
        MigratorBridge.isEnabled = false
    }

    /// Test seam: `--seed-session=<accessJWT>:<refreshToken>` writes the pair
    /// straight to the Keychain so a UI test launches already authenticated,
    /// skipping the login sheet. The access JWT is dot-delimited and the
    /// refresh token is opaque — neither contains a colon — so the first colon
    /// is the unambiguous separator. See spec/services/ios-e2e-beta.md (GH #137).
    private static func seedSessionFromLaunchArgs() {
        let prefix = "--seed-session="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return
        }
        let value = String(arg.dropFirst(prefix.count))
        guard let sep = value.firstIndex(of: ":") else { return }
        let access = String(value[value.startIndex..<sep])
        let refresh = String(value[value.index(after: sep)...])
        guard !access.isEmpty, !refresh.isEmpty else { return }
        TokenStore().saveTokens(access: access, refresh: refresh)
    }

    /// Parse --import-content launch argument at init time so the @State
    /// initial value is non-nil before any views appear. This ensures the
    /// import sheet presents immediately rather than relying on onChange.
    private static func importContentFromLaunchArgs() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--import-content"),
              idx + 1 < args.count else { return nil }
        let base64 = args[idx + 1]
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(pendingImportContent: $pendingImportContent)
                .environment(planStore)
                .environment(sessionStore)
                .environment(settingsStore)
                .environment(gymStore)
                .environment(equipmentStore)
                .environment(syncStatusStore)
                .environment(authStore)
                .environment(inboxPoller)
                .environment(outboxPusher)
                .environment(featureFlags)
                .onAppear {
                    planStore.loadPlans()
                    sessionStore.loadSessions()
                    settingsStore.loadSettings()
                    gymStore.loadGyms()
                    handleLaunchArguments()
                    LiveActivityService.shared.cleanupOrphanedActivities()
                    // CloudKit sync is ALWAYS off under tests (even with
                    // --live-backend) — a beta UI run must never write to a
                    // tester's iCloud. The network paths below run when not
                    // testing, or under the --live-backend Layer-3 gate.
                    if !Self.isRunningTests {
                        Task {
                            await CKSyncEngineManager.shared.start()
                        }
                    }
                    if Self.networkPathsEnabled {
                        // Wait for launch session restoration to settle before
                        // the first authed calls, so an expired access token is
                        // refreshed first rather than tripping a premature 401
                        // / refresh-token race. See spec/services/authentication.md.
                        Task { @MainActor in
                            await authStore.restoreSession()
                            await inboxPoller.pollIfAuthenticated()
                        }
                        Task { @MainActor in
                            await authStore.restoreSession()
                            await outboxPusher.flushIfAuthenticated()
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        if !Self.isRunningTests {
                            Task {
                                await CKSyncEngineManager.shared.start()
                            }
                        }
                        if Self.networkPathsEnabled {
                            Task { @MainActor in
                                await authStore.restoreSession()
                                await inboxPoller.pollIfAuthenticated()
                            }
                            Task { @MainActor in
                                await authStore.restoreSession()
                                await outboxPusher.flushIfAuthenticated()
                            }
                        }
                    default:
                        break
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: SessionStore.sessionDidComplete)) { note in
                    guard
                        let sessionId = note.userInfo?["sessionId"] as? String,
                        Self.networkPathsEnabled
                    else { return }
                    outboxPusher.enqueue(clientSessionId: sessionId)
                }
                // Reload affected stores both incrementally (per merged batch) and at
                // the end of the fetch cycle, so synced records appear live without a
                // manual pull-to-refresh.
                .onReceive(NotificationCenter.default.publisher(for: .syncRecordsMerged)) { notification in
                    reloadStores(forChangedTypes: notification.userInfo?["changedRecordTypes"] as? Set<String> ?? [])
                }
                .onReceive(NotificationCenter.default.publisher(for: .syncCompleted)) { notification in
                    reloadStores(forChangedTypes: notification.userInfo?["changedRecordTypes"] as? Set<String> ?? [])
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    /// Reload the stores affected by an incoming sync. An empty `changedTypes` set means
    /// "unknown — reload everything" (e.g. the final `.syncCompleted` with no detail).
    private func reloadStores(forChangedTypes changed: Set<String>) {
        if changed.isEmpty || !changed.isDisjoint(with: ["WorkoutPlan", "PlannedExercise", "PlannedSet"]) {
            planStore.loadPlans()
        }
        if changed.isEmpty || !changed.isDisjoint(with: ["WorkoutSession", "SessionExercise", "SessionSet"]) {
            sessionStore.loadSessions()
        }
        if changed.isEmpty || changed.contains("UserSettings") {
            settingsStore.loadSettings()
        }
        if changed.isEmpty || !changed.isDisjoint(with: ["Gym", "GymEquipment"]) {
            gymStore.loadGyms()
        }
    }

    private static let isRunningTests = NSClassFromString("XCTestCase") != nil

    /// Layer-3 e2e gate (GH #137). UI tests are network-isolated by default;
    /// `--live-backend` re-enables the auth/inbox/outbox network paths so a
    /// scenario can exercise the real client↔server contract against beta.
    /// CloudKit sync is deliberately NOT covered by this flag — it stays off
    /// under tests regardless. See spec/services/ios-e2e-beta.md.
    private static let isLiveBackend = ProcessInfo.processInfo.arguments.contains("--live-backend")

    /// True when the auth/inbox/outbox network startup paths should run: always
    /// outside tests, and under tests only when `--live-backend` is passed.
    private static var networkPathsEnabled: Bool { !isRunningTests || isLiveBackend }

    private func handleLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments

        // --import-content is handled at init time via importContentFromLaunchArgs()
        // to ensure the @State initial value is set before views appear.
        if args.contains("--import-content") { return }

        if let urlIndex = args.firstIndex(of: "-url"),
           urlIndex + 1 < args.count {
            let urlString = args[urlIndex + 1]
            if let url = URL(string: urlString) {
                handleIncomingURL(url)
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "liftmark" {
            // Handle liftmark:// deep links
            // URL format: liftmark:///path/to/file or liftmark://path/to/file
            var filePath: String
            if let host = url.host, !host.isEmpty {
                filePath = "/" + host + url.path
            } else {
                filePath = url.path
            }

            // Validate the path is within allowed directories and has a valid extension
            guard let safePath = FileImportService.validateDeepLinkPath(filePath) else {
                return
            }

            if FileManager.default.fileExists(atPath: safePath),
               let content = try? String(contentsOfFile: safePath, encoding: .utf8) {
                pendingImportContent = content
            }
        } else if url.isFileURL {
            // Handle file:// URLs from share sheet / "Open In" / document types
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            if let content = try? String(contentsOf: url, encoding: .utf8) {
                pendingImportContent = content
            }
        }
    }
}

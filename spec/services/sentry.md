# Crash & Error Reporter Specification (Sentry)

## Purpose

Ship crash reports and non-fatal sync-error signals off-device so regressions are caught without waiting for a user to export logs. `Logger` remains the authoritative on-device record; Sentry is a lossy, privacy-filtered mirror of a narrow subset.

This service exists because a month of failed CloudKit uploads (CKError 12 `invalidArguments`) went unnoticed until a user manually exported debug logs. Visibility is the single justification — any design decision should be evaluated against "does this tell us sooner?".

## Public API

`CrashReporter` is a singleton. All methods are safe to call before `start()` (they no-op) and when the DSN is unconfigured (they no-op).

### `start()`

Initializes the underlying Sentry SDK. Idempotent. Called once from `LiftMarkApp.init`.

If the DSN is missing or empty, `start()` logs at `info` level to `Logger` (`category: .sync`) and returns. The app must never crash because the reporter is unconfigured.

### `captureError(_ error: Error, category: LogCategory, metadata: [String: String]? = nil)`

Report a non-fatal sync-class error. Only whitelisted metadata keys are forwarded (see **Privacy**).

### `captureParseError(_ error: Error, structural: [String: String], rawContent: String? = nil)`

Report a parse-class error. `structural` is always sent; `rawContent` is only attached if the user has enabled `privacy.includeContentInErrorReports`. The reporter — not the caller — checks the setting, so callers always pass the content and the gate is enforced in one place.

### `addBreadcrumb(_ message: String, category: LogCategory, metadata: [String: String]? = nil)`

Leave a trail. Used at sync cycle boundaries.

### `setUserContext(anonymousId: String)`

Attach a stable anonymous identifier so errors from the same device can be grouped. **Never** pass iCloud user IDs, emails, or anything user-provided.

## Initialization

- Called from `LiftMarkApp.init`, guarded to skip during `XCTestCase` runs (matches the existing `CKSyncEngineManager.shared.start()` gate).
- DSN is read from the build-generated `SentryConfig.dsn` constant. The constant is written by a pre-build phase that reads `SENTRY_DSN_REST` from the xcconfig and prepends `https://`. The DSN is split this way because xcconfig treats `//` as a comment start and truncates values containing it — storing the scheme-less suffix and reassembling in shell side-steps the issue.
  - xcconfig file: `mobile-apps/ios/Config/Sentry.xcconfig` — gitignored. Contains `SENTRY_DSN_REST = <dsn-without-https://>`.
  - `Sentry.xcconfig.example` (committed) documents the format.
  - `SentryConfig.swift` is committed with an empty placeholder and overwritten at build time (same pattern as `BuildInfo.swift`).
  - CI (the TestFlight workflow) strips the `https://` prefix from the `SENTRY_DSN` secret and writes the xcconfig before `xcodegen generate`.
- Debug and Release both send to the same Sentry project, tagged by `environment` (`debug`, `testflight`, `release`) derived from `#if DEBUG` + `Bundle.appStoreReceiptURL` path heuristic.
- Release health and auto-session tracking: **enabled**.
- Performance monitoring (`tracesSampleRate`): **0.1** for sync operations only, via explicit transactions — not global auto-instrumentation.

## Privacy

Error sources split into three classes with different rules:

### Sync-class errors
CloudKit errors, DB errors, state persistence errors. The diagnostic signal is structural (error code, record type, field name) — content is not needed to act on the report.

**Never send for sync-class errors:**
- Workout content (exercise names, sets, reps, weights, notes, tags)
- User-provided text of any kind (workout plan titles, settings strings)
- File contents, imported LMWF bodies
- iCloud user identifiers, email, device name
- GPS/location, HealthKit data

### Parse-class errors
LMWF parser, file import, validator failures. The input IS the bug — a report without some form of input is low-signal. These default to **structural-only** and can be escalated to **full content** by an explicit user setting.

**Structural-only** (default — always safe to send):
- Token type and position (line, column)
- Parser state / expected vs. got
- Line count, byte count of the input
- No raw strings, no quoted literals, no identifiers from user input

**Full content** (opt-in via Settings → Privacy → "Include workout content in error reports", default **off**):
- Raw LMWF/markdown body up to 16 KB (truncated with a marker if longer)
- Still no iCloud identifiers, email, or HealthKit data — the toggle only unlocks the workout body itself

The toggle's label in Settings must explicitly say the content leaves the device and name Sentry as the recipient. The setting key is `privacy.includeContentInErrorReports` in `UserSettings`.

### Global always-never
Regardless of class or setting:
- iCloud user identifiers, email, device name
- GPS/location, HealthKit data
- Internal/debug URLs and tokens

### Master off switch
Users can disable crash reporting entirely via Settings → Privacy → "Send crash and error reports". Default **on** (opt-out). Stored in `UserDefaults` key `privacy.crashReportingEnabled`.

When toggled off mid-session, `CrashReporter.setEnabled(false)` calls `SentrySDK.close()`; any subsequent `captureError`/`addBreadcrumb` calls are no-ops until re-enabled. The content-inclusion toggle is nested under and disabled when the master is off.

**Allowed metadata keys** for sync-class errors (enforced by a static allowlist in `CrashReporter`):
- `recordType` — CloudKit record type name (e.g. `WorkoutPlan`, `SessionSet`)
- `errorCode` — integer CKError code
- `errorDomain` — error domain string
- `zoneName` — CloudKit zone name (e.g. `LiftMarkData`)
- `fieldName` — CloudKit field name implicated in `invalidArguments`
- `fkTable` — FK target table for merge errors (e.g. `session_sets`)
- `partialFailureCount` — integer (also used by `OutboxPusherService` to carry the count of completed workouts stranded by an auth failure)
- `tag` — short stable event-category marker (e.g. `"data_loss"`, `"outbox_auth_failure"`); enables single-rule Sentry alerts
- `sdkVersion`, `osVersion`, `buildType` — already on every event via Sentry defaults

Record IDs (UUIDs) are allowed in breadcrumbs but **not** in captured error metadata, because Sentry's search makes high-cardinality UUIDs noisy without being useful.

Any key not on the allowlist is dropped silently. The allowlist is a compile-time `Set<String>` constant.

### Migrator-class errors (removed)

The one-time GRDB migration **bridge** emitted a `migrator_*` event family and required a dedicated
`migratorMetadataAllowlist` in `CrashReporter`. The bridge and its telemetry were removed in GH #96
once every active device had bridged (see [`migrator.md`](migrator.md) §6). Schema migrations now run
through GRDB's `DatabaseMigrator` directly; a failed migration surfaces as an unhandled error/crash,
not a bespoke event. No migrator-specific allowlist remains.

### Tags

Tags attached to captured events:

| Tag | Values | Purpose |
|-----|--------|---------|
| `tag: "data_loss"` | set on `SyncSessionGuard` data-loss-detected / restore-failed paths | Target for a single alert rule |
| `tag: "outbox_auth_failure"` | set on `OutboxPusherService` flush cycles that cannot push completed workouts because the session is missing/expired (GH #143) | Target an alert: a user has completed workouts that silently aren't syncing |

### `beforeSend` hook

`CrashReporter.start()` installs a `beforeSend` hook that:
1. Drops the event if its `message` or `exception.value` contains any substring from a redaction list (workout plan titles observed from `WorkoutPlanStore`, user display name). This is a defense-in-depth check — the primary defense is not attaching this data in the first place.
2. Strips any `extra` / `tags` keys not on the allowlist.

## Sync instrumentation

### Breadcrumbs
- `CKSyncEngineManager.fetchChanges()` → breadcrumb `sync.fetch.begin`
- `didFetchChanges` delegate → breadcrumb `sync.fetch.end` with `changedRecordTypes` joined string
- `willSendChanges` / `didSendChanges` analogous

### Capture sites

All 28 error sites enumerated in the exploratory survey (see commit message) call `CrashReporter.captureError` **in addition to** their existing `Logger.shared.error(.sync, …)` calls. The Logger call is the on-device source of truth; the Sentry call is best-effort.

High-priority sites (must capture):
- `CKSyncConflictResolver` — all CKError branches
- `CKSyncEngineManager` zone creation, state persistence, state load
- `SyncSessionGuard` data-loss-detected and restore-failed paths — these carry a distinguishing `tag: "data_loss"` so they can be alerted on in Sentry

Low-priority sites (breadcrumb only, no capture):
- Transient `.networkFailure` / `.networkUnavailable` — CKSyncEngine will retry; capturing creates noise

### Once-per-build capture throttling

Some failure conditions are *chronic per device* rather than per-occurrence interesting: the same device re-hits the identical condition every sync/flush cycle until an external fix lands (a schema promotion, the user re-authenticating). Capturing each occurrence burns event quota without adding signal — Sentry LIFTMARK-IOS-P accumulated 700+ identical `outbox_auth_failure` events from one signed-out device, one per foreground flush.

`CrashReporter.captureErrorOncePerBuild(key:error:breadcrumb:category:metadata:)` is the shared throttle for these sites:

- The first call with a given `key` on a given build number performs a full `captureError`; subsequent calls with the same key on the same build emit `breadcrumb` instead (so the condition still annotates any *other* event the device sends).
- The seen-key set persists in `UserDefaults` and **resets when the build number changes**, so every new release re-captures once per affected device — the Sentry issue stays alive for as long as any device is still affected, and release-over-release recurrence remains visible.
- The decision logic lives in the internal, pure-testable `CrashReporter.shouldCapture(key:build:)`.

Throttled sites:
- `CKSyncConflictResolver` schema-drift (key: `ck-reject-<code>-<recordType>`) and catch-all CK save failures (key: `ck-fail-<code>-<recordType>`)
- `OutboxPusherService` auth-failure reporting (key: `outbox-auth-failure`) — see [workout-outbox.md](workout-outbox.md#auth-failure-handling-during-flush)

## Dependencies

- `sentry-cocoa` via SPM, pinned to a `from:` version in `project.yml` → `packages:`.
- No Sentry imports outside of `CrashReporter.swift`. The rest of the app talks to our wrapper.

## Tests

Unit tests in `LiftMarkTests/CrashReporterTests.swift`:

1. `start()` with nil DSN does not crash and subsequent calls no-op.
2. `captureError` with metadata containing non-allowlisted keys drops those keys (verified via a testable metadata-filter helper that is not gated on SentrySDK).
3. The metadata-filter helper is `internal` and pure — it can be unit tested without initializing Sentry.
4. `start()` is idempotent — second call is a no-op.
5. `captureParseError` with the opt-in setting **off** does not forward `rawContent` to the SDK (verified via an injected test-seam that records what the wrapper would have sent).
6. `captureParseError` with the opt-in setting **on** forwards `rawContent` truncated to 16 KB with a `…[truncated]` marker.
7. `shouldCapture(key:build:)` returns `true` the first time a key is seen on a build, `false` for repeats on the same build, and `true` again when the build number changes (throttle resets per release).

Manual verification (documented, not automated):
1. Build against a test Sentry project.
2. Trigger a non-fatal via a debug-menu action that calls `CrashReporter.captureError(NSError(domain: "test", code: 1), category: .sync)`.
3. Confirm the event appears in Sentry within ~30 seconds with `environment: debug` and no workout data in the payload.
4. Force a real CKError by signing out of iCloud mid-sync; confirm a `sync.fetch.*` breadcrumb trail and a `CKError` captured event.

## Cost & quotas

Sentry free tier: 5K errors/month. Alpha user base is <50, so we're nowhere near the ceiling. If we approach it, the first lever is tightening the `tracesSampleRate` to 0 and the second is dropping breadcrumbs for low-signal sites. No billing automation in scope for this change.

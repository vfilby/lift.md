# Open Sentry Issues — Investigation Report

_Snapshot: 2026-05-14. Project: `eff3/liftmark-ios`._

Two open issues at time of writing:
- **LIFTMARK-IOS-H** — `CKError 12 (invalidArguments)` on `UserSettings`. The urgent one.
- **LIFTMARK-IOS-C** — `migrator_bridge_succeeded` info-level event.

---

## Issue LIFTMARK-IOS-H — `CKError 12 (invalidArguments)` on `UserSettings`

### What's happening
- **149 events / 4 users** since 2026-04-23 (one heavy tester accounts for 146/149).
- Distribution: TestFlight build 112 = 76 events, build 119 = 60 events, plus a trickle on 114/100/109/120 incl. 3 in `release` env.
- Every event: outer `CKErrorDomain` code **12** (`CKErrorInvalidArguments`), inner `CKInternalErrorDomain` 2006, on `recordType: UserSettings`, in the `sync.send.begin` → no `sync.send.end` window.
- The extras Sentry shows are bare: `{recordType, errorCode, errorDomain}`. **No `recordFields`, no `tag`.**

### Root cause: CloudKit Production schema drift
Between Apr 20–24, six new fields were added to the `UserSettings` CKRecord payload in `CKRecordMapper.swift:218` but the CloudKit Production schema for `iCloud.com.eff3.liftmark.v2` was never promoted from Development. The CloudKit schema lives only in Apple's CloudKit Dashboard — there is no schema artifact checked into the repo, so deploys are an out-of-band manual step.

The six fields added since the last green state (commit `7a525c0^`):
- `defaultTimerCountdown` (Int64, Apr 20)
- `defaultWeightStepLbs` (Double, Apr 23) — **first error fires the same day**
- `aiPromptIncludeFormatPointer` (Int64, Apr 24)
- `aiPromptIncludeRecentWorkouts` (Int64, Apr 24)
- `aiPromptIncludeProgression` (Int64, Apr 24)
- `aiPromptIncludeEquipment` (Int64, Apr 24)

TestFlight builds use the Production CloudKit env, so every TestFlight tester who edits any setting hits this. The `errorCode 12 / inner 2006` pair is exactly what Apple returns when the server schema doesn't accept a field on the incoming record.

### Three latent bugs the investigation surfaced

**1. `recordFields` diagnostic is silently dropped before reaching Sentry.**
Commit `fcab1ab` (Apr 25) was specifically written to capture `record.allKeys().sorted()` so the next 2006 would name the offending field. But `recordFields` was never added to `CrashReporter.syncMetadataAllowlist` (`CrashReporter.swift:19-28`), so `filter(metadata:allowlist:)` strips it before `SentrySDK.capture`, and `sanitize(event:)` strips it again in `beforeSend` as defense-in-depth. **That entire commit's diagnostic value is currently zero** — which is why we can see the symptom but not the field name in Sentry.

**2. Dispatch lands in `default`, not the schema-drift branch.**
`CKSyncConflictResolver.swift:104` adds a dedicated handler for `.serverRejectedRequest` (code 15) with `tag: schema-drift-suspected`. But CloudKit is returning `.invalidArguments` (code 12) for this case, so it falls through to `default` at line 128 — same shape of metadata but without the schema-drift tag. The intent of the Apr 25 fix only partially applies in practice.

**3. `captureOncePerBuild` throttling leaks.**
The throttle key is `"ck-fail-\(rawValue)-\(recordType)-\(fields)"` where `fields = record.allKeys()`. `UserSettings` has two optional fields (`customPromptAddition`, `homeTiles`) that `toCKRecord` only sets when non-nil. Whenever a user toggles a setting that moves an optional in or out of nil, the field list changes → new throttle key → re-capture. That's why we still see 76 events on a single build despite a "once-per-build" guard.

### Blast radius

| Impact | Severity |
|---|---|
| UserSettings never reaches iCloud → settings don't sync between devices | **High but silent** (no UI surfaces this) |
| Reinstall on the same iCloud account = settings lost (never made it up) | **Silent data loss for prefs** |
| Other record types (Workouts, Sessions, Plans, SetMeasurement) | **Not affected** — their schemas haven't drifted |
| Sync engine retries indefinitely | Battery/network waste on affected devices, but CKSyncEngine handles backoff internally |
| Sentry event quota | Currently fine (149/3 weeks across 4 users). Would scale poorly if shipped to App Store users at this rate |

### Solutions, in priority order

1. **Promote the CloudKit schema from Development to Production** in the CloudKit Dashboard for `iCloud.com.eff3.liftmark.v2`. This is the actual fix. Verify the six fields above plus the SetMeasurement record type are deployed.
2. **After promotion, bump `currentFullUploadVersion`** in `CKSyncEngineManager.swift:180` (currently `3`) so existing devices re-upload their UserSettings and the queue drains. Without this, the engine may stay stuck on the cached failed change.
3. **Add `recordFields` to `syncMetadataAllowlist`** in `CrashReporter.swift:19-28`. Field NAMES only — no user content — safe to ship. Without this we'll re-investigate the next drift from a description, not from data.
4. **Route `.invalidArguments` into the schema-drift branch.** Either fall-through `case .invalidArguments, .serverRejectedRequest:` in `CKSyncConflictResolver.swift:101`, or add a parallel case with the same `tag: schema-drift-suspected`. The dispatch is the difference between "I see schema drift" and "I see a generic save failure".
5. **Stabilize the throttle key** — use a static list of expected field names per record type, or drop `fields` from the throttle key entirely (key on `recordType`+`errorCode`). Otherwise the throttle remains a sieve.
6. **Make CloudKit schema review part of release.** This is the second time CK 12 has bitten (the original Sentry rationale was a prior month-long invisible CK 12 incident). Options:
   - Cheap: add a pre-release checklist line — "if any `toCKRecord(...)` changed since the last release tag, promote schema first."
   - Better: write a small `tools/` script that diffs the local CKRecord schema (parsed from `CKRecordMapper.swift`) against `git show <last-release>:CKRecordMapper.swift` and warns if anything new appears. Wire it into the `release` skill's pre-flight checks.

---

## Issue LIFTMARK-IOS-C — `migrator_bridge_succeeded` (info-level)

### What it is
- **29 events / 7 users**, info-level, first seen Apr 22.
- Every event has `fromVersion: 0`, `bridgedIdentifierCount: 0`, `toIdentifier: v15_ai_prompt_toggles` → fresh-install path in `MigratorBridge.swift:76-91`.
- ~4 events per user, despite a `UserDefaults.succeededEventSent` exactly-once guard at `MigratorBridge.swift:508-520`.

### Is it a bug?
**Mostly no — it's signal that the spec asks for.** `spec/services/migrator.md` §5.3/§6 explicitly designates `migrator_bridge_succeeded` as the cleanup-trigger event: ≥95% of devices must emit it before the bridge code can be removed. The fresh-install path emits with `fromVersion=0` deliberately so fresh installs count toward that 95%.

The 4×-per-user count is consistent with TestFlight reinstalls (UserDefaults wipes → guard resets). Not a regression.

### What is a real concern
The spec table at `spec/services/migrator.md:243-246` still lists `migrator_bridge_backup_succeeded` as an event, but the code at `MigratorBridge.swift:293` (per commit `bea7640`) now emits it as a breadcrumb. **Spec is out of date** — minor, but should be reconciled.

The recent test commit (`9447887`) asserts the breadcrumb shape for `backup_succeeded`. There is no equivalent test guarding `succeeded`'s level/shape, so a refactor could quietly demote it and break the §6 cleanup gate.

### Blast radius
~zero operationally — info-level, exactly-once guarded, low volume. The cost is Sentry inbox noise (it appears as an "issue" beside real errors).

### Solutions

1. **Leave the emission as-is** — it's spec-mandated.
2. **Acknowledge / set up a Sentry inbox rule** that auto-resolves `migrator_event:migrator_bridge_succeeded` per release so it stops looking like a bug-needing-attention.
3. **Reconcile the spec**: update `spec/services/migrator.md:244` to note `backup_succeeded` is now a breadcrumb (matching code and the new test).
4. **Optional belt-and-suspenders**: add a test that asserts `succeeded` IS an event (not a breadcrumb), mirroring the `backup_succeeded` test from `9447887`. Cheap protection for the cleanup-gate signal.

---

## Recommended sequencing

### Stage 1 — Stop the bleed (today)
- [x] Promote CloudKit Production schema in CloudKit Dashboard (`iCloud.com.eff3.liftmark.v2`); verify the six UserSettings fields above + SetMeasurement record type.
- [x] Bump `currentFullUploadVersion` in `CKSyncEngineManager.swift:180` so existing devices re-upload their UserSettings after the schema is live.

### Stage 2 — Fix the diagnostics (one PR)
- [x] Add `recordFields` to `syncMetadataAllowlist` in `CrashReporter.swift:19-28`.
- [x] Fold `.invalidArguments` into the schema-drift branch in `CKSyncConflictResolver.swift:101` (or add a parallel case with `tag: schema-drift-suspected`).
- [x] Stabilize `captureOncePerBuild` throttle key — drop `fields` from the key or use a static field list per record type.

### Stage 3 — Prevent recurrence
- [x] Add a release pre-flight check that diffs the current `toCKRecord(...)` field set against the last release tag and warns on any new field.
- [x] Document in CLAUDE.md / release skill: "promote CloudKit schema before any release that touches `CKRecordMapper.swift`."

### Stage 4 — Inbox hygiene + spec catch-up
- [ ] In Sentry: bulk-resolve LIFTMARK-IOS-H after a 24h soak post-schema-deploy.
- [ ] In Sentry: add an auto-resolve rule for `migrator_event:migrator_bridge_succeeded`.
- [x] Reconcile `spec/services/migrator.md:244` — `backup_succeeded` is now a breadcrumb, not an event.
- [~] Add a test asserting `migrator_bridge_succeeded` IS an event (mirror of `9447887`) — skipped as redundant: `MigratorBridgeTests.testBridge_emitsExpectedEventSequence:409` already asserts `capturedEvents.contains("migrator_bridge_succeeded")`, so a refactor that demoted it to a breadcrumb would fail the existing test.

---

## Resolution (2026-05-22)

Shipped over one overnight session. All four stages committed to `main` and deployed via two release-pipeline runs.

### Commits
- `b1290e2` — Stage 1: `cloudkit-schema.ckdb` updated (6 fields added to `UserSettings`), `currentFullUploadVersion` 3 → 4. Production schema promoted via CloudKit Dashboard before commit.
- `b06176a` — Stage 2: `recordFields` allowlisted, `.invalidArguments` folded into schema-drift case (uses actual error code in log + throttle key), throttle key reduced to `recordType + errorCode`.
- `d2c7dd4` — Stage 3: `tools/check_ckrecord_drift.py` + 9 pytest cases, wired into release skill step 2.5, documented under `## Release` in CLAUDE.md.
- `d0aef4a` — Stage 4: `spec/services/migrator.md` §5.2 reconciled — `migrator_bridge_backup_succeeded` moved from events table to breadcrumbs list with rationale.

### Validation
- iOS unit tests: TEST SUCCEEDED.
- iOS UI tests: 19/19 passing in 1158 s.
- Tools tests: 40 passing (31 existing + 9 new for the drift checker).
- Release pipeline run `26267622971` (Stage 1) — success, 9m13s.
- Release pipeline run `26268727803` (Stages 2/3/4) — success, 10m58s.
- TestFlight build **127** smoke-tested 2026-05-22 — no Sentry CKError 12 events on initial use.

### Outstanding (handoff)
1. After a few more sessions of build 127 soak (multiple setting edits, backgrounding cycles), bulk-resolve LIFTMARK-IOS-H in Sentry.
2. Add the Sentry auto-resolve rule for `migrator_event:migrator_bridge_succeeded` — this is a spec-mandated cleanup-trigger event (see `spec/services/migrator.md` §5.3), not a bug. Keeps the inbox clean until §6 cleanup can run.

### What changes next time
- Any commit touching `CKRecordMapper*.swift` is now gated by `tools/check_ckrecord_drift.py` — adding a `record["new"]` line without updating `cloudkit-schema.ckdb` and promoting the Production schema will fail the release pre-flight rather than fail silently in users' iCloud queues.
- When schema drift does occur, Sentry will now include `recordFields` and the `schema-drift-suspected` tag for both CKError 12 and 2006, so the offending field name is recoverable without a repro.

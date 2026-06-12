# Workout Outbox Service Specification

## Purpose

Store the user's most recent completed workouts on the server so third-party agents (Claude Code, ChatGPT, custom scripts) can read recent training history. This closes the loop on the inbox: agents push plans in, the user trains, and the user's completed sessions flow back out for the agent to inspect on the next interaction.

Concrete agent use cases this enables:

1. **Confirm and encourage** — "I see you completed today's push day, good work."
2. **Check in on progress** — read actual loads/reps vs. the prescribed plan to gauge readiness for the next progression.
3. **Avoid overlap** — read recent muscle groups so the next session it writes doesn't hit a hammered group.

Symmetry with [workout-inbox](workout-inbox.md):

```
Inbox  : agent → server → iOS    (workouts to do)
Outbox : iOS → server → agent    (workouts done)
```

## End-to-end flow

```
iOS session completion ──POST /v1/workouts/outbox──► Server outbox (DDB)
                                                    │ trim to last 20
                                                    │
                              GET /v1/workouts/outbox
                              GET /v1/workouts/outbox/:outbox_id
                                                    ▼
                                External agent (PAT) reads recent training
```

A completed session is pushed exactly once per device install. The server keeps the **last 20 items per user** as a rolling ring buffer; the 21st push evicts the oldest. There is no agent-side write path — agents read only.

## Retention

- **Last 20 items per user.** Enforced on every write: after `PutItem`, query the user's items sorted oldest-first, and `DeleteItem` everything past position 20.
- 20 covers ~5 weeks for a 4×/week lifter — enough for agents to spot progression trends and same-muscle-group adjacency without keeping a full training journal on the server.
- No time-based component. A user who trains rarely sees a longer-lived window; a user who trains daily sees the most recent 20.
- A reaper job is **out of scope** for v1 — trim-on-write is sufficient. (If a write fails mid-trim and leaves the user at 21, the next push reaps it. Bounded permanent overshoot is impossible.)

## Payload

The outbox stores the **single-session JSON shape produced by `WorkoutExportService.exportSingleSessionAsJson`** — the canonical iOS export format for a finished workout. This deliberately reuses an existing, tested export path rather than inventing a new server-side projection.

```jsonc
{
  "exportedAt": "2026-05-25T18:30:00Z",
  "appVersion": "1.6.3",
  "session": {
    "name": "Push Day",
    "date": "2026-05-25",
    "startTime": "2026-05-25T17:35:00Z",
    "endTime": "2026-05-25T18:28:00Z",
    "duration": 3180,
    "status": "completed",
    "exercises": [
      {
        "exerciseName": "Bench Press",
        "orderIndex": 0,
        "status": "completed",
        "sets": [
          {
            "orderIndex": 0, "status": "completed",
            "isDropset": false, "isPerSide": false,
            "targetWeight": 185, "targetWeightUnit": "lbs", "targetReps": 5,
            "actualWeight": 185, "actualWeightUnit": "lbs", "actualReps": 5,
            "completedAt": "2026-05-25T17:42:00Z"
          }
        ]
      }
    ]
  }
}
```

Why JSON, not LMWF: LMWF is a *plan* format (per [[project-lmwf-plan-not-record]] — `@rpe`/`@tempo` are deprecated for records). The actuals that matter to a feedback agent — actual weight per set, actual reps, rest, completion timestamps — live in the rich JSON. Re-encoding to LMWF would lossily strip them.

The whole envelope is stored verbatim under `payload_json` server-side. Agents fetching a single item get the full envelope back.

## Server side

### Persistence

`workout_outbox` DynamoDB table. Schema mirrors `workout_inbox` for operational consistency:

```
workout_outbox
  user_id          PK
  outbox_id        SK    (ULID — lexicographic = chronological)
  source_device_id        device that pushed it (for audit)
  client_session_id       iOS WorkoutSession.id (idempotency key; see below)
  payload_json            full WorkoutExportService single-session envelope
  created_at              server-side ISO 8601 (when the row was written)
  session_completed_at    ISO 8601 from session.endTime, denormalized for filter
  session_name            denormalized for cheap list rendering
```

**No GSI in v1.** Ring-buffer trim uses the existing PK/SK query (oldest first).

### Idempotency

The same `client_session_id` from the same `user_id` must not produce two rows. The retry-queue on iOS will re-fire on transient failures, so the server enforces dedup:

- Write path: query for an existing row with the same `user_id` + `client_session_id`. If present, return the existing item with 200 (not 201). Otherwise insert with `ConditionExpression: attribute_not_exists(outbox_id)`.
- Acceptable race: two concurrent retries from two devices may both pass the existence check and both insert. Bounded duplicate (≤2) is acceptable — next ring-buffer trim eats the older.

### Endpoints

All resource endpoints accept **session JWT OR PAT** per [[feedback-auth-modality-matches-caller]]. PAT scopes are listed; sessions implicitly satisfy any scope.

| Method | Path                                | Scope             | Description                                                                                              |
|--------|-------------------------------------|-------------------|----------------------------------------------------------------------------------------------------------|
| POST   | `/v1/workouts/outbox`               | `workouts:write`  | Push a completed session. Body: full single-session export envelope. Returns the created item summary.   |
| GET    | `/v1/workouts/outbox`               | `workouts:read`   | List up to the last 20 items (newest first). Returns summaries (no full payload).                        |
| GET    | `/v1/workouts/outbox/:outbox_id`    | `workouts:read`   | Fetch one item including full `payload_json`.                                                            |
| DELETE | `/v1/workouts/outbox/:outbox_id`    | `workouts:write`  | User-initiated removal (privacy). Returns 204; 404 if not owned.                                         |

Notes:
- **No ack/ingest lifecycle.** Outbox items don't transition states — they exist (most-recent-N) or are reaped. There is no "ingested" because the consumers (agents) are stateless callers.
- **DELETE requires `workouts:write`**, matching the inbox DELETE convention. Rationale: deletion is a state-changing action, so a read-only PAT (handed to a third-party agent for least-privilege history access) must not be able to prune the user's history. Only a token granted `workouts:write` may delete.
- **List response shape** mirrors inbox list — summary projection per row, deterministic ordering newest-first.

### Validation on POST

- Body size cap: 1 MB (same as `/v1/validate`).
- `session.endTime` required and parseable (proves it's a completed session). Rejects 422 otherwise — server is intentionally strict; iOS only ever pushes completed sessions.
- `session.status` must be `"completed"`. 422 otherwise.
- `client_session_id` required (top-level, sibling of the export envelope), 422 otherwise.

Request body:

```jsonc
{
  "client_session_id": "uuid-of-WorkoutSession",
  "export": { /* full WorkoutExportService envelope */ }
}
```

The export envelope is stored verbatim; `client_session_id` is the idempotency key.

### Logs

- `outbox_push_complete` — `{outboxId, clientSessionId, dedupHit: bool, exerciseCount, totalSetCount, trimmedCount, durationMs}`
- `outbox_list` — `{count, durationMs}`
- `outbox_get` — `{outboxId, found: bool}`
- `outbox_delete` — `{outboxId, durationMs}`

## iOS side

### Local persistence

New device-local GRDB table `outbox_pending_queue` — queue of completed sessions awaiting push. Introduced in schema v17.

```sql
CREATE TABLE IF NOT EXISTS outbox_pending_queue (
  client_session_id  TEXT PRIMARY KEY NOT NULL,    -- WorkoutSession.id
  enqueued_at        TEXT NOT NULL,                -- ISO 8601
  attempt_count      INTEGER NOT NULL DEFAULT 0,
  next_attempt_after TEXT,                         -- ISO 8601; null means eligible now
  last_error         TEXT                          -- short message, for diagnostics
);
```

- **Device-local**, **not synced via CloudKit**, **excluded from `.db` backups**. The source of truth for "did this session get pushed" is the server; this table only tracks in-flight retries on this device.
- Rows are deleted on successful push.

### OutboxPusherService

Mirrors `InboxPollerService` in lifecycle and observability.

- **Enqueue trigger**: the call site that flips a `WorkoutSession` to `status = .completed` also inserts a row into `outbox_pending_queue` (same transaction if possible — never enqueue without the session being durably completed).
- **Flush triggers**:
  - On enqueue (best-effort immediate push).
  - On app foreground transition.
  - On network reachability change from offline → online.
  - On manual "Sync now" tap in Settings.
- **Automatic vs. forced flush.** `flushIfAuthenticated(force:)` takes a `force` flag (default `false`):
  - **Automatic flushes** (enqueue, foreground, reachability) leave `force: false` and process only items eligible *now* — i.e. those whose `next_attempt_after` is null or in the past (`OutboxPendingQueueRepository.eligibleItems()`). This honors the retry backoff so a flapping server isn't hammered.
  - **A manual "Sync now"** passes `force: true` and processes **all** queued items oldest-first regardless of `next_attempt_after` (`OutboxPendingQueueRepository.allItems()`). The backoff timer is an automatic-flush concern; when the user explicitly asks to sync, items parked behind a backoff window must push immediately rather than waiting out the retry timer.
- **"Sync now" flushes BOTH directions.** The Settings "Sync now" button polls the inbox **and** force-flushes the outbox (`inboxPoller.pollIfAuthenticated()` + `outboxPusher.flushIfAuthenticated(force: true)`, run concurrently). A manual sync that only polled the inbox would silently leave completed workouts unpushed — the symptom this requirement closes.
- **Single in-flight push gate** (`isFlushing`) — drains the queue serially, oldest first.
- **Per-item flow**:
  1. Read the `WorkoutSession` from `workout_sessions` + descendants.
  2. Run `WorkoutExportService.exportSingleSessionAsJson` to produce the envelope (in-memory; do not write a file).
  3. `POST /v1/workouts/outbox` with the envelope + `client_session_id`.
  4. On 2xx: delete the queue row.
  5. On a **real API 4xx** (other than 429) — i.e. a 403/4xx whose body carries our JSON `{"error": ...}` shape, or a 401: log, delete the queue row (no point retrying a bad payload), and **capture to Sentry** (`outbox_push_403` / `outbox_push_4xx`) so a terminal drop is never silent.
  6. On **5xx / network / 429**: increment `attempt_count`, set `next_attempt_after = now + backoff(attempt_count)`, leave the row in place.
  7. On an **edge / WAF block** (a 403 with no JSON `{"error"}` body — e.g. CloudFront's `SizeRestrictions_BODY` rejecting a large workout before it reaches the API): this is **infrastructure, not a permanent client error**. The client maps it to `APIError.edgeBlocked(status:)`, **preserves the queue row**, schedules a retry like a transient failure, and captures to Sentry (`outbox_edge_blocked`). Dropping here is exactly the silent data-loss this service must prevent — a large completed workout would vanish. The server-side fix is to keep the CloudFront WAF body-inspection limit and `SizeRestrictions_BODY` override wide enough for real workout payloads (see [lmwf-validator.md](lmwf-validator.md)); the client guard is defense-in-depth so a future edge rejection never silently drops a workout.
- **Backoff**: 30s, 2m, 10m, 30m, 2h (capped). After 10 attempts, log a Sentry breadcrumb (not an error capture per [[reference-sentry-metadata-allowlist]]) and keep retrying — a sustained 5xx for hours means something is wrong on the server, not the client.
- **No CloudKit ack flow**. The outbox is one-way; once the server accepts the row, the device's job is done.

### Settings surface

A small status pill in Settings → "Account → Sync to account":

- "All workouts synced" (queue empty).
- "N workout(s) pending sync. [Sync now]" (queue non-empty).
- Tapping "Sync now" polls the inbox and **force-flushes the outbox** (`flushIfAuthenticated(force: true)`), bypassing the retry backoff so parked items push immediately. The spinner/disabled state reflects either an in-flight inbox poll or outbox flush.

No outbox-browsing UI — the surface for "my completed workouts" remains the History tab, fed by the local database. The outbox is a side-channel for agents, not a user-facing collection.

### Sign-out behavior

Local `outbox_pending_queue` table is wiped on **user-initiated logout** — the queue is session-scoped device state, matching the inbox convention. Server-side outbox rows stay (they outlive any single device install).

**Critical distinction — expired session vs. logout:** a *user-initiated* logout (Settings → Sign out) wipes the queue. A *silently expired session* (refresh token rejected with 401 during `refreshIfNeeded`) must **not** wipe the queue. The completed workouts in the queue still belong to the same user and the same server account; they just couldn't be pushed because the access/refresh chain lapsed. Dropping them here is exactly the data-loss bug this service must prevent (see GH #143). Tokens may be cleared in the expired-session path (an expired refresh token is useless), but the outbox queue survives so that re-authentication can drain it. See [AuthenticationStore re-auth state](#re-authentication-state) below.

### Auth-failure handling during flush

When a flush cannot push because the device is effectively signed out — either `!authStore.isAuthenticated` at the top of `flushIfAuthenticated()`, or a `POST` returns 401 even after `withAuthorizedRequest` tried to refresh — the service must fail **loudly and recoverably**:

1. **Keep the queued items.** Auth failure is never a reason to delete a row. The completed workouts stay enqueued and become eligible to push the moment the user re-authenticates.
2. **Log to the device log.** `Logger.shared.error(.sync, "outbox flush blocked: authentication required", metadata: [...])` so the on-device debug log records the unsynced state (this is the authoritative on-device record per [logger.md](logger.md)).
3. **Capture to Sentry once per flush cycle** (not per item — avoid event-quota spam) via `CrashReporter.shared.captureError(_:category:metadata:)` with `category: .sync` and `metadata["tag"] = "outbox_auth_failure"`. The `pendingCount` of stranded items is attached under the allowlisted `partialFailureCount` key. See [sentry.md](sentry.md) for the tag/allowlist.
4. **Reflect the unsynced state observably.** `lastError` is set to a user-facing "Sign in to sync" message and `pendingCount` continues to reflect the stranded rows so the app-level [auth-sync banner](#auth-sync-banner-ui) can render.

This is the one normal-operation path (alongside the giveup-4xx case) that *does* emit a Sentry capture: a user who completed a workout that silently never synced is a real, actionable failure, not a transient network blip.

**Self-recovering, but kept error-level (GH #265).** The capture fires on every flush *cycle* the workout stays stranded, even though the strand normally self-heals: a 401 never bumps `next_attempt_after` (see [OutboxPusherService](#outboxpusherservice) — only transient 5xx/429/network failures schedule a backoff), so the row stays immediately eligible and drains on the next successful auth (login, app foreground, or launch). GH #265 confirmed there is **no data-loss bug** on builds ≥ 147 and chose to keep the event at error level rather than downgrade it: the volume is low and the signal is genuinely data-at-risk (the workout is unsynced until re-auth, and permanently stuck if the user never signs back in). The recovery is proven end-to-end by `OutboxPusherServiceTests.testStrandedWorkoutDrainsAfterReLogin` — enqueue → 401 strand (queue preserved, alert fired once with `partialFailureCount: 1`) → `login()` → the recovery flush pushes the stranded row and the queue empties.

### Auth-sync banner (UI)

An app-level banner is shown at the root (`ContentView`) when there are completed workouts that cannot sync because the device needs sign-in:

```
outboxPusher.pendingCount > 0
  && (!authStore.isAuthenticated || authStore.sessionExpired)
  && sessionStore.activeSession == nil
```

- Copy: "N workout(s) waiting to sync — sign in to upload." Tapping it presents `LoginView`.
- Accessibility identifier `auth-sync-banner` for UI tests.
- A successful login resets `sessionExpired` and triggers `flushIfAuthenticated()`, which drains the queue and clears the banner.
- **Suppressed during an active workout** (`sessionStore.activeSession != nil`). The banner is mounted as a top `safeAreaInset` over the whole tab view; the active-workout screen draws its own header (including the Finish button) into that same top region, so a visible banner overlaps and intercepts the Finish tap. A sync nag for *past* completed workouts also shouldn't crowd a live session. The banner returns automatically once the workout ends.

### Re-authentication state

`AuthenticationStore` exposes an observable `private(set) var sessionExpired: Bool` (default `false`):

- Set to `true` when `refreshIfNeeded()` receives `APIError.unauthorized` — the refresh chain is dead and the user must sign in again. The store clears the dead tokens and `currentUser` in this path (an expired refresh token is useless), but **does not** invoke the user-initiated `logout()` codepath and therefore **does not** wipe the `outbox_pending_queue` or inbox. This is the load-bearing distinction that makes a silently-completed workout recoverable (GH #143).
- Reset to `false` on a successful `login(...)`. A successful login also kicks `OutboxPusherService.flushIfAuthenticated()` so queued completions sync immediately rather than waiting for the next foreground transition.
- `isAuthenticated` remains `currentUser != nil`; `sessionExpired` is an orthogonal signal that the *last known* session lapsed and re-auth is needed. The banner condition treats either `!isAuthenticated` or `sessionExpired` as "needs sign-in".

### Conflict + dedup rules

- Re-pushing the same `client_session_id` is a no-op server-side (returns the existing row).
- A second device with the same session synced down via CloudKit will not push it — the queue is only seeded by the completion event, not by sync. Each device pushes only sessions it owns the completion of.
- Editing a completed workout after push **does not retroactively update the server**. The outbox is a snapshot at completion time, not a live mirror of `workout_sessions`. (Future: add `PATCH /v1/workouts/outbox/:outbox_id` if this proves limiting. Out of scope v1.)

## Web surface

Logged-in users can browse their own outbox at `getlift.md/account/outbox` (beta: `beta.getlift.md/account/outbox`) so they can see what their agents will read back. Same session JWT the rest of `/account/*` uses; PATs are not involved here.

### Pages

- **`/account/outbox`** — list view. Calls `GET /v1/workouts/outbox`, renders the last 20 items in a table (session name, completed-at, duration, exercise/set count, source device id). Each row links to the detail page. Empty state: "No completed workouts yet — finish one in the iOS app and it'll show up here."
- **`/account/outbox/view?id=<outbox_id>`** — detail view. Calls `GET /v1/workouts/outbox/:id`, renders the full `payload.session.exercises[]` as a per-exercise table with target vs actual columns (weight, reps, time, RPE). Includes a **Delete** button that calls `DELETE /v1/workouts/outbox/:id` and navigates back to the list — privacy escape hatch for the user.

Both pages share `AccountLayout` and the `account-table` / `badge` / `mono` styling already established by `/account/index.astro` and `/account/login.astro`. Both gate on `requireSessionOrRedirect()` and 401-redirect to `/account/login` on auth loss.

### Why query-param routing for detail

Astro builds static and the site upload is via S3 + CloudFront. A truly dynamic route (`/account/outbox/[id].astro`) would need `getStaticPaths` we can't satisfy at build time. The detail page is a static HTML shell that reads `?id=` at runtime and fetches client-side, so the same compiled HTML serves every detail URL. Browser back/forward and shareable links still work since the URL changes.

### Cross-link from the account index

`/account/index.astro` gets a small "Workout outbox" section pointing to the list page. Mirrors the existing "Workout inbox" section's affordance level (it's a side door, not the headline feature).

## Telemetry

`Logger.shared.info(.network, ...)` events on iOS:

- `outbox_enqueue` — `{client_session_id}`
- `outbox_push_attempt` — `{client_session_id, attempt}`
- `outbox_push_success` — `{client_session_id, outbox_id}`
- `outbox_push_giveup_4xx` — `{client_session_id, status, body_snippet}` (logged via `Logger.shared.error`)
- `outbox_flush_complete` — `{pushed, retried, failed, queue_size_after}`
- `outbox flush blocked: authentication required` — `{pendingCount}` (logged via `Logger.shared.error(.sync, …)`; also a single Sentry capture per flush cycle with `tag: "outbox_auth_failure"`)

No Sentry error captures for normal flows (network blips are not bugs). 4xx-other-than-429 is a real bug; log via Sentry. **Auth failure with a non-empty queue is also a real, user-impacting bug** (a completed workout silently never synced — GH #143); it captures once per flush cycle.

## Out of scope (v1)

- Editing/PATCH after push (snapshot is final).
- Agent-write to outbox (agents read only).
- Server-side reaper job (trim-on-write is enough).
- Time-based retention windows.
- Per-token scope split (`workouts:history:read`) — piggybacks on `workouts:read` until a use case for finer-grained access appears.
- Multi-device "who pushed first" race resolution beyond ring-buffer eventual consistency.

## Cross-references

- [[project-issue-71-design]] — umbrella for the identity + inbox/outbox surface.
- [workout-inbox.md](workout-inbox.md) — symmetric service; share infra patterns.
- [../data/database-schema.md](../data/database-schema.md) — local `outbox_pending_queue` schema (v17).
- [[feedback-auth-modality-matches-caller]] — dual-auth design.
- [[project-lmwf-plan-not-record]] — explains why outbox payload is JSON, not LMWF.

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
| DELETE | `/v1/workouts/outbox/:outbox_id`    | `workouts:read`   | User-initiated removal (privacy). Returns 204; 404 if not owned.                                         |

Notes:
- **No ack/ingest lifecycle.** Outbox items don't transition states — they exist (most-recent-N) or are reaped. There is no "ingested" because the consumers (agents) are stateless callers.
- **DELETE uses `workouts:read` scope, not a separate write scope**, matching the inbox DELETE convention. Rationale: if a token can read history, it can prune its view of it. Tokens with no read access cannot delete blindly.
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
- **Single in-flight push gate** (`isFlushing`) — drains the queue serially, oldest first.
- **Per-item flow**:
  1. Read the `WorkoutSession` from `workout_sessions` + descendants.
  2. Run `WorkoutExportService.exportSingleSessionAsJson` to produce the envelope (in-memory; do not write a file).
  3. `POST /v1/workouts/outbox` with the envelope + `client_session_id`.
  4. On 2xx: delete the queue row.
  5. On 4xx (other than 429): log, delete the queue row (no point retrying a bad payload), and report via `Logger.shared.error`.
  6. On 5xx / network / 429: increment `attempt_count`, set `next_attempt_after = now + backoff(attempt_count)`, leave the row in place.
- **Backoff**: 30s, 2m, 10m, 30m, 2h (capped). After 10 attempts, log a Sentry breadcrumb (not an error capture per [[reference-sentry-metadata-allowlist]]) and keep retrying — a sustained 5xx for hours means something is wrong on the server, not the client.
- **No CloudKit ack flow**. The outbox is one-way; once the server accepts the row, the device's job is done.

### Settings surface

A small status pill in Settings → "Account → Sync to account":

- "All workouts synced" (queue empty).
- "N workout(s) pending sync. [Sync now]" (queue non-empty).
- Tapping "Sync now" calls the flush method explicitly.

No outbox-browsing UI — the surface for "my completed workouts" remains the History tab, fed by the local database. The outbox is a side-channel for agents, not a user-facing collection.

### Sign-out behavior

Local `outbox_pending_queue` table is wiped on logout — the queue is session-scoped device state, matching the inbox convention. Server-side outbox rows stay (they outlive any single device install).

### Conflict + dedup rules

- Re-pushing the same `client_session_id` is a no-op server-side (returns the existing row).
- A second device with the same session synced down via CloudKit will not push it — the queue is only seeded by the completion event, not by sync. Each device pushes only sessions it owns the completion of.
- Editing a completed workout after push **does not retroactively update the server**. The outbox is a snapshot at completion time, not a live mirror of `workout_sessions`. (Future: add `PATCH /v1/workouts/outbox/:outbox_id` if this proves limiting. Out of scope v1.)

## Telemetry

`Logger.shared.info(.network, ...)` events on iOS:

- `outbox_enqueue` — `{client_session_id}`
- `outbox_push_attempt` — `{client_session_id, attempt}`
- `outbox_push_success` — `{client_session_id, outbox_id}`
- `outbox_push_giveup_4xx` — `{client_session_id, status, body_snippet}` (logged via `Logger.shared.error`)
- `outbox_flush_complete` — `{pushed, retried, failed, queue_size_after}`

No Sentry error captures for normal flows (network blips are not bugs). 4xx-other-than-429 is a real bug; log via Sentry.

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

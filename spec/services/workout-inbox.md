# Workout Inbox Service Specification

## Purpose

Receive workout plans pushed to a user from outside the app (e.g., Claude Code via PAT) and surface them in the iOS app as a reviewable "inbox" before they become part of the user's plan library.

The user explicitly decides what to do with each inbox item — discard, save to plans, or start now — so an inbox never silently mutates the plan library.

## End-to-end flow

```
External client (PAT) ──POST /v1/workouts──► Server inbox (DDB)
                                                │
                                                │ GET /v1/workouts?status=pending
                                                ▼
                                        iOS InboxPollerService
                                                │
                                                │ upsert (key = server inbox_id)
                                                ▼
                                       Local workout_inbox table
                                                │
                                                ▼
                                       Plans screen → Inbox section
                                                │
                                       ┌────────┼────────┐
                                       │        │        │
                                    Discard  Add to  Start workout
                                              Plans   (promote + start)
                                       │        │        │
                                       ▼        ▼        ▼
                            DELETE         promote → workout_templates
                            /v1/workouts/  + delete from inbox
                            :inbox_id      + DELETE server row
```

## Server side

### Persistence

`workout_inbox` DynamoDB table — see `validator/src/infra/tables.ts`.

Each row stores:
- `inbox_id` (ULID sort key, scoped by `user_id` partition key)
- `lmwf_text` — original markdown
- `parsed_json` — the full parsed `WorkoutPlan` (not just the summary projection)
- `status` — `pending` until iOS has fetched the detail; `ingested` after iOS's GET acknowledges receipt
- `source_token_id` — PAT ULID or `"session"` for portal-pushed items
- `created_at`, `ingested_at`

### Endpoints

| Method | Path                          | Scope           | Description                                                                                 |
|--------|-------------------------------|-----------------|---------------------------------------------------------------------------------------------|
| POST   | `/v1/workouts`                | `workouts:write`| Push a new workout (LMWF body). Returns inbox item summary + warnings.                      |
| GET    | `/v1/workouts?status=pending` | `workouts:read` | List pending items (latest first). Returns summary only.                                     |
| GET    | `/v1/workouts/:inbox_id`      | `workouts:read` | Fetch one item including `workout` (full parsed plan) and `lmwf_text`.                      |
| POST   | `/v1/workouts/:inbox_id/ack`  | `workouts:read` | Mark item `ingested`. Idempotent. iOS calls this once the item is stored in the local inbox.|
| DELETE | `/v1/workouts/:inbox_id`      | `workouts:read` | Hard-delete the row. Called by iOS on Discard and after Promote/Start.                       |

Both `ack` and `DELETE` require the row to belong to the authenticated user (404 otherwise — no leak about whether the row exists).

### Auth model

Resource endpoints (`/v1/workouts/*`) accept session JWT **OR** PAT — see `validator/src/middleware/auth.ts`. Pushes from the web portal use the session; pushes from Claude Code use a PAT.

## iOS side

### Local persistence

Local GRDB table `workout_inbox` — see `spec/data/database-schema.md`. Keyed by server `inbox_id` so re-polling is idempotent.

Stored columns:
- `inbox_id` (PK, server ULID)
- `fetched_at` — when this device first stored it
- `lmwf_text` — markdown, used for "View source"
- `workout_json` — the full parsed `WorkoutPlan` as JSON (the iOS-side decoder rehydrates on demand)
- `summary_name`, `summary_exercise_count`, `summary_set_count` — denormalized for fast list rendering without parsing `workout_json`
- `source_token_id` — for display ("From: Claude Code", etc.)
- `created_at_server` — server-side `created_at`

The table is **device-local**. It is not synced via CloudKit and is not included in `.db` backup exports (server is the source of truth — a fresh install will repopulate from `/v1/workouts?status=pending`).

### Poller

`InboxPollerService`:

- Triggered on foreground transition and when user taps **Sync now** in Settings.
- Single in-flight poll (`isPolling` gate).
- Fetches the listing, then for each item the detail, then upserts into the local inbox table.
- Calls `/ack` once the upsert succeeds. Ack failure is non-fatal — server will return the same item next poll, the local upsert is a no-op (same `inbox_id`).
- Per-item decode/store failures are logged and skipped; the item stays pending server-side for retry on next poll.

Removed from the v1 poller:
- Auto-creation of `WorkoutPlan` rows. The poller no longer touches `workout_templates`.
- `syncCompleted` `NotificationCenter` post for the workout-plan store.

### Inbox section UI

Lives at the top of the Plans screen — see `spec/screens/workouts.md`.

Always visible. Empty state: "No new workouts in your inbox."

Row actions (swipe or context menu):

| Action          | Behavior                                                                                                                                                  |
|-----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| Discard         | Local row deleted; `DELETE /v1/workouts/:inbox_id` fired. On network failure: row stays gone locally; server row dies on next sync (or is reaped by TTL). |
| Add to Plans    | Promote: insert a `WorkoutPlan` from `workout_json`; delete the inbox row; `DELETE` the server row.                                                       |
| Start Workout   | Promote (as above), then open the newly created plan's detail screen. v1 stops here — the user taps Start on the detail screen. (Future: skip the detail screen and open Active Workout directly.) |

Tap on a row (not swipe) opens a read-only detail sheet (`InboxPreviewSheet`) — workout name, tags, default unit, description, and a card per exercise listing each set's target weight/reps/time/RPE plus per-set modifier chips (drop, per-side, rest, tempo). Footer holds the same three actions; selecting one dismisses the sheet and runs the action on the parent (`InboxSectionView` owns the queue/server reconciliation).

### Conflict + dedup rules

- Re-polling the same `inbox_id` is a no-op (upsert). Promotion creates a fresh `WorkoutPlan` UUID each time — so accidentally pushing the same workout twice yields two inbox items that promote to two distinct plans (or the user discards the duplicate).
- Promotion is one-shot: once a `WorkoutPlan` is created from an inbox item, the inbox row is deleted. There is no "re-import from inbox history" — the server-side row is also deleted.
- A signed-out user's inbox table is wiped on logout (treating inbox as session-scoped device state).

## Telemetry

`Logger.shared.info(.network, ...)` events:

- `inbox_poll_complete` — `{fetched, upserted, acked, errors}`
- `inbox_discard` — `{inbox_id}`
- `inbox_promote` — `{inbox_id, plan_id, started: bool}`
- Errors via `Logger.shared.error(.network, ...)` with full error.

No Sentry capture for normal flows; only unexpected decode/DB failures.

## Open items

- TTL/reaping of stale server-side inbox rows (e.g., `ingested` for >30 days). Out of scope v1.
- Multi-device behavior: two devices polling concurrently will both see the same pending items; ack is idempotent. First-to-act may delete the server row; the other device's promote will fail the server DELETE but local promote still succeeds. Acceptable for v1.

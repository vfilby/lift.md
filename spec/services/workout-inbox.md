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
- `lmwf_text` — original markdown; **the single source of truth**
- `status` — `pending` until iOS has fetched the detail; `ingested` after iOS's GET acknowledges receipt
- `source_token_id` — PAT ULID or `"session"` for portal-pushed items
- `created_at`, `ingested_at`

The server does **not** persist the parsed result. Pushes are still validated
on receipt (invalid LMWF is rejected with `422` and nothing is enqueued), but
the parse output is discarded. The `workout` (full `WorkoutPlan`) and `summary`
fields the read endpoints return are derived **on read** by re-parsing
`lmwf_text` — so there is no stored pre-parse to drift away from the markdown.
Inboxes are small (per-user, default 50), so parsing on read is cheap and needs
no caching. If a row's markdown ever fails to parse on read, `workout`/`summary`
degrade to `null` rather than failing the request.

> DynamoDB is schemaless, so this needs no migration. Rows written before this
> change may still carry a now-ignored `parsed_json` attribute; the server no
> longer reads it, and new rows are written without it.

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

### Web portal inbox table

The account dashboard (`website/src/pages/account/index.astro`) renders the inbox as a triage-first table. The top-level row carries only what the user needs to decide what to do; identifying and quantitative detail collapses into an expandable row.

Top-level columns:

| Column   | Content                                                              |
|----------|---------------------------------------------------------------------|
| ▸        | Expander toggle (`details.row-detail`).                             |
| Title    | `summary.workoutName` (falls back to `—`).                         |
| Date     | `created_at`, formatted.                                            |
| Status   | Badge: `pending` / `ingested` / `rejected`.                        |
| Actions  | `Mark ingested` (pending only), `Download`, `Delete`.              |

Deliberately **not** in the top-level row: inbox ID, source/source-token, exercise count, set count.

Expanded detail row (one per item, hidden until the expander opens):

- ID (first 8 chars, full ID on hover) + source label, small/muted.
- Tags, if any (chips).
- Exercise count + total set count.
- Per-exercise breakdown: name, set count, and a group-type chip (superset/circuit) when present — so the user can tell what the workout contains without downloading it.

Actions wire to the resource endpoints (session JWT):

- **Mark ingested** → `POST /v1/workouts/:inbox_id/ack`, then refresh.
- **Download** → `GET /v1/workouts/:inbox_id` for the full `lmwf_text`, then triggers a client-side download of a `<name>.lmwf.md` file.
- **Delete** → `DELETE /v1/workouts/:inbox_id` (confirmed), then refresh.

## iOS side

### Local persistence

Local GRDB table `workout_inbox` — see `spec/data/database-schema.md`. Keyed by server `inbox_id` so re-polling is idempotent.

Stored columns:
- `inbox_id` (PK, server ULID)
- `fetched_at` — when this device first stored it
- `lmwf_text` — original markdown; the **single source of truth** for preview, promotion, and "View source"
- `source_token_id` — for display ("From: Claude Code", etc.)
- `created_at_server` — server-side `created_at`

No pre-parse is persisted (the `workout_json` / `summary_*` columns were dropped in schema v18). The server still returns a `workout` field on the detail call for backward compatibility, but the client **ignores it** — `lmwf_text` is the only thing stored.

The list/preview summary (name + exercise/set counts) is **derived in memory** by parsing `lmwf_text` with `MarkdownParser` when items are loaded (the repository assembles each `InboxItem` with a parsed summary; held in memory, never persisted). Parsing is pure string work, done at load time rather than on every SwiftUI render.

Promotion and preview both parse `lmwf_text` through the canonical `MarkdownParser.parseWorkout` path — the same path every other import uses. This is the root-cause fix for grouping bugs (e.g. supersets): a promoted plan is byte-identical to importing that markdown as a file, with `parentExerciseId` grouping intact and `sourceMarkdown` set to `lmwf_text` (so Edit / Reprocess / Export work on inbox plans).

The table is **device-local**. It is not synced via CloudKit and is not included in `.db` backup exports (server is the source of truth — a fresh install will repopulate from `/v1/workouts?status=pending`).

### Poller

`InboxPollerService`:

- Triggered on foreground transition and when user taps **Sync now** in Settings.
- Single in-flight poll (`isPolling` gate).
- Fetches the listing, then for each item the detail, then upserts into the local inbox table. Only `lmwf_text` + metadata (`inbox_id`, `created_at`, `source_token_id`) are decoded and stored; the server's structured `workout` field is ignored.
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
| Add to Plans    | Promote: parse `lmwf_text` via `MarkdownParser`, set the plan's `sourceMarkdown = lmwf_text`, insert the `WorkoutPlan`; delete the inbox row; `DELETE` the server row.                                                       |
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

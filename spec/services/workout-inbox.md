# Workout Inbox Service Specification

## Purpose

Receive workout plans pushed to a user from outside the app (e.g., Claude Code via PAT) and surface them in the iOS app as a reviewable "inbox" before they become part of the user's plan library.

The user explicitly decides what to do with each inbox item — discard, save to plans, or start now — so an inbox never silently mutates the plan library.

## End-to-end flow

```
External client (PAT) ──POST /v1/workouts──► Server inbox (DDB)
                                                │
                                                │ GET /v1/workouts   (all undeleted rows)
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
- `status` — `pending` for every live row. A row stays in the inbox as long as it exists; the user removes it by importing or discarding, which **hard-deletes** the row (see Lifecycle below). `ingested` is a legacy state nothing sets anymore (it lingers only on rows acked by a pre-GH #164 client); it does **not** remove the row from the inbox, and clients list rows regardless of status.
- `source_token_id` — PAT ULID or `"session"` for portal-pushed items
- `created_at`, `ingested_at`

#### Lifecycle (durability — GH #164)

The server row **is** the inbox entry, and it is the durable source of truth. A
row lives in exactly two states from the inbox's perspective: **present** (the
row exists → it's in the inbox) and **gone** (the row was hard-deleted because
the user imported or discarded it). There is no intermediate "the client has
seen this" state that removes it from the listing.

This is the root-cause fix for GH #164. The previous design had iOS `ack` each
item on fetch (`pending`→`ingested`) and then list only `status=pending`. Once
acked, an item could never be re-listed — so any loss of the device-local cache
(logout wipe, reinstall, the v18 `DROP TABLE workout_inbox` migration, or a
second device) stranded the item server-side as `ingested`, invisible and
impossible to import or delete. The local table is now a pure disposable cache:
it can be wiped at any time and the next poll rebuilds it from the server.

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
| GET    | `/v1/workouts`                | `workouts:read` | List items (latest first). iOS sends no `status` filter so it sees every live row; an optional `?status=` filter still works for the web portal. Returns summary only. |
| GET    | `/v1/workouts/:inbox_id`      | `workouts:read` | Fetch one item including `workout` (full parsed plan) and `lmwf_text`.                      |
| POST   | `/v1/workouts/:inbox_id/ack`  | `workouts:write`| **Orphaned/legacy.** Marks item `ingested`. No client calls it anymore (iOS and the web portal both stopped — GH #164); kept only so old rows/clients don't 404. Idempotent. |
| DELETE | `/v1/workouts/:inbox_id`      | `workouts:write`| Hard-delete the row. The **only** way an item leaves the inbox. Called by iOS on Discard and after Promote/Start. |

Both `ack` and `DELETE` are state-changing and require `workouts:write` (a read-only PAT must not be able to flip ingestion state or delete rows — least-privilege for tokens handed to third-party agents). They also require the row to belong to the authenticated user (404 otherwise — no leak about whether the row exists).

### Auth model

Resource endpoints (`/v1/workouts/*`) accept session JWT **OR** PAT — see `validator/src/middleware/auth.ts`. Pushes from the web portal use the session; pushes from Claude Code use a PAT.

**PAT scope allowlist.** `POST /v1/tokens` validates requested scopes against a server-side allowlist (`ALLOWED_SCOPES` in `validator/src/routes/tokens.ts`) — currently exactly the scopes the API enforces: `workouts:read`, `workouts:write`. Unknown scopes are rejected with `400`, and the array is length-capped. This keeps any future privileged scope deny-by-default for self-service token creation (a user cannot pre-mint a token carrying a scope the server hasn't yet wired up).

### Web portal inbox table

The account dashboard (`website/src/pages/account/index.astro`) renders the inbox as a triage-first table. The top-level row carries only what the user needs to decide what to do; identifying and quantitative detail collapses into an expandable row.

Top-level columns:

| Column   | Content                                                              |
|----------|---------------------------------------------------------------------|
| ▸        | Expander toggle (`details.row-detail`).                             |
| Title    | `summary.workoutName` (falls back to `—`).                         |
| Date     | `created_at`, formatted.                                            |
| Status   | Badge: `pending` / `ingested` / `rejected`. `ingested` only appears on legacy rows left over from before GH #164 — nothing sets it anymore. |
| Actions  | `Download`, `Delete`.                                              |

Deliberately **not** in the top-level row: inbox ID, source/source-token, exercise count, set count.

Expanded detail row (one per item, hidden until the expander opens):

- ID (first 8 chars, full ID on hover) + source label, small/muted.
- Tags, if any (chips).
- Exercise count + total set count.
- Per-exercise breakdown: name, set count, and a group-type chip (superset/circuit) when present — so the user can tell what the workout contains without downloading it.

Actions wire to the resource endpoints (session JWT):

- **Download** → `GET /v1/workouts/:inbox_id` for the full `lmwf_text`, then triggers a client-side download of a `<name>.lmwf.md` file.
- **Delete** → `DELETE /v1/workouts/:inbox_id` (confirmed), then refresh.

There is no "Mark ingested" action: an item leaves the inbox only by being deleted (here or imported/discarded on a device). The `/ack` endpoint still exists server-side but is now orphaned — see the endpoints table.

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
- Fetches the listing (`GET /v1/workouts`, **no** `status` filter so every live row is returned), then for each item *not already in the local table* the detail, then upserts into the local inbox table. Only `lmwf_text` + metadata (`inbox_id`, `created_at`, `source_token_id`) are decoded and stored; the server's structured `workout` field is ignored.
- **Does not** `ack`. Items are never transitioned server-side by the poll; they remain in the inbox until the user imports or discards them (which `DELETE`s the row). This is what makes the local table a disposable cache that self-heals after a wipe/reinstall (GH #164).
- Rows already present locally are skipped without re-fetching the detail — pending rows are immutable (a push always creates a new `inbox_id`), so re-fetching them is pure waste. Poll cost is proportional to *new* items, not the whole inbox.
- Per-item decode/store failures are logged and skipped; the item stays in the inbox server-side for retry on next poll.

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

- Re-polling the same `inbox_id` is a no-op (the row is already cached, so it's skipped). Promotion creates a fresh `WorkoutPlan` UUID each time — so accidentally pushing the same workout twice yields two inbox items that promote to two distinct plans (or the user discards the duplicate).
- Promotion is one-shot: once a `WorkoutPlan` is created from an inbox item, the inbox row is deleted. There is no "re-import from inbox history" — the server-side row is also deleted.
- A signed-out user's inbox table is wiped on logout (treating inbox as session-scoped device state). This is now lossless: because the poll no longer acks, the server still holds every un-acted item, so signing back in repopulates the inbox from the next poll (GH #164).
- A `DELETE` that fails (offline) leaves the row server-side; the local row is already gone, so the item reappears on the next poll. The user can re-discard. Accepted edge — the alternative (durably queueing the delete) is out of scope.

## Telemetry

`Logger.shared.info(.network, ...)` events:

- `inbox_poll_complete` — `{fetched, upserted, skipped, errors}`
- `inbox_discard` — `{inbox_id}`
- `inbox_promote` — `{inbox_id, plan_id, started: bool}`
- Errors via `Logger.shared.error(.network, ...)` with full error.

No Sentry capture for normal flows; only unexpected decode/DB failures.

## Open items

- TTL/reaping of stale server-side inbox rows the user never acts on. Out of scope v1.
- Multi-device behavior: two devices polling will both see the same items (the poll no longer mutates server state, so there's no first-to-fetch race). First-to-act `DELETE`s the server row; the other device's `DELETE` then 404s harmlessly, and that device drops the stale local row on its next poll only once it also acts — i.e. an item imported/discarded on device A can still linger in device B's local cache until device B acts on it. Reconciling the local cache down to the server set on every poll is a future improvement. Acceptable for v1.
- The legacy `ingested` status + `/ack` endpoint now have no caller (both iOS and the web portal stopped using them in GH #164). The endpoint is kept so stale clients/rows don't 404; removing it (and the `ingested` status, badge, and filter option) entirely is a candidate cleanup.

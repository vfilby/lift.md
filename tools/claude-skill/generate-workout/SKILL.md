---
name: generate-workout
description: Generate a strength training workout plan in LMWF (LiftMark Workout Format). Use when the user asks to write, generate, draft, or plan a workout, training day, training plan, lifting session, program, or asks for something "in LMWF" / "in LiftMark format". Produces valid LMWF markdown, validates it via the live API, and iterates on any errors before returning.
---

# Generate a workout in LMWF

LMWF is a markdown-based format for strength training **plans** (not session records). Full spec: https://workoutformat.liftmark.app/spec.md — fetch it if you need detail beyond what's below.

## Critical semantic: plans, not records

LMWF documents describe what the athlete **intends to do**. Notes express programming intent, technique cues, stop conditions, and targets. **Never** write retrospective content like "felt strong today", "bar path was clean", "last set was a grinder". That is session-log semantics and belongs in the app's session data, not in LMWF.

## Format essentials

```
# Workout Name
@tags: strength, push        # optional, comma-separated
@units: lbs                  # or kg; optional, default is lbs

Workout-level programming note — focus, constraints, stop conditions.

## Exercise Name
Exercise-level note — target ranges, cues, substitutions.

- 135 x 5                    # weight x reps
- 185 x 5 @rest: 180s        # functional modifier: @rest
- 225 x 5 @rest: 180s Aim for RPE 7   # trailing text is a per-set freeform note
- x 10                       # bodyweight (no weight)
- 60s                        # time-based (seconds)
- 2m                         # time-based (minutes)
- 1m 30s                     # time-based (mixed)
```

### Supersets (nested headers, one level deeper)

```
## Arms Superset

### Cable Triceps Pushdown
- 50 x 12
- 50 x 12

### Dumbbell Curl
- 30 x 10
- 30 x 10
```

### Modifiers

- **Functional (use when needed):** `@rest: <duration>`, `@dropset`, `@perside`. These trigger app behavior (timers, drop-set recording, per-side timer for timed sets). `@perside` is primarily for timed per-side sets like `- 30s @perside`; for rep-based sets, prefer trailing prose ("per side", "each leg") which is auto-detected.
- **AMRAP is not a modifier.** Express AMRAP via the rep value (`- 135 x AMRAP` or `- bw x AMRAP`). The validator emits a `DEPRECATED_AMRAP` warning if `@amrap` is used as a flag.
- **Deprecated (do not use — validator emits a warning):** `@rpe`, `@tempo`. Express RPE, tempo, and all descriptive targets as trailing freeform text on the set line (e.g. `- 225 x 5 @rest: 180s Aim for RPE 8, controlled eccentric`).

## Workflow

1. **Generate.** Write the LMWF document based on the user's ask. Default to `@units: lbs` unless the user says kg. Include warmup and cooldown blocks for full sessions; skip them for quick single-exercise drafts. Add programming notes where useful — don't pad.

2. **Validate.** Run the bundled validator:

   ```bash
   ~/.claude/skills/generate-workout/validate.sh <<'EOF'
   # your LMWF here
   EOF
   ```

   or against a file:

   ```bash
   ~/.claude/skills/generate-workout/validate.sh path/to/workout.md
   ```

   The response is JSON with `success`, `summary`, `errors`, `warnings`. If `success: true` and `errors: []`, you're done — if there are warnings, show them to the user but do not block.

3. **Fix and re-validate** on any errors. Common fixes:
   - Bad set format (e.g. using `@rpe` — replace with trailing note).
   - Missing workout H1.
   - Orphan set before first exercise header.
   - Mixed unit suffix in same workout with a different `@units` metadata.

4. **Return** the validated LMWF to the user in a single fenced code block. Do not include the validator's JSON unless asked — the user wants the workout, not the diagnostics.

## Account-aware workflow (when a bearer token is available)

If `LIFTMARK_PAT` is set in the environment (or the user pastes a token like `lm_pat_live_…` into the conversation), you can close the feedback loop: read recent training before generating, and push the validated workout straight to the user's LiftMark inbox so it shows up in the iOS app.

Without a token, fall back to the basic workflow above — generate, validate, hand the LMWF back to the user.

### Before generating: read recent completed workouts (outbox)

Required scope: `workouts:read`. Returns the user's last 20 completed sessions (newest first), so you can avoid same-muscle adjacency, stage progressions on actual loads/reps, and acknowledge what they just finished.

```bash
curl -fsS https://workoutformat.liftmark.app/v1/workouts/outbox \
  -H "Authorization: Bearer $LIFTMARK_PAT"
```

Response shape (summary list):

```json
{
  "items": [
    {
      "outbox_id": "01HXXXX…",
      "session_name": "Push Day",
      "session_completed_at": "2026-05-25T18:28:00Z",
      "source_device_id": "…",
      "created_at": "…"
    }
  ]
}
```

For per-set detail on one session (target vs actual weight, reps, time, RPE):

```bash
curl -fsS https://workoutformat.liftmark.app/v1/workouts/outbox/<outbox_id> \
  -H "Authorization: Bearer $LIFTMARK_PAT"
```

Returns `{ outbox_id, session_name, session_completed_at, payload: { session: { name, date, duration, exercises: [{exerciseName, sets: [{targetWeight, targetWeightUnit, targetReps, actualWeight, actualReps, actualTime, …}]}] } } }`. Read the most recent 2–3 sessions before generating — that's usually enough context.

### After validating: push the workout (inbox)

Required scope: `workouts:write`. The workout lands in the iOS app's Plans → Inbox section for the user to review and start.

```bash
curl -fsS -X POST https://workoutformat.liftmark.app/v1/workouts \
  -H "Authorization: Bearer $LIFTMARK_PAT" \
  -H "Content-Type: text/markdown" \
  --data-binary @workout.md
```

Or with the LMWF in a JSON wrapper:

```bash
curl -fsS -X POST https://workoutformat.liftmark.app/v1/workouts \
  -H "Authorization: Bearer $LIFTMARK_PAT" \
  -H "Content-Type: application/json" \
  -d '{"lmwf": "# Push Day\n@units: lbs\n..."}'
```

Response on success (HTTP 201):

```json
{
  "inbox_id": "01HXXXX…",
  "status": "pending",
  "created_at": "…",
  "summary": { "workoutName": "...", "exerciseCount": 5, "totalSetCount": 14, "exercises": [...] },
  "warnings": []
}
```

The push is **idempotent on content**: if an identical workout (byte-for-byte, modulo surrounding whitespace) is already sitting unread in the inbox, the server returns **HTTP 200** with the existing item and a `"deduplicated": true` field instead of creating a second copy. Same shape as above, plus `"deduplicated": true`. This only matches *pending* items — re-pushing a workout the user already imported or discarded creates a fresh one — and is content-keyed, so an edited re-push (e.g. one more set) is a distinct item. A 200 here is **success, not an error**; surface it as "already in your inbox" rather than re-queuing.

After a successful push, surface the inbox_id + summary line to the user — "Queued — Push Day, 5 exercises, 14 sets. Open the LiftMark app to start it." for a 201, or "Already in your inbox — Push Day …" for a deduplicated 200. Do **not** push without validating first — `/v1/workouts` re-validates server-side and returns 422 on parse errors, but pre-validating with `validate.sh` is faster and gives you a chance to fix issues before involving the user's account.

### Token handling

- Never log or echo the token. Use `Authorization: Bearer "$LIFTMARK_PAT"` directly — don't print it into transcripts.
- A 401 means the token is missing, malformed, revoked, or expired. A 403 means scope mismatch (e.g. trying to push with a read-only token).
- Token management lives at https://liftmark.app/account — users mint and revoke tokens there.

## Reference

- Full spec (markdown): https://workoutformat.liftmark.app/spec.md
- Human docs + in-browser validator: https://workoutformat.liftmark.app/
- Validator API: `POST https://workoutformat.liftmark.app/validate` (Content-Type `application/json` with `{"markdown": "..."}` or `text/markdown` with the raw body)
- Inbox API (push, requires `workouts:write` PAT): `POST https://workoutformat.liftmark.app/v1/workouts`
- Outbox API (read recent completions, requires `workouts:read` PAT): `GET https://workoutformat.liftmark.app/v1/workouts/outbox` and `GET …/outbox/<outbox_id>`

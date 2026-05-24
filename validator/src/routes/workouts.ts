/**
 * /v1/workouts — workout inbox endpoints (PAT or session auth).
 *
 * Third-party clients (Claude Code, ChatGPT, scripts) push LMWF workouts
 * here; the iOS app polls and ingests into CloudKit. Server can't write
 * CloudKit, so this inbox is the seam. The web dashboard also reaches
 * these endpoints with a session JWT so a logged-in user can inspect and
 * push to their own inbox.
 *
 * Routes:
 *   - POST   /v1/workouts             push a workout (workouts:write)
 *   - GET    /v1/workouts             list pending/ingested/rejected (workouts:read)
 *   - GET    /v1/workouts/:inbox_id   fetch full item incl. lmwf_text (workouts:read)
 *   - POST   /v1/workouts/:inbox_id/ack  mark ingested (workouts:read)
 *
 * Scopes are enforced for PATs only — session JWTs implicitly satisfy any
 * scope (the user is logged in and inspecting their own account).
 *
 * Parse-and-shape duplicates /validate's logic by design — see the slice
 * notes for the future cleanup.
 */
import { Hono } from 'hono';
import { ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import { parseWorkout, type WorkoutPlan } from '../parser/index.js';
import { requireScope, type AuthVariables } from '../middleware/auth.js';
import {
  createInboxItem,
  deleteInboxItem,
  getInboxItem,
  getInboxItemsByUser,
  markIngested,
  type InboxStatus,
} from '../repositories/workout_inbox.js';

const MAX_INPUT_BYTES = 1_048_576; // 1MB
const MAX_INPUT_LINES = 50_000;
const MAX_EXERCISES = 500;
const MAX_TOTAL_SETS = 10_000;
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;

interface ExerciseSummary {
  name: string;
  setCount: number;
  groupType: string | null;
  groupName: string | null;
  parentExerciseId: string | null;
}

interface WorkoutSummary {
  workoutName: string;
  defaultWeightUnit: string | null;
  tags: string[];
  exerciseCount: number;
  totalSetCount: number;
  exercises: ExerciseSummary[];
}

interface PushBody {
  lmwf?: unknown;
}

type SizeCheck =
  | { kind: 'ok' }
  | { kind: 'too_big'; status: 413; error: string; field: string; value: number };

function checkInputSize(markdown: string): SizeCheck {
  const inputBytes = Buffer.byteLength(markdown, 'utf-8');
  if (inputBytes > MAX_INPUT_BYTES) {
    return {
      kind: 'too_big',
      status: 413,
      error: 'Input exceeds maximum size of 1MB',
      field: 'inputBytes',
      value: inputBytes,
    };
  }
  const lineCount = markdown.split('\n').length;
  if (lineCount > MAX_INPUT_LINES) {
    return {
      kind: 'too_big',
      status: 413,
      error: 'Input exceeds maximum of 50,000 lines',
      field: 'lineCount',
      value: lineCount,
    };
  }
  return { kind: 'ok' };
}

function summarize(
  result: ReturnType<typeof parseWorkout>,
): WorkoutSummary | null {
  if (!result.data) return null;
  return summarizePlan(result.data);
}

/// Derive the summary projection from a stored WorkoutPlan. Used by the
/// list/get endpoints since parsed_json now stores the full WorkoutPlan.
function summarizePlan(plan: WorkoutPlan): WorkoutSummary {
  const exercises: ExerciseSummary[] = plan.exercises.map((ex) => ({
    name: ex.exerciseName,
    setCount: ex.sets.length,
    groupType: ex.groupType,
    groupName: ex.groupName,
    parentExerciseId: ex.parentExerciseId,
  }));
  return {
    workoutName: plan.name,
    defaultWeightUnit: plan.defaultWeightUnit,
    tags: plan.tags,
    exerciseCount: plan.exercises.length,
    totalSetCount: exercises.reduce((sum, ex) => sum + ex.setCount, 0),
    exercises,
  };
}

/// Best-effort summary from an unknown parsed_json blob — old rows persisted
/// before the full-payload migration stored only the summary itself, so we
/// fall back to returning whatever's there if the shape doesn't look like a
/// WorkoutPlan. New rows always go through summarizePlan().
function projectSummaryFromStored(parsed: unknown): WorkoutSummary | null {
  if (parsed === null || parsed === undefined) return null;
  if (typeof parsed !== 'object') return null;
  const obj = parsed as Record<string, unknown>;
  // Heuristic: WorkoutPlan shape carries `exercises` with `sets` arrays.
  // Pre-migration rows have `workoutName`+`exercises[].setCount` instead.
  if (Array.isArray(obj.exercises) && 'name' in obj && !('workoutName' in obj)) {
    return summarizePlan(parsed as WorkoutPlan);
  }
  // Looks like an already-projected summary — pass through.
  return parsed as WorkoutSummary;
}

function log(entry: Record<string, unknown>): void {
  console.log(JSON.stringify(entry));
}

type Variables = AuthVariables & { requestId: string; startTime: number };

export const workoutsRouter = new Hono<{ Variables: Variables }>();

workoutsRouter.post('/', requireScope('workouts:write'), async (c) => {
  const requestId = c.var.requestId;
  const startTime = c.var.startTime;

  const contentType =
    c.req.header('content-type') ?? c.req.header('Content-Type') ?? '';

  let markdown: string | undefined;

  if (contentType.includes('text/markdown')) {
    markdown = await c.req.text();
  } else {
    let bodyStr: string;
    try {
      bodyStr = await c.req.text();
    } catch {
      bodyStr = '';
    }
    if (!bodyStr) {
      return c.json({ error: 'Missing request body' }, 400);
    }
    let parsed: PushBody;
    try {
      parsed = JSON.parse(bodyStr) as PushBody;
    } catch {
      return c.json({ error: 'Invalid JSON body' }, 400);
    }
    if (typeof parsed.lmwf !== 'string') {
      return c.json({ error: 'lmwf field must be a string' }, 400);
    }
    markdown = parsed.lmwf;
  }

  if (!markdown || markdown.trim().length === 0) {
    return c.json({ error: 'Missing or empty lmwf field' }, 400);
  }

  const size = checkInputSize(markdown);
  if (size.kind === 'too_big') {
    log({
      level: 'warn',
      requestId,
      event: 'workouts_push_error',
      status: 413,
      error: size.error,
      [size.field]: size.value,
      durationMs: Date.now() - startTime,
    });
    return c.json(
      {
        success: false,
        summary: null,
        errors: [size.error],
        warnings: [],
        message: size.error,
      },
      413,
    );
  }

  const result = parseWorkout(markdown);

  // Enforce parsed-shape limits — mirrors /validate.
  if (result.data) {
    const exerciseCount = result.data.exercises.length;
    const setCount = result.data.exercises.reduce(
      (sum, ex) => sum + ex.sets.length,
      0,
    );
    if (exerciseCount > MAX_EXERCISES) {
      const err = `Workout exceeds maximum of ${MAX_EXERCISES} exercises (found ${exerciseCount})`;
      log({
        level: 'warn',
        requestId,
        event: 'workouts_push_error',
        status: 413,
        error: err,
        durationMs: Date.now() - startTime,
      });
      return c.json(
        { success: false, summary: null, errors: [err], warnings: [], message: err },
        413,
      );
    }
    if (setCount > MAX_TOTAL_SETS) {
      const err = `Workout exceeds maximum of ${MAX_TOTAL_SETS} total sets (found ${setCount})`;
      log({
        level: 'warn',
        requestId,
        event: 'workouts_push_error',
        status: 413,
        error: err,
        durationMs: Date.now() - startTime,
      });
      return c.json(
        { success: false, summary: null, errors: [err], warnings: [], message: err },
        413,
      );
    }
  }

  if (!result.success) {
    log({
      level: 'warn',
      requestId,
      event: 'workouts_push_rejected',
      status: 422,
      errorCount: result.errors.length,
      warningCount: result.warnings.length,
      durationMs: Date.now() - startTime,
    });
    return c.json(
      {
        success: false,
        summary: summarize(result),
        errors: result.errors,
        warnings: result.warnings,
        message: 'Workout did not parse; nothing was queued.',
      },
      422,
    );
  }

  const summary = summarize(result);
  // Session-authed pushes (web dashboard) record 'session' as their
  // source — distinguishes "pushed via PAT X" from "pushed via the web
  // portal" in the audit trail. PAT pushes record the token's ULID.
  const sourceTokenId = c.var.pat_token_id ?? 'session';
  // Persist the FULL parser result, not just the summary projection. iOS
  // rehydrates a complete WorkoutPlan from this on ingest, so it needs
  // every exercise's full set list (weights, reps, modifiers, notes).
  // The summary projection is derived on read for the list endpoint.
  const item = await createInboxItem({
    user_id: c.var.user.user_id,
    source_token_id: sourceTokenId,
    lmwf_text: markdown,
    parsed_json: result.data,
    status: 'pending',
  });

  log({
    level: 'info',
    requestId,
    event: 'workouts_push_complete',
    status: 201,
    inboxId: item.inbox_id,
    exerciseCount: summary?.exerciseCount ?? 0,
    totalSetCount: summary?.totalSetCount ?? 0,
    warningCount: result.warnings.length,
    durationMs: Date.now() - startTime,
  });

  return c.json(
    {
      inbox_id: item.inbox_id,
      status: item.status,
      created_at: item.created_at,
      summary,
      warnings: result.warnings,
    },
    201,
  );
});

workoutsRouter.get('/', requireScope('workouts:read'), async (c) => {
  const statusRaw = c.req.query('status');
  let status: InboxStatus | undefined;
  if (statusRaw !== undefined) {
    if (statusRaw !== 'pending' && statusRaw !== 'ingested' && statusRaw !== 'rejected') {
      return c.json(
        { error: 'status must be one of: pending, ingested, rejected' },
        400,
      );
    }
    status = statusRaw;
  }

  const sinceCursor = c.req.query('since');

  let limit: number | undefined;
  const limitRaw = c.req.query('limit');
  if (limitRaw !== undefined) {
    const parsed = Number(limitRaw);
    if (!Number.isInteger(parsed) || parsed < 1 || parsed > MAX_LIMIT) {
      return c.json(
        { error: `limit must be an integer between 1 and ${MAX_LIMIT}` },
        400,
      );
    }
    limit = parsed;
  } else {
    limit = DEFAULT_LIMIT;
  }

  const { items, nextCursor } = await getInboxItemsByUser(
    c.var.user.user_id,
    { status, sinceCursor, limit },
  );

  return c.json({
    items: items.map((it) => ({
      inbox_id: it.inbox_id,
      status: it.status,
      created_at: it.created_at,
      ingested_at: it.ingested_at,
      source_token_id: it.source_token_id,
      summary: projectSummaryFromStored(it.parsed_json),
    })),
    next_cursor: nextCursor ?? null,
  });
});

workoutsRouter.get('/:inbox_id', requireScope('workouts:read'), async (c) => {
  const inboxId = c.req.param('inbox_id');
  const item = await getInboxItem(c.var.user.user_id, inboxId);
  if (!item) {
    return c.json({ error: 'Inbox item not found' }, 404);
  }
  // `workout` exposes the full stored WorkoutPlan so iOS can rehydrate
  // without re-parsing LMWF locally. `summary` stays for clients that
  // only need the lightweight projection (and matches what list returns).
  return c.json({
    inbox_id: item.inbox_id,
    user_id: item.user_id,
    status: item.status,
    created_at: item.created_at,
    ingested_at: item.ingested_at,
    source_token_id: item.source_token_id,
    summary: projectSummaryFromStored(item.parsed_json),
    workout: item.parsed_json,
    lmwf_text: item.lmwf_text,
  });
});

workoutsRouter.post('/:inbox_id/ack', requireScope('workouts:read'), async (c) => {
  const inboxId = c.req.param('inbox_id');
  try {
    await markIngested(c.var.user.user_id, inboxId);
  } catch (err) {
    if (err instanceof ConditionalCheckFailedException) {
      return c.json({ error: 'Inbox item not found' }, 404);
    }
    throw err;
  }
  return c.body(null, 204);
});

// Hard-delete an inbox row. Used by iOS on Discard and after Promote/Start
// — the local app has committed (or thrown away) the workout and the server
// row is no longer needed. The condition expression scopes the delete to
// the caller's user_id, so foreign rows 404 silently with no existence leak.
workoutsRouter.delete('/:inbox_id', requireScope('workouts:read'), async (c) => {
  const inboxId = c.req.param('inbox_id');
  try {
    await deleteInboxItem(c.var.user.user_id, inboxId);
  } catch (err) {
    if (err instanceof ConditionalCheckFailedException) {
      return c.json({ error: 'Inbox item not found' }, 404);
    }
    throw err;
  }
  return c.body(null, 204);
});

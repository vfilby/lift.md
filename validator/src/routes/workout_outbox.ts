/**
 * /v1/workouts/outbox — completed-workout outbox (PAT or session auth).
 *
 * The reverse direction of the workout inbox: iOS pushes completed sessions
 * here so external agents (Claude Code, ChatGPT, scripts) can read recent
 * training history to give the user feedback and shape the next workout.
 * Last 20 items per user; ring-buffer trim on every write. See
 * `spec/services/workout-outbox.md`.
 *
 * Routes:
 *   - POST   /v1/workouts/outbox              push (workouts:write)
 *   - GET    /v1/workouts/outbox              list last 20 (workouts:read)
 *   - GET    /v1/workouts/outbox/:outbox_id   fetch one (workouts:read)
 *   - DELETE /v1/workouts/outbox/:outbox_id   user-initiated removal (workouts:read)
 */
import { Hono } from 'hono';
import { ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import { requireScope, type AuthVariables } from '../middleware/auth.js';
import {
  createOutboxItem,
  deleteOutboxItem,
  getOutboxItem,
  getOutboxItemsByUser,
  type OutboxItem,
} from '../repositories/workout_outbox.js';

const MAX_INPUT_BYTES = 1_048_576; // 1MB — matches inbox / validate.

type Variables = AuthVariables & { requestId: string; startTime: number };

interface PushBody {
  client_session_id?: unknown;
  export?: unknown;
  source_device_id?: unknown;
}

interface ExportEnvelope {
  exportedAt?: unknown;
  appVersion?: unknown;
  session?: {
    name?: unknown;
    endTime?: unknown;
    status?: unknown;
    exercises?: unknown;
    [k: string]: unknown;
  };
}

function log(entry: Record<string, unknown>): void {
  console.log(JSON.stringify(entry));
}

function outboxItemToSummary(item: OutboxItem): Record<string, unknown> {
  return {
    outbox_id: item.outbox_id,
    client_session_id: item.client_session_id,
    session_name: item.session_name,
    session_completed_at: item.session_completed_at,
    created_at: item.created_at,
    source_device_id: item.source_device_id,
  };
}

export const outboxRouter = new Hono<{ Variables: Variables }>();

outboxRouter.post('/', requireScope('workouts:write'), async (c) => {
  const requestId = c.var.requestId;
  const startTime = c.var.startTime;

  // Read the raw body once so we can size-check before parsing.
  let raw: string;
  try {
    raw = await c.req.text();
  } catch {
    raw = '';
  }

  if (!raw) {
    return c.json({ error: 'Missing request body' }, 400);
  }

  const bodyBytes = Buffer.byteLength(raw, 'utf-8');
  if (bodyBytes > MAX_INPUT_BYTES) {
    log({
      level: 'warn',
      requestId,
      event: 'outbox_push_error',
      status: 413,
      error: 'Body exceeds 1MB',
      bodyBytes,
      durationMs: Date.now() - startTime,
    });
    return c.json({ error: 'Body exceeds maximum size of 1MB' }, 413);
  }

  let parsed: PushBody;
  try {
    parsed = JSON.parse(raw) as PushBody;
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  if (typeof parsed.client_session_id !== 'string' || !parsed.client_session_id.trim()) {
    return c.json({ error: 'client_session_id is required' }, 400);
  }
  const clientSessionId = parsed.client_session_id.trim();

  if (!parsed.export || typeof parsed.export !== 'object') {
    return c.json({ error: 'export envelope is required' }, 400);
  }
  const envelope = parsed.export as ExportEnvelope;
  const session = envelope.session;
  if (!session || typeof session !== 'object') {
    return c.json({ error: 'export.session is required' }, 400);
  }

  // Completed-only guard: outbox is for finished workouts.
  if (typeof session.endTime !== 'string' || !session.endTime) {
    return c.json(
      { error: 'export.session.endTime is required (completed sessions only)' },
      422,
    );
  }
  if (session.status !== 'completed') {
    return c.json(
      { error: 'export.session.status must be "completed"' },
      422,
    );
  }

  const sessionName =
    typeof session.name === 'string' && session.name ? session.name : 'Workout';
  const sourceDeviceId =
    typeof parsed.source_device_id === 'string' ? parsed.source_device_id : null;

  const exerciseArr = Array.isArray(session.exercises) ? session.exercises : [];
  const exerciseCount = exerciseArr.length;
  let setCount = 0;
  for (const ex of exerciseArr) {
    if (ex && typeof ex === 'object' && Array.isArray((ex as { sets?: unknown }).sets)) {
      setCount += ((ex as { sets: unknown[] }).sets).length;
    }
  }

  const { item, dedupHit, trimmedCount } = await createOutboxItem({
    user_id: c.var.user.user_id,
    source_device_id: sourceDeviceId,
    client_session_id: clientSessionId,
    payload_json: envelope,
    session_completed_at: session.endTime,
    session_name: sessionName,
  });

  log({
    level: 'info',
    requestId,
    event: 'outbox_push_complete',
    status: dedupHit ? 200 : 201,
    outboxId: item.outbox_id,
    clientSessionId,
    dedupHit,
    exerciseCount,
    totalSetCount: setCount,
    trimmedCount,
    durationMs: Date.now() - startTime,
  });

  return c.json(
    {
      outbox_id: item.outbox_id,
      client_session_id: item.client_session_id,
      session_name: item.session_name,
      session_completed_at: item.session_completed_at,
      created_at: item.created_at,
      dedup_hit: dedupHit,
    },
    dedupHit ? 200 : 201,
  );
});

outboxRouter.get('/', requireScope('workouts:read'), async (c) => {
  const startTime = c.var.startTime;
  const items = await getOutboxItemsByUser(c.var.user.user_id);
  log({
    level: 'info',
    requestId: c.var.requestId,
    event: 'outbox_list',
    count: items.length,
    durationMs: Date.now() - startTime,
  });
  return c.json({ items: items.map(outboxItemToSummary) });
});

outboxRouter.get('/:outbox_id', requireScope('workouts:read'), async (c) => {
  const outboxId = c.req.param('outbox_id');
  const item = await getOutboxItem(c.var.user.user_id, outboxId);
  log({
    level: 'info',
    requestId: c.var.requestId,
    event: 'outbox_get',
    outboxId,
    found: item !== null,
  });
  if (!item) {
    return c.json({ error: 'Outbox item not found' }, 404);
  }
  return c.json({
    outbox_id: item.outbox_id,
    client_session_id: item.client_session_id,
    session_name: item.session_name,
    session_completed_at: item.session_completed_at,
    created_at: item.created_at,
    source_device_id: item.source_device_id,
    payload: item.payload_json,
  });
});

outboxRouter.delete('/:outbox_id', requireScope('workouts:read'), async (c) => {
  const outboxId = c.req.param('outbox_id');
  const startTime = c.var.startTime;
  try {
    await deleteOutboxItem(c.var.user.user_id, outboxId);
  } catch (err) {
    if (err instanceof ConditionalCheckFailedException) {
      return c.json({ error: 'Outbox item not found' }, 404);
    }
    throw err;
  }
  log({
    level: 'info',
    requestId: c.var.requestId,
    event: 'outbox_delete',
    outboxId,
    durationMs: Date.now() - startTime,
  });
  return c.body(null, 204);
});

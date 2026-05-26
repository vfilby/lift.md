/**
 * Workout outbox repository.
 *
 * Completed iOS sessions are pushed here so external agents (Claude Code,
 * ChatGPT, scripts) can read recent training history via PAT. Last-20-items
 * per user, ring-buffer trim on every write. See
 * `spec/services/workout-outbox.md` for the full design.
 *
 * Table layout (see src/infra/tables.ts):
 *   - PK: user_id, SK: outbox_id (ULID — lexicographic = chronological)
 *   - GSI 'client-session-index': PK=user_id, SK=client_session_id
 *     (dedup lookup on POST to make pushes idempotent across retries)
 */
import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  QueryCommand,
} from '@aws-sdk/lib-dynamodb';
import { ulid } from 'ulid';
import { ddb, tableName } from '../infra/ddb.js';

export const MAX_OUTBOX_ITEMS_PER_USER = 20;

export interface OutboxItem {
  outbox_id: string;
  user_id: string;
  source_device_id: string | null;
  client_session_id: string;
  payload_json: unknown;
  created_at: string;
  session_completed_at: string;
  session_name: string;
}

export interface CreateOutboxItemInput {
  user_id: string;
  source_device_id?: string | null;
  client_session_id: string;
  payload_json: unknown;
  session_completed_at: string;
  session_name: string;
}

export interface CreateOutboxItemResult {
  item: OutboxItem;
  dedupHit: boolean;
  trimmedCount: number;
}

export interface ListOutboxOptions {
  limit?: number;
}

export async function createOutboxItem(
  input: CreateOutboxItemInput,
): Promise<CreateOutboxItemResult> {
  // Dedup: if this (user_id, client_session_id) has already been pushed,
  // return the existing row instead of writing a duplicate. The retry queue
  // on iOS will replay the same body on transient failures, so this needs
  // to be cheap and idempotent.
  const existing = await findByClientSession(
    input.user_id,
    input.client_session_id,
  );
  if (existing) {
    return { item: existing, dedupHit: true, trimmedCount: 0 };
  }

  const item: OutboxItem = {
    outbox_id: ulid(),
    user_id: input.user_id,
    source_device_id: input.source_device_id ?? null,
    client_session_id: input.client_session_id,
    payload_json: input.payload_json,
    created_at: new Date().toISOString(),
    session_completed_at: input.session_completed_at,
    session_name: input.session_name,
  };

  await ddb.send(
    new PutCommand({
      TableName: tableName('workout_outbox'),
      Item: item,
      ConditionExpression: 'attribute_not_exists(outbox_id)',
    }),
  );

  const trimmedCount = await trimToRetention(input.user_id);

  return { item, dedupHit: false, trimmedCount };
}

async function findByClientSession(
  user_id: string,
  client_session_id: string,
): Promise<OutboxItem | null> {
  const result = await ddb.send(
    new QueryCommand({
      TableName: tableName('workout_outbox'),
      IndexName: 'client-session-index',
      KeyConditionExpression:
        'user_id = :uid AND client_session_id = :csid',
      ExpressionAttributeValues: {
        ':uid': user_id,
        ':csid': client_session_id,
      },
      Limit: 1,
    }),
  );
  const items = (result.Items as OutboxItem[] | undefined) ?? [];
  return items[0] ?? null;
}

/// Delete everything past position MAX_OUTBOX_ITEMS_PER_USER (oldest first).
/// Returns the count deleted. Best-effort: a write that fails mid-trim
/// leaves the user temporarily over-quota; the next push reaps it.
async function trimToRetention(user_id: string): Promise<number> {
  const result = await ddb.send(
    new QueryCommand({
      TableName: tableName('workout_outbox'),
      KeyConditionExpression: 'user_id = :uid',
      ExpressionAttributeValues: { ':uid': user_id },
      // Newest first; we drop the tail past MAX_OUTBOX_ITEMS_PER_USER.
      ScanIndexForward: false,
      // Only project the SK — full payload not needed for trim.
      ProjectionExpression: 'outbox_id',
    }),
  );
  const ids = ((result.Items as { outbox_id: string }[] | undefined) ?? []).map(
    (i) => i.outbox_id,
  );
  if (ids.length <= MAX_OUTBOX_ITEMS_PER_USER) return 0;

  const toDelete = ids.slice(MAX_OUTBOX_ITEMS_PER_USER);
  await Promise.all(
    toDelete.map((outbox_id) =>
      ddb.send(
        new DeleteCommand({
          TableName: tableName('workout_outbox'),
          Key: { user_id, outbox_id },
        }),
      ),
    ),
  );
  return toDelete.length;
}

export async function getOutboxItemsByUser(
  user_id: string,
  opts: ListOutboxOptions = {},
): Promise<OutboxItem[]> {
  const limit = Math.min(
    opts.limit ?? MAX_OUTBOX_ITEMS_PER_USER,
    MAX_OUTBOX_ITEMS_PER_USER,
  );

  const result = await ddb.send(
    new QueryCommand({
      TableName: tableName('workout_outbox'),
      KeyConditionExpression: 'user_id = :uid',
      ExpressionAttributeValues: { ':uid': user_id },
      ScanIndexForward: false,
      Limit: limit,
    }),
  );
  return (result.Items as OutboxItem[] | undefined) ?? [];
}

export async function getOutboxItem(
  user_id: string,
  outbox_id: string,
): Promise<OutboxItem | null> {
  const result = await ddb.send(
    new GetCommand({
      TableName: tableName('workout_outbox'),
      Key: { user_id, outbox_id },
    }),
  );
  return (result.Item as OutboxItem | undefined) ?? null;
}

export async function deleteOutboxItem(
  user_id: string,
  outbox_id: string,
): Promise<void> {
  await ddb.send(
    new DeleteCommand({
      TableName: tableName('workout_outbox'),
      Key: { user_id, outbox_id },
      ConditionExpression:
        'attribute_exists(user_id) AND attribute_exists(outbox_id)',
    }),
  );
}

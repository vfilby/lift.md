/**
 * Workout inbox repository.
 *
 * Pushed workouts land here and stay until the iOS app polls them and
 * ingests into CloudKit. CloudKit can't be written from a server, so
 * this table is the seam.
 *
 * Table layout (see src/infra/tables.ts):
 *   - PK: user_id, SK: inbox_id (ULID — lexicographic sort = chronological)
 *   - GSI 'status-index': PK=status, SK=created_at  (for the reaper job)
 */
import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand,
} from '@aws-sdk/lib-dynamodb';
import { createHash } from 'node:crypto';
import { ulid } from 'ulid';
import { ddb, tableName } from '../infra/ddb.js';

export type InboxStatus = 'pending' | 'ingested' | 'rejected';

export interface InboxItem {
  inbox_id: string;
  user_id: string;
  source_token_id: string;
  lmwf_text: string;
  status: InboxStatus;
  created_at: string;
  ingested_at?: string;
  /**
   * sha256 hex of the (trimmed) `lmwf_text`. Used for push-time dedup so a
   * double-fired or replayed push of byte-identical content collapses onto
   * the existing pending item instead of minting a duplicate (GH #193).
   * Optional on read so legacy rows written before this field existed still
   * decode — those simply never match a dedup probe.
   */
  content_hash?: string;
}

export interface CreateInboxItemInput {
  user_id: string;
  source_token_id: string;
  lmwf_text: string;
  status: InboxStatus;
}

/**
 * Stable dedup fingerprint for an inbox push: sha256 hex of the trimmed
 * `lmwf_text`. Trimming absorbs insignificant leading/trailing whitespace so
 * a re-push that differs only by a trailing newline still collapses. Two
 * genuinely different plans (e.g. an edited version with more sets) hash
 * differently and are kept as distinct items.
 */
export function inboxContentHash(lmwf_text: string): string {
  return createHash('sha256').update(lmwf_text.trim()).digest('hex');
}

export interface ListInboxOptions {
  status?: InboxStatus;
  sinceCursor?: string;
  limit?: number;
}

const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;

/**
 * Thrown when a pagination cursor is malformed, wrong-shape, or belongs to
 * a different user. Routes catch this and return a clean 400 instead of the
 * unhandled 500 a raw JSON.parse / DynamoDB ValidationException would yield.
 */
export class InvalidCursorError extends Error {
  constructor(message = 'Invalid pagination cursor') {
    super(message);
    this.name = 'InvalidCursorError';
  }
}

function encodeCursor(key: Record<string, unknown>): string {
  return Buffer.from(JSON.stringify(key), 'utf8').toString('base64');
}

/**
 * Decode a paging cursor back into a DynamoDB ExclusiveStartKey, validating
 * it before it is trusted. The cursor is attacker-controllable (a query
 * param), so we: (1) guard base64-decode + JSON.parse against malformed
 * input, (2) require the exact key shape we encode (`{user_id, inbox_id}`,
 * both strings), and (3) assert the embedded user_id matches the
 * authenticated caller. The DynamoDB key condition already pins reads to the
 * caller's partition, so (3) is defense-in-depth — but it also turns a forged
 * cross-tenant cursor into a clean 400 rather than a DynamoDB
 * ValidationException 500.
 */
function decodeCursor(
  cursor: string,
  expectedUserId: string,
): Record<string, unknown> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(cursor, 'base64').toString('utf8'));
  } catch {
    throw new InvalidCursorError();
  }
  if (
    typeof parsed !== 'object' ||
    parsed === null ||
    typeof (parsed as Record<string, unknown>).user_id !== 'string' ||
    typeof (parsed as Record<string, unknown>).inbox_id !== 'string'
  ) {
    throw new InvalidCursorError();
  }
  const key = parsed as { user_id: string; inbox_id: string };
  if (key.user_id !== expectedUserId) {
    throw new InvalidCursorError();
  }
  return { user_id: key.user_id, inbox_id: key.inbox_id };
}

export async function createInboxItem(
  input: CreateInboxItemInput,
): Promise<InboxItem> {
  const item: InboxItem = {
    ...input,
    inbox_id: ulid(),
    created_at: new Date().toISOString(),
    content_hash: inboxContentHash(input.lmwf_text),
  };

  await ddb.send(
    new PutCommand({
      TableName: tableName('workout_inbox'),
      Item: item,
      ConditionExpression: 'attribute_not_exists(inbox_id)',
    }),
  );

  return item;
}

/**
 * Find this user's most recent *pending* inbox item whose content matches the
 * given hash, or null. Backs push-time dedup (GH #193): a push that is
 * byte-identical (modulo whitespace) to an item the user hasn't yet acted on
 * returns the existing item rather than creating a duplicate. Scoped to
 * `pending` on purpose — once an item is ingested or discarded, a deliberate
 * re-push should produce a fresh item.
 *
 * Reads the caller's partition (newest-first) with a server-side filter on
 * status + content_hash. The inbox is small and self-draining, so this is a
 * bounded query; no GSI is required.
 */
export async function findPendingByContentHash(
  user_id: string,
  content_hash: string,
): Promise<InboxItem | null> {
  const result = await ddb.send(
    new QueryCommand({
      TableName: tableName('workout_inbox'),
      KeyConditionExpression: 'user_id = :uid',
      FilterExpression: '#st = :pending AND content_hash = :h',
      ExpressionAttributeNames: { '#st': 'status' },
      ExpressionAttributeValues: {
        ':uid': user_id,
        ':pending': 'pending',
        ':h': content_hash,
      },
      // Newest first — ULID SK is lexicographically chronological.
      ScanIndexForward: false,
    }),
  );
  const items = (result.Items as InboxItem[] | undefined) ?? [];
  return items[0] ?? null;
}

export async function getInboxItemsByUser(
  user_id: string,
  opts: ListInboxOptions = {},
): Promise<{ items: InboxItem[]; nextCursor?: string }> {
  const limit = Math.min(opts.limit ?? DEFAULT_LIMIT, MAX_LIMIT);

  const params: ConstructorParameters<typeof QueryCommand>[0] = {
    TableName: tableName('workout_inbox'),
    KeyConditionExpression: 'user_id = :uid',
    ExpressionAttributeValues: { ':uid': user_id },
    // Newest first — ULID is lexicographically chronological.
    ScanIndexForward: false,
    Limit: limit,
  };

  if (opts.status) {
    params.FilterExpression = '#st = :st';
    params.ExpressionAttributeNames = { '#st': 'status' };
    params.ExpressionAttributeValues = {
      ...params.ExpressionAttributeValues,
      ':st': opts.status,
    };
  }

  if (opts.sinceCursor) {
    params.ExclusiveStartKey = decodeCursor(opts.sinceCursor, user_id);
  }

  const result = await ddb.send(new QueryCommand(params));
  const items = (result.Items as InboxItem[] | undefined) ?? [];

  return {
    items,
    nextCursor: result.LastEvaluatedKey
      ? encodeCursor(result.LastEvaluatedKey)
      : undefined,
  };
}

export async function getInboxItem(
  user_id: string,
  inbox_id: string,
): Promise<InboxItem | null> {
  const result = await ddb.send(
    new GetCommand({
      TableName: tableName('workout_inbox'),
      Key: { user_id, inbox_id },
    }),
  );
  return (result.Item as InboxItem | undefined) ?? null;
}

export async function markIngested(
  user_id: string,
  inbox_id: string,
): Promise<void> {
  await ddb.send(
    new UpdateCommand({
      TableName: tableName('workout_inbox'),
      Key: { user_id, inbox_id },
      UpdateExpression: 'SET #st = :st, ingested_at = :now',
      ExpressionAttributeNames: { '#st': 'status' },
      ExpressionAttributeValues: {
        ':st': 'ingested',
        ':now': new Date().toISOString(),
      },
      ConditionExpression:
        'attribute_exists(user_id) AND attribute_exists(inbox_id)',
    }),
  );
}

export async function deleteInboxItem(
  user_id: string,
  inbox_id: string,
): Promise<void> {
  // Condition ensures the row exists AND belongs to this user — without it,
  // a missing row would silently succeed and a foreign row would silently
  // disappear. Caller maps ConditionalCheckFailedException to 404.
  await ddb.send(
    new DeleteCommand({
      TableName: tableName('workout_inbox'),
      Key: { user_id, inbox_id },
      ConditionExpression:
        'attribute_exists(user_id) AND attribute_exists(inbox_id)',
    }),
  );
}

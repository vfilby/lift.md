/**
 * AI plan-edit usage counters (`ai_usage` table).
 *
 * One row per (user_id, day) where `day` is the UTC calendar date. The
 * route reserves a slot BEFORE calling the model with an atomic conditional
 * increment, and releases it on terminal failure (422 / 502 / 504) so a
 * failed edit never costs the user a request. See
 * spec/services/ai-plan-editing.md → Quota.
 *
 * Table layout (see src/infra/tables.ts):
 *   - PK: user_id (S), SK: day (S, YYYY-MM-DD UTC)
 *   - count (N) — requests reserved today
 *   - ttl   (N) — epoch seconds, 7 days after `day`; DynamoDB reaps the row
 */
import { ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import { GetCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import { ddb, tableName } from '../infra/ddb.js';

export interface AIUsage {
  user_id: string;
  day: string;
  count: number;
  ttl: number;
}

/** Thrown by reserveAIRequest when `count` is already at the ceiling. */
export class QuotaExceededError extends Error {
  constructor(
    public readonly userId: string,
    public readonly day: string,
    public readonly ceiling: number,
  ) {
    super(`AI quota ceiling (${ceiling}) reached for ${userId} on ${day}`);
    this.name = 'QuotaExceededError';
  }
}

const MS_PER_DAY = 24 * 60 * 60 * 1000;
const TTL_DAYS = 7;

/** UTC calendar date (YYYY-MM-DD) for `now`. */
export function utcDay(now: Date = new Date()): string {
  return now.toISOString().slice(0, 10);
}

/** Start of the next UTC day after `now` — when the quota resets. */
export function nextUtcMidnight(now: Date = new Date()): Date {
  const start = Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate(),
  );
  return new Date(start + MS_PER_DAY);
}

/** Epoch seconds 7 days after the start of `day` (YYYY-MM-DD UTC). */
export function ttlForDay(day: string): number {
  const start = Date.parse(`${day}T00:00:00Z`);
  if (Number.isNaN(start)) {
    throw new Error(`ttlForDay: invalid day "${day}"`);
  }
  return Math.floor((start + TTL_DAYS * MS_PER_DAY) / 1000);
}

/**
 * Atomically reserve one request: `ADD count 1` guarded by
 * `attribute_not_exists(count) OR count < :ceiling`. Returns the new count.
 * Throws QuotaExceededError when the condition fails (count >= ceiling).
 *
 * `ttl` is set only on first write (`if_not_exists`) so the reap time is
 * stable for the row's lifetime.
 */
export async function reserveAIRequest(
  userId: string,
  day: string,
  ceiling: number,
): Promise<number> {
  try {
    const result = await ddb.send(
      new UpdateCommand({
        TableName: tableName('ai_usage'),
        Key: { user_id: userId, day },
        UpdateExpression: 'ADD #count :one SET #ttl = if_not_exists(#ttl, :ttl)',
        ConditionExpression:
          'attribute_not_exists(#count) OR #count < :ceiling',
        // `count` and `ttl` are DynamoDB reserved words.
        ExpressionAttributeNames: { '#count': 'count', '#ttl': 'ttl' },
        ExpressionAttributeValues: {
          ':one': 1,
          ':ceiling': ceiling,
          ':ttl': ttlForDay(day),
        },
        ReturnValues: 'ALL_NEW',
      }),
    );
    const count = (result.Attributes as AIUsage | undefined)?.count;
    if (typeof count !== 'number') {
      throw new Error('reserveAIRequest: UpdateItem returned no count');
    }
    return count;
  } catch (err) {
    if (err instanceof ConditionalCheckFailedException) {
      throw new QuotaExceededError(userId, day, ceiling);
    }
    throw err;
  }
}

/**
 * Give back one reserved request (`ADD count -1`, never below zero). Best
 * effort: any failure is logged and swallowed — a stuck counter costs the
 * user at most one request today, which is preferable to surfacing a
 * bookkeeping error on top of the model failure the caller is handling.
 */
export async function releaseAIRequest(
  userId: string,
  day: string,
): Promise<void> {
  try {
    await ddb.send(
      new UpdateCommand({
        TableName: tableName('ai_usage'),
        Key: { user_id: userId, day },
        UpdateExpression: 'ADD #count :minusOne',
        ConditionExpression: '#count > :zero',
        ExpressionAttributeNames: { '#count': 'count' },
        ExpressionAttributeValues: { ':minusOne': -1, ':zero': 0 },
      }),
    );
  } catch (err) {
    console.warn(
      JSON.stringify({
        level: 'warn',
        event: 'ai_usage_release_failed',
        user_id: userId,
        day,
        error: err instanceof Error ? err.message : String(err),
      }),
    );
  }
}

export async function getAIUsage(
  userId: string,
  day: string,
): Promise<AIUsage | null> {
  const result = await ddb.send(
    new GetCommand({
      TableName: tableName('ai_usage'),
      Key: { user_id: userId, day },
    }),
  );
  return (result.Item as AIUsage | undefined) ?? null;
}

/**
 * Personal access token (PAT) repository.
 *
 * Plaintext token format: `lm_pat_<mode>_<32 url-safe-base64 chars>`
 *   - mode is 'live' or 'test' (defaults to 'live')
 *   - the 32-char random tail is derived from 24 random bytes
 *
 * Only the SHA-256 hash is persisted; the plaintext is returned exactly
 * once from createToken and the caller is responsible for showing it to
 * the user and then discarding it.
 *
 * Table layout (see src/infra/tables.ts):
 *   - PK: token_hash  (single-GetItem lookup for auth middleware)
 *   - GSI 'user_id-index': PK=user_id, SK=created_at  (settings UI list)
 *
 * Revocation note: the UI surfaces tokens by their public `token_id`,
 * but the table PK is `token_hash`. revokeToken takes (user_id, token_id)
 * so we can find the row via the user_id-index without a full scan; the
 * UpdateItem then targets the actual PK.
 */
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import {
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand,
} from '@aws-sdk/lib-dynamodb';
import { ddb, tableName } from '../infra/ddb.js';

export type TokenMode = 'live' | 'test';

export interface PatToken {
  token_id: string;
  user_id: string;
  token_hash: string;
  prefix: string;
  name: string;
  scopes: string[];
  created_at: string;
  last_used_at?: string;
  last_used_ip?: string;
  expires_at?: string;
  revoked_at?: string;
}

export interface CreateTokenInput {
  user_id: string;
  name: string;
  scopes: string[];
  expires_at?: string;
  mode?: TokenMode;
}

/**
 * Generate a url-safe-base64 random string of the requested character
 * length (no padding, [A-Za-z0-9_-] only).
 */
function urlSafeRandom(chars: number): string {
  // 4 base64 chars per 3 bytes — round up.
  const bytes = Math.ceil((chars * 3) / 4);
  return randomBytes(bytes)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '')
    .slice(0, chars);
}

export function hashToken(plaintext: string): string {
  return createHash('sha256').update(plaintext).digest('hex');
}

export async function createToken(
  input: CreateTokenInput,
): Promise<{ token: PatToken; plaintext: string }> {
  const mode: TokenMode = input.mode ?? 'live';
  const randomPart = urlSafeRandom(32);
  const plaintext = `lm_pat_${mode}_${randomPart}`;

  const token: PatToken = {
    token_id: randomUUID(),
    user_id: input.user_id,
    token_hash: hashToken(plaintext),
    prefix: randomPart.slice(0, 8),
    name: input.name,
    scopes: input.scopes,
    created_at: new Date().toISOString(),
    expires_at: input.expires_at,
  };

  await ddb.send(
    new PutCommand({
      TableName: tableName('pat_tokens'),
      Item: token,
      ConditionExpression: 'attribute_not_exists(token_hash)',
    }),
  );

  return { token, plaintext };
}

export async function getTokenByHash(
  token_hash: string,
): Promise<PatToken | null> {
  const result = await ddb.send(
    new GetCommand({
      TableName: tableName('pat_tokens'),
      Key: { token_hash },
    }),
  );
  return (result.Item as PatToken | undefined) ?? null;
}

export async function listTokensByUserId(
  user_id: string,
): Promise<PatToken[]> {
  const result = await ddb.send(
    new QueryCommand({
      TableName: tableName('pat_tokens'),
      IndexName: 'user_id-index',
      KeyConditionExpression: 'user_id = :uid',
      ExpressionAttributeValues: { ':uid': user_id },
      // Sort descending by created_at — newest first.
      ScanIndexForward: false,
    }),
  );
  return (result.Items as PatToken[] | undefined) ?? [];
}

/**
 * Revoke a token by its public token_id, scoped to a user_id.
 *
 * Implementation: query the user_id-index for all the user's tokens,
 * find the row with the matching token_id (this is small — users have
 * a handful of PATs, not thousands), then UpdateItem by token_hash.
 *
 * Returns silently if no matching token is found — callers wanting a
 * 404 should check first with listTokensByUserId.
 */
export async function revokeToken(
  user_id: string,
  token_id: string,
): Promise<void> {
  const tokens = await listTokensByUserId(user_id);
  const match = tokens.find((t) => t.token_id === token_id);
  if (!match) return;
  await revokeTokenByHash(match.token_hash);
}

/** Internal-use revoke when the caller already has the token_hash. */
export async function revokeTokenByHash(token_hash: string): Promise<void> {
  await ddb.send(
    new UpdateCommand({
      TableName: tableName('pat_tokens'),
      Key: { token_hash },
      UpdateExpression: 'SET revoked_at = :now',
      ExpressionAttributeValues: { ':now': new Date().toISOString() },
      ConditionExpression: 'attribute_exists(token_hash)',
    }),
  );
}

/**
 * Stamp last-used metadata on a token. Auth middleware calls this in
 * fire-and-forget mode (without awaiting) so token lookup latency on
 * the hot path is unaffected.
 */
export async function markUsed(
  token_hash: string,
  ip: string,
): Promise<void> {
  await ddb.send(
    new UpdateCommand({
      TableName: tableName('pat_tokens'),
      Key: { token_hash },
      UpdateExpression: 'SET last_used_at = :now, last_used_ip = :ip',
      ExpressionAttributeValues: {
        ':now': new Date().toISOString(),
        ':ip': ip,
      },
    }),
  );
}

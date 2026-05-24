/**
 * Refresh token repository.
 *
 * Refresh tokens are opaque random strings — NOT JWTs. They carry no
 * claims; the row in DDB is the sole source of truth. This keeps the
 * server able to revoke them instantly without waiting for a JWT to
 * expire on its own.
 *
 * Plaintext format: `lm_refresh_<32 url-safe-base64 chars>` (24 bytes
 * of crypto.randomBytes, base64url-encoded, sliced to 32 chars).
 *
 * Only sha256(plaintext) hex is persisted. We never store, log, or
 * return the plaintext after the single createRefreshToken call.
 *
 * ── Rotation + reuse-detection model ──
 *
 * Every successful /v1/auth/refresh call:
 *   - issues a NEW refresh token (new hash, new row)
 *   - marks the OLD row with revoked_at=now AND replaced_by=<new hash>
 *
 * A token whose row has BOTH revoked_at and replaced_by set has already
 * been rotated. If that same plaintext is presented again it can only
 * mean an attacker captured the token before the legitimate client
 * rotated it (or the legitimate client is replaying — same blast
 * radius). The mitigation is identical: revoke the entire family.
 *
 * To support "revoke the entire family" without scan-the-world walks,
 * every row carries `family_root_hash` — the token_hash of the original
 * login-issued row. On rotation the new row inherits the parent's
 * family_root_hash. On reuse detection we Query the family-index GSI
 * and revoke every member at once. (The original ancestor IS a member
 * — family_root_hash on the root row equals its own token_hash.)
 *
 * ── Absolute expiry, not sliding ──
 *
 * The new refresh token issued on rotation inherits `expires_at` from
 * its parent (which in turn inherited from its parent ... back to the
 * family root, which was set to issued_at + 1 year at login). The
 * entire chain therefore dies on the same wall-clock date as the
 * original login, NOT 1 year from the most recent refresh. This is
 * the load-bearing security property: a stolen token grants at most
 * until the original family expiry, not perpetual access.
 *
 * ── Constant-time comparison ──
 *
 * Lookup is a DDB GetItem keyed on the sha256 hex hash. DDB does the
 * comparison server-side as a single equality match on the partition
 * key, so no plaintext is ever compared client-side and timingSafeEqual
 * is moot for the lookup path. If a future change ever performs a
 * client-side hash comparison (e.g. Query + filter), use
 * `crypto.timingSafeEqual` on equal-length Buffers — the byte-by-byte
 * shortcut in `===` is a textbook timing oracle.
 */
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import {
  GetCommand,
  PutCommand,
  QueryCommand,
  TransactWriteCommand,
  UpdateCommand,
} from '@aws-sdk/lib-dynamodb';
import { ddb, tableName } from '../infra/ddb.js';

/**
 * Thrown by `rotateRefreshToken` when the atomic write fails because the
 * old row was already revoked between read and write. The handler maps
 * this to a 401 — a concurrent rotation already won the race.
 */
export class RotationConflictError extends Error {
  constructor(message = 'Refresh token already rotated') {
    super(message);
    this.name = 'RotationConflictError';
  }
}

export interface RefreshToken {
  token_hash: string;
  user_id: string;
  identity_id: string;
  /** Hash of the family-root row. Equals token_hash for the root itself. */
  family_root_hash: string;
  issued_at: string;
  /** Inherited from the family root — does not slide on rotation. */
  expires_at: string;
  last_used_at?: string;
  revoked_at?: string;
  /** Hash of the rotation successor; presence + revoked_at signals reuse. */
  replaced_by?: string;
  /** Optional caller-supplied label, e.g. 'iOS app' or 'Web (Chrome)'. */
  device_label?: string;
}

export interface CreateRefreshTokenInput {
  user_id: string;
  identity_id: string;
  device_label?: string;
  /**
   * Rotation parent's family root hash. Omit for a brand-new login —
   * the new row will start a fresh family rooted at itself.
   */
  familyRootHash?: string;
  /**
   * Rotation parent's expires_at. Omit for a brand-new login — defaults
   * to now + 1 year. When rotating, callers MUST pass through the
   * parent's expires_at so the absolute-expiry property holds.
   */
  expires_at?: string;
}

const REFRESH_LIFETIME_MS = 365 * 24 * 60 * 60 * 1000; // 1 year

/**
 * SHA-256 hex of a refresh-token plaintext. Used both at write time and
 * at lookup time so the same function defines "what gets stored".
 */
export function hashRefreshToken(plaintext: string): string {
  return createHash('sha256').update(plaintext).digest('hex');
}

/**
 * Generate a URL-safe base64 random string of the requested character
 * length. Mirrors the helper in pat_tokens.ts intentionally — refresh
 * tokens and PATs both want opaque, no-padding, [A-Za-z0-9_-] strings.
 */
function urlSafeRandom(chars: number): string {
  const bytes = Math.ceil((chars * 3) / 4);
  return randomBytes(bytes)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '')
    .slice(0, chars);
}

/**
 * Constant-time comparison of two refresh-token hashes. NOT used on the
 * GetItem-by-hash lookup path (DDB compares server-side), but exposed
 * for future code that does Query+filter and needs to avoid a timing
 * oracle on the hash field.
 */
export function hashesEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  return timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'));
}

export async function createRefreshToken(
  input: CreateRefreshTokenInput,
): Promise<{ token: RefreshToken; plaintext: string }> {
  const randomPart = urlSafeRandom(32);
  const plaintext = `lm_refresh_${randomPart}`;
  const token_hash = hashRefreshToken(plaintext);
  const now = new Date();

  const expires_at =
    input.expires_at ??
    new Date(now.getTime() + REFRESH_LIFETIME_MS).toISOString();

  // Family root: a new login starts a fresh family rooted at itself;
  // a rotation inherits the parent's root.
  const family_root_hash = input.familyRootHash ?? token_hash;

  const token: RefreshToken = {
    token_hash,
    user_id: input.user_id,
    identity_id: input.identity_id,
    family_root_hash,
    issued_at: now.toISOString(),
    expires_at,
    device_label: input.device_label,
  };

  await ddb.send(
    new PutCommand({
      TableName: tableName('refresh_tokens'),
      Item: token,
      // Defence in depth — a hash collision on 256 bits would be
      // newsworthy, but if it ever happened we'd rather fail than
      // silently overwrite an existing token.
      ConditionExpression: 'attribute_not_exists(token_hash)',
    }),
  );

  return { token, plaintext };
}

/**
 * Atomic rotation: in a single DynamoDB transaction, insert the new
 * refresh-token row AND mark the old row revoked + replaced_by = new
 * hash. Either both writes land or neither does.
 *
 * Without this, two concurrent legitimate refresh attempts presenting
 * the same old plaintext could both pass the "not revoked" check, both
 * insert distinct new rows, and both succeed in marking the old one
 * revoked. The family would then contain two valid children — and the
 * one that isn't re-presented next would later look like reuse and
 * cascade-revoke the entire family.
 *
 * The Put uses `attribute_not_exists(token_hash)` for defence-in-depth
 * collision detection (mirrors plain createRefreshToken). The Update
 * uses `attribute_not_exists(revoked_at)` so a second concurrent call
 * with the same `oldHash` fails the conditional check, the transaction
 * is cancelled, and crucially the Put is rolled back — no orphan row.
 *
 * On conditional-check failure we throw `RotationConflictError`.
 * Callers map this to 401.
 */
export async function rotateRefreshToken(
  oldHash: string,
  input: CreateRefreshTokenInput,
): Promise<{ token: RefreshToken; plaintext: string }> {
  const randomPart = urlSafeRandom(32);
  const plaintext = `lm_refresh_${randomPart}`;
  const token_hash = hashRefreshToken(plaintext);
  const now = new Date();

  const expires_at =
    input.expires_at ??
    new Date(now.getTime() + REFRESH_LIFETIME_MS).toISOString();
  const family_root_hash = input.familyRootHash ?? token_hash;

  const newRow: RefreshToken = {
    token_hash,
    user_id: input.user_id,
    identity_id: input.identity_id,
    family_root_hash,
    issued_at: now.toISOString(),
    expires_at,
    device_label: input.device_label,
  };

  const nowIso = now.toISOString();

  try {
    await ddb.send(
      new TransactWriteCommand({
        TransactItems: [
          {
            Put: {
              TableName: tableName('refresh_tokens'),
              Item: newRow,
              ConditionExpression: 'attribute_not_exists(token_hash)',
            },
          },
          {
            Update: {
              TableName: tableName('refresh_tokens'),
              Key: { token_hash: oldHash },
              UpdateExpression: 'SET revoked_at = :now, replaced_by = :rb',
              ExpressionAttributeValues: {
                ':now': nowIso,
                ':rb': token_hash,
              },
              // The whole transaction depends on the old row still being
              // un-revoked. A concurrent rotation that already won the
              // race will have set revoked_at, and this fails the check
              // → the transaction cancels → the Put above is rolled back.
              ConditionExpression:
                'attribute_exists(token_hash) AND attribute_not_exists(revoked_at)',
            },
          },
        ],
      }),
    );
  } catch (err) {
    // The AWS SDK throws TransactionCanceledException with a
    // CancellationReasons array; the entry corresponding to the failed
    // condition has Code === 'ConditionalCheckFailed'. We treat any
    // such cancellation as the rotation-race signal — at this point
    // the Put has not landed (transactions are atomic).
    const e = err as {
      name?: string;
      CancellationReasons?: { Code?: string }[];
    };
    if (
      e.name === 'TransactionCanceledException' &&
      Array.isArray(e.CancellationReasons) &&
      e.CancellationReasons.some((r) => r?.Code === 'ConditionalCheckFailed')
    ) {
      throw new RotationConflictError();
    }
    throw err;
  }

  return { token: newRow, plaintext };
}

export async function getRefreshTokenByHash(
  token_hash: string,
): Promise<RefreshToken | null> {
  const result = await ddb.send(
    new GetCommand({
      TableName: tableName('refresh_tokens'),
      Key: { token_hash },
    }),
  );
  return (result.Item as RefreshToken | undefined) ?? null;
}

/**
 * Revoke a single refresh token. `replaced_by` is set when the
 * revocation is part of a rotation (so reuse detection can fire if the
 * old plaintext is presented again). It is left unset on plain
 * revocations (logout, logout-all, identity-cascade).
 */
export async function revokeRefreshToken(
  token_hash: string,
  opts: { replaced_by?: string } = {},
): Promise<void> {
  const now = new Date().toISOString();
  if (opts.replaced_by) {
    await ddb.send(
      new UpdateCommand({
        TableName: tableName('refresh_tokens'),
        Key: { token_hash },
        UpdateExpression: 'SET revoked_at = :now, replaced_by = :rb',
        ExpressionAttributeValues: { ':now': now, ':rb': opts.replaced_by },
        ConditionExpression: 'attribute_exists(token_hash)',
      }),
    );
  } else {
    await ddb.send(
      new UpdateCommand({
        TableName: tableName('refresh_tokens'),
        Key: { token_hash },
        UpdateExpression: 'SET revoked_at = :now',
        ExpressionAttributeValues: { ':now': now },
        ConditionExpression: 'attribute_exists(token_hash)',
      }),
    );
  }
}

/**
 * Revoke every member of a family — used on reuse detection. Returns
 * the number of newly-revoked rows (already-revoked rows are skipped to
 * avoid trampling the original revocation timestamp / replaced_by
 * pointer that the rotation chain set).
 */
export async function revokeFamilyByRoot(
  family_root_hash: string,
): Promise<number> {
  const revokeRow = async (token_hash: string): Promise<boolean> => {
    try {
      await ddb.send(
        new UpdateCommand({
          TableName: tableName('refresh_tokens'),
          Key: { token_hash },
          UpdateExpression: 'SET revoked_at = :now',
          ExpressionAttributeValues: { ':now': new Date().toISOString() },
          // Only revoke if still un-revoked — keeps the rotation chain's
          // replaced_by pointer intact on rows that were already rotated.
          ConditionExpression:
            'attribute_exists(token_hash) AND attribute_not_exists(revoked_at)',
        }),
      );
      return true;
    } catch (err) {
      const e = err as { name?: string };
      // A concurrent path beat us to the revocation — that's fine, the
      // row IS revoked, just not by us. Don't double-count.
      if (e.name === 'ConditionalCheckFailedException') return false;
      throw err;
    }
  };

  const queryFamily = async (): Promise<RefreshToken[]> => {
    const result = await ddb.send(
      new QueryCommand({
        TableName: tableName('refresh_tokens'),
        IndexName: 'family-index',
        KeyConditionExpression: 'family_root_hash = :root',
        ExpressionAttributeValues: { ':root': family_root_hash },
      }),
    );
    return (result.Items as RefreshToken[] | undefined) ?? [];
  };

  let revoked = 0;
  for (const item of await queryFamily()) {
    if (item.revoked_at) continue;
    if (await revokeRow(item.token_hash)) revoked += 1;
  }

  // Best-effort tightening: re-query once after the loop completes.
  // A legitimate rotation that landed AFTER the first Query but BEFORE
  // its parent was revoked would leave the new child un-revoked. The
  // re-query shrinks that window to milliseconds without adding latency
  // to every rotation. It does NOT fully close it — the only complete
  // fix is a killed-families set checked on rotation insert (i.e. add
  // an additional Put to the rotation transaction asserting the root
  // is not killed). Acceptable trade-off for v1.
  for (const item of await queryFamily()) {
    if (item.revoked_at) continue;
    if (await revokeRow(item.token_hash)) revoked += 1;
  }

  return revoked;
}

/**
 * List a user's refresh tokens that are still usable today. Used by
 * logout-all and the identity-deletion cascade. Returns the rows
 * themselves (not just hashes) so callers can log per-token metadata.
 */
export async function listActiveByUserId(
  user_id: string,
): Promise<RefreshToken[]> {
  const result = await ddb.send(
    new QueryCommand({
      TableName: tableName('refresh_tokens'),
      IndexName: 'user_id-index',
      KeyConditionExpression: 'user_id = :uid',
      ExpressionAttributeValues: { ':uid': user_id },
      ScanIndexForward: false,
    }),
  );
  const items = (result.Items as RefreshToken[] | undefined) ?? [];
  const now = Date.now();
  return items.filter(
    (t) => !t.revoked_at && new Date(t.expires_at).getTime() >= now,
  );
}

export async function revokeAllForUser(
  user_id: string,
  _reason: string,
): Promise<number> {
  // _reason is logged by callers, not stored on the row — we'd need a
  // separate audit table to retain per-revocation reasons.
  const active = await listActiveByUserId(user_id);
  let revoked = 0;
  for (const t of active) {
    await revokeRefreshToken(t.token_hash);
    revoked += 1;
  }
  return revoked;
}

export async function revokeAllForIdentity(
  user_id: string,
  identity_id: string,
  _reason: string,
): Promise<number> {
  // Identity-scoped cascade: only revoke rows bound to the removed
  // identity. Other identities under the same user keep their refresh
  // tokens — losing one sign-in method should not nuke the others.
  const active = await listActiveByUserId(user_id);
  let revoked = 0;
  for (const t of active) {
    if (t.identity_id !== identity_id) continue;
    await revokeRefreshToken(t.token_hash);
    revoked += 1;
  }
  return revoked;
}

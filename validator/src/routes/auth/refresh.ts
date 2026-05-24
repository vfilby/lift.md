/**
 * Refresh-token endpoints.
 *
 *   POST /v1/auth/refresh      — exchange a refresh token for a new
 *                                access JWT + a NEW refresh token
 *                                (rotation per use, family-cascade on
 *                                reuse detection)
 *   POST /v1/auth/logout       — revoke a single refresh token
 *                                (session-authenticated)
 *   POST /v1/auth/logout-all   — revoke every refresh token for the
 *                                authenticated user
 *
 * The refresh endpoint is the security-critical surface: see
 * src/repositories/refresh_tokens.ts for the rotation + reuse-detection
 * design notes. The handler here only sequences the repo calls; the
 * invariants (absolute expiry, family cascade, never-leak-old-token)
 * are enforced jointly by the repo and the handler.
 */
import { Hono } from 'hono';
import { signJwt } from '../../infra/jwt.js';
import { audit } from '../../infra/audit.js';
import {
  getRefreshTokenByHash,
  hashRefreshToken,
  revokeFamilyByRoot,
  revokeRefreshToken,
  revokeAllForUser,
  rotateRefreshToken,
  RotationConflictError,
} from '../../repositories/refresh_tokens.js';
import {
  sessionMiddleware,
  type SessionVariables,
} from '../../middleware/session.js';
import { requireFreshAuth } from '../../middleware/fresh.js';

interface RefreshBody {
  refresh_token?: unknown;
}

interface LogoutBody {
  refresh_token?: unknown;
}

const REFRESH_PREFIX = 'lm_refresh_';

export const refreshRouter = new Hono();

refreshRouter.post('/refresh', async (c) => {
  // Defence in depth: refresh tokens MUST NOT travel in query strings.
  // Query strings leak into access logs, browser history, Referer
  // headers, and HTTP proxies. We accept body only and explicitly
  // reject the URL form even if the body also has one.
  const queryToken = c.req.query('refresh_token');
  if (queryToken) {
    return c.json(
      { error: 'refresh_token must be in the request body, not the URL' },
      400,
    );
  }

  let body: RefreshBody;
  try {
    body = await c.req.json<RefreshBody>();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const plaintext = body.refresh_token;
  if (typeof plaintext !== 'string' || !plaintext.startsWith(REFRESH_PREFIX)) {
    return c.json({ error: 'Invalid refresh token' }, 401);
  }

  const presented_hash = hashRefreshToken(plaintext);
  const row = await getRefreshTokenByHash(presented_hash);
  if (!row) {
    audit(
      { event: 'refresh_token_lookup_miss', token_hash: presented_hash },
      'warn',
    );
    return c.json({ error: 'Invalid refresh token' }, 401);
  }

  // Reuse detection: a row with BOTH revoked_at AND replaced_by has
  // already been rotated. Presenting it again means either an attacker
  // captured the token or the legitimate client is replaying — same
  // blast radius. Nuke the whole family and surface a security event.
  if (row.revoked_at && row.replaced_by) {
    const cascaded = await revokeFamilyByRoot(row.family_root_hash);
    audit(
      {
        event: 'refresh_token_reuse_detected',
        user_id: row.user_id,
        identity_id: row.identity_id,
        token_hash: row.token_hash,
        family_root_hash: row.family_root_hash,
        family_members_revoked: cascaded,
      },
      'warn',
    );
    return c.json(
      { error: 'Refresh token reuse detected. Please sign in again.' },
      401,
    );
  }

  // Straight revocation (logout, logout-all, identity-cascade) — no
  // theft signal, just a dead token.
  if (row.revoked_at) {
    audit(
      {
        event: 'refresh_attempt_revoked',
        user_id: row.user_id,
        identity_id: row.identity_id,
        token_hash: row.token_hash,
      },
      'warn',
    );
    return c.json({ error: 'Refresh token revoked' }, 401);
  }

  if (new Date(row.expires_at).getTime() < Date.now()) {
    audit(
      {
        event: 'refresh_attempt_expired',
        user_id: row.user_id,
        identity_id: row.identity_id,
        token_hash: row.token_hash,
        family_root_hash: row.family_root_hash,
      },
      'warn',
    );
    return c.json({ error: 'Refresh token expired' }, 401);
  }

  // Rotation: mint a new refresh token in the same family, inheriting
  // the family's absolute expires_at so the chain dies on the original
  // wall-clock date (a stolen token cannot perpetually extend itself).
  //
  // The mint AND the old-row revocation happen in a single DDB
  // transaction. Two concurrent legitimate refresh attempts presenting
  // the same plaintext would otherwise both pass the not-revoked check,
  // both mint distinct new children, and both succeed in marking the
  // old row revoked — producing TWO valid children in the family and
  // setting up a guaranteed reuse-detection cascade later. With the
  // transaction, exactly one wins; the loser sees RotationConflictError
  // and we return 401 with a retry hint.
  let newRow;
  let new_refresh_token;
  try {
    ({ token: newRow, plaintext: new_refresh_token } = await rotateRefreshToken(
      row.token_hash,
      {
        user_id: row.user_id,
        identity_id: row.identity_id,
        familyRootHash: row.family_root_hash,
        expires_at: row.expires_at,
        device_label: row.device_label,
      },
    ));
  } catch (err) {
    if (err instanceof RotationConflictError) {
      audit(
        {
          event: 'rotation_conflict',
          user_id: row.user_id,
          identity_id: row.identity_id,
          token_hash: row.token_hash,
          family_root_hash: row.family_root_hash,
        },
        'warn',
      );
      return c.json(
        { error: 'Refresh token already rotated. Retry with the new token.' },
        401,
      );
    }
    throw err;
  }

  const access_jwt = signJwt(
    {
      sub: row.user_id,
      identity_id: row.identity_id,
      type: 'access',
      // Rotated, not fresh — caller proved possession of a refresh
      // token but did NOT re-prove a credential. Sensitive routes
      // (none yet) will require `authn_age === 'fresh'`.
      authn_age: 'rotated',
    },
    '1h',
  );

  audit({
    event: 'refresh_success',
    user_id: row.user_id,
    identity_id: row.identity_id,
    token_hash: newRow.token_hash,
    family_root_hash: row.family_root_hash,
    parent_token_hash: row.token_hash,
  });

  // Response intentionally omits the user object — caller can hit
  // a future /v1/me route if it needs to refresh user metadata.
  // The old refresh token is gone from server state at this point;
  // returning it here would defeat the purpose of rotation.
  return c.json({ access_jwt, refresh_token: new_refresh_token }, 200);
});

refreshRouter.post('/logout', sessionMiddleware, async (c) => {
  const ctx = c as typeof c & { var: SessionVariables };

  let body: LogoutBody;
  try {
    body = await c.req.json<LogoutBody>();
  } catch {
    // Malformed body — still succeed silently. Logout should be the
    // most forgiving endpoint; a confused client should still end up
    // logged out without leaking server-side state.
    return c.body(null, 204);
  }

  const plaintext = body.refresh_token;
  if (typeof plaintext !== 'string' || !plaintext.startsWith(REFRESH_PREFIX)) {
    return c.body(null, 204);
  }

  const hash = hashRefreshToken(plaintext);
  const row = await getRefreshTokenByHash(hash);
  // Belongs-to-current-user check: a session A must never be able to
  // revoke a refresh token belonging to session B. On mismatch we
  // 204 silently — no oracle about whether the token exists.
  if (!row || row.user_id !== ctx.var.session.user_id) {
    return c.body(null, 204);
  }
  if (!row.revoked_at) {
    await revokeRefreshToken(hash);
    audit({
      event: 'logout',
      user_id: row.user_id,
      identity_id: row.identity_id,
      token_hash: row.token_hash,
    });
  }
  return c.body(null, 204);
});

refreshRouter.post('/logout-all', sessionMiddleware, requireFreshAuth, async (c) => {
  const ctx = c as typeof c & { var: SessionVariables };
  const revoked = await revokeAllForUser(
    ctx.var.session.user_id,
    'logout_all',
  );
  audit({
    event: 'logout_all',
    user_id: ctx.var.session.user_id,
    identity_id: ctx.var.session.identity_id,
    tokens_revoked: revoked,
  });
  return c.body(null, 204);
});

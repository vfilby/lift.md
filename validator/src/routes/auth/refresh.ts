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
 *
 * ── httpOnly refresh-cookie contract (M2) ──
 *
 * The web client never touches the refresh token in JS; the browser stores
 * it as an httpOnly cookie set by the server. iOS keeps using the JSON
 * `refresh_token` bearer. Both channels carry the SAME token value.
 *
 *   - Cookie name/attrs: `lmwf_refresh=<token>; HttpOnly; Secure;
 *     SameSite=Strict; Path=/v1/auth; Max-Age=<remaining lifetime secs>`.
 *     SameSite=Strict is the CSRF mitigation on these mutating endpoints.
 *   - login (password.ts) and refresh SET the cookie (refresh rotates it,
 *     Max-Age tracks the inherited absolute expiry — rotation never extends
 *     it).
 *   - refresh accepts the token from the JSON body OR the cookie; if BOTH
 *     are present the body wins (keeps explicit iOS calls deterministic).
 *     An empty/absent body is valid when the cookie carries the token.
 *   - logout and logout-all CLEAR the cookie (Max-Age=0).
 */
import { Hono } from 'hono';
import { getCookie, setCookie, deleteCookie } from 'hono/cookie';
import { signJwt } from '../../infra/jwt.js';
import { audit } from '../../infra/audit.js';
import {
  getRefreshTokenByHash,
  hashRefreshToken,
  refreshLifetimeSeconds,
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
import { bumpTokensValidAfter } from '../../repositories/users.js';

interface RefreshBody {
  refresh_token?: unknown;
}

interface LogoutBody {
  refresh_token?: unknown;
}

const REFRESH_PREFIX = 'lm_refresh_';

// Idempotent-rotation grace window. When an already-rotated token is
// re-presented within this many ms of its rotation AND its successor is still
// the untouched live tip, we treat the call as a benign retry (lost response /
// concurrent double-spend / app killed mid-refresh during an OS update) and
// re-issue from the successor instead of nuking the whole family.
//
// Kept deliberately short (sub-minute): client hardening persists the new
// token synchronously, so a legitimate relaunch reads the NEW token and never
// re-presents the old one. This grace only catches the sub-minute
// lost-response / kill-during-refresh race; anything later is treated as
// genuine reuse (theft protection intact). Read per-request via an env
// override so tests can shrink the window to make the boundary deterministic.
function refreshGraceMs(): number {
  const raw = process.env.REFRESH_GRACE_MS;
  if (raw !== undefined) {
    const n = Number(raw);
    if (Number.isFinite(n) && n >= 0) return n;
  }
  return 60_000;
}

// httpOnly refresh cookie — mirrors the constants in password.ts. Scoped to
// /v1/auth, SameSite=Strict (CSRF mitigation on these mutating endpoints).
const REFRESH_COOKIE = 'lmwf_refresh';
const REFRESH_COOKIE_PATH = '/v1/auth';

/**
 * Expire the refresh cookie. deleteCookie emits Max-Age=0 with the same
 * attributes the browser needs to match the original (Path/Secure/SameSite),
 * so the stored cookie is dropped.
 */
function clearRefreshCookie(c: Parameters<typeof deleteCookie>[0]): void {
  deleteCookie(c, REFRESH_COOKIE, {
    httpOnly: true,
    secure: true,
    sameSite: 'Strict',
    path: REFRESH_COOKIE_PATH,
  });
}

/**
 * Mint the access JWT + set the rotated refresh cookie + return the 200
 * success body. Shared by the normal rotation path and the idempotent-rotation
 * grace path so both produce IDENTICAL responses (same signer/claims, same
 * cookie attributes). `newRow`/`newToken` are the freshly-rotated successor.
 */
function rotationSuccessResponse(
  c: Parameters<typeof setCookie>[0],
  newRow: { token_hash: string; expires_at: string },
  newToken: string,
  claims: { user_id: string; identity_id: string },
) {
  const access_jwt = signJwt(
    {
      sub: claims.user_id,
      identity_id: claims.identity_id,
      type: 'access',
      // Rotated, not fresh — caller proved possession of a refresh
      // token but did NOT re-prove a credential. Sensitive routes
      // (none yet) will require `authn_age === 'fresh'`.
      authn_age: 'rotated',
    },
    '1h',
  );

  // Rotate the httpOnly cookie too (M2). Max-Age tracks the inherited
  // absolute expiry so the cookie dies with the family — rotation never
  // extends it. iOS ignores the cookie and uses the JSON token below.
  setCookie(c, REFRESH_COOKIE, newToken, {
    httpOnly: true,
    secure: true,
    sameSite: 'Strict',
    path: REFRESH_COOKIE_PATH,
    maxAge: refreshLifetimeSeconds(newRow.expires_at),
  });

  return c.json({ access_jwt, refresh_token: newToken }, 200);
}

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

  // Body is optional now: a browser client may present the token via the
  // httpOnly cookie instead and send an empty/absent body. iOS keeps
  // sending it in the JSON body. A malformed-but-present body still 400s.
  let body: RefreshBody = {};
  const rawBody = await c.req.text();
  if (rawBody.length > 0) {
    try {
      body = JSON.parse(rawBody) as RefreshBody;
    } catch {
      return c.json({ error: 'Invalid JSON body' }, 400);
    }
  }

  // Accept the refresh token from EITHER the JSON body (iOS bearer flow,
  // back-compat) OR the lmwf_refresh cookie (browser flow). If both are
  // present the body wins, keeping explicit iOS calls deterministic.
  const bodyToken =
    typeof body.refresh_token === 'string' ? body.refresh_token : undefined;
  const cookieToken = getCookie(c, REFRESH_COOKIE);
  const plaintext = bodyToken ?? cookieToken;
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

  // A row with BOTH revoked_at AND replaced_by has already been rotated.
  // Re-presenting it is EITHER genuine token theft (an attacker replaying a
  // stale token) OR a benign retry (lost response / concurrent double-spend /
  // app killed mid-refresh). We distinguish the two with a bounded grace
  // window + a "successor is still the untouched live tip" check, so benign
  // retries get a fresh token instead of nuking the whole session.
  if (row.revoked_at && row.replaced_by) {
    const successor = await getRefreshTokenByHash(row.replaced_by);
    const withinGrace =
      Date.now() - Date.parse(row.revoked_at) <= refreshGraceMs();
    // Benign retry iff the successor exists, is still the live tip (the legit
    // client never used it: no replaced_by, no revoked_at), AND we're inside
    // the grace window of the rotation.
    const isBenignRetry =
      successor != null &&
      !successor.replaced_by &&
      !successor.revoked_at &&
      withinGrace;

    if (isBenignRetry) {
      // Re-issue by rotating the SUCCESSOR — mint a fresh pair exactly like
      // the normal success path. The just-rotated token the client already
      // holds is the successor; we advance the chain by one so the client
      // ends up with a brand-new live token.
      try {
        const { token: graceRow, plaintext: graceToken } =
          await rotateRefreshToken(successor.token_hash, {
            user_id: successor.user_id,
            identity_id: successor.identity_id,
            familyRootHash: successor.family_root_hash,
            expires_at: successor.expires_at,
            device_label: successor.device_label,
          });
        audit(
          {
            event: 'refresh_token_grace_reissue',
            user_id: row.user_id,
            identity_id: row.identity_id,
            token_hash: graceRow.token_hash,
            family_root_hash: row.family_root_hash,
            parent_token_hash: successor.token_hash,
            presented_token_hash: row.token_hash,
          },
          'warn',
        );
        return rotationSuccessResponse(c, graceRow, graceToken, {
          user_id: successor.user_id,
          identity_id: successor.identity_id,
        });
      } catch (err) {
        if (err instanceof RotationConflictError) {
          // A concurrent benign retry already advanced the successor — same
          // race the normal path hits. Tell the client to retry with the new
          // token; do NOT nuke the family.
          audit(
            {
              event: 'rotation_conflict',
              user_id: row.user_id,
              identity_id: row.identity_id,
              token_hash: successor.token_hash,
              family_root_hash: row.family_root_hash,
            },
            'warn',
          );
          return c.json(
            {
              error:
                'Refresh token already rotated. Retry with the new token.',
            },
            401,
          );
        }
        throw err;
      }
    }

    // Not a benign retry: successor missing / already advanced / revoked, or
    // outside the grace window. Treat as genuine reuse — nuke the whole
    // family and surface a security event.
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

  audit({
    event: 'refresh_success',
    user_id: row.user_id,
    identity_id: row.identity_id,
    token_hash: newRow.token_hash,
    family_root_hash: row.family_root_hash,
    parent_token_hash: row.token_hash,
  });

  // Response intentionally omits the user object — caller can hit the
  // /v1/me route if it needs to refresh user metadata. The old refresh
  // token is gone from server state at this point; returning it here would
  // defeat the purpose of rotation.
  return rotationSuccessResponse(c, newRow, new_refresh_token, {
    user_id: row.user_id,
    identity_id: row.identity_id,
  });
});

refreshRouter.post('/logout', sessionMiddleware, async (c) => {
  const ctx = c as typeof c & { var: SessionVariables };

  // Always clear the browser cookie, regardless of what happens below —
  // logout's contract is "this client ends up logged out". We clear it up
  // front so every early-return path also drops it.
  clearRefreshCookie(c);

  let body: LogoutBody = {};
  const rawBody = await c.req.text();
  if (rawBody.length > 0) {
    try {
      body = JSON.parse(rawBody) as LogoutBody;
    } catch {
      // Malformed body — still succeed silently. Logout should be the
      // most forgiving endpoint; a confused client should still end up
      // logged out without leaking server-side state.
      return c.body(null, 204);
    }
  }

  // Token from body (iOS) or cookie (browser); body wins if both present.
  const bodyToken =
    typeof body.refresh_token === 'string' ? body.refresh_token : undefined;
  const plaintext = bodyToken ?? getCookie(c, REFRESH_COOKIE);
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
  // requireFreshAuth gates this on a `fresh` access token (password
  // login), so a victim holding only a rotated token must re-login first.
  // That freshness dead-end is the intended L7 behavior: once H1 makes
  // password reset revoke all tokens, a recovering user re-logs in
  // (minting a fresh token) and logout-all is available again. No change
  // to the gate is needed — re-login restores it.
  const revoked = await revokeAllForUser(
    ctx.var.session.user_id,
    'logout_all',
  );
  // Bump the account access-token cutoff so the ≤1h access JWTs already in
  // flight on other devices are rejected at the next request — "log out
  // everywhere" should kill access tokens too, not just refresh tokens.
  await bumpTokensValidAfter(ctx.var.session.user_id);
  // Clear this browser's cookie too — its underlying token was just
  // revoked along with all the others.
  clearRefreshCookie(c);
  audit({
    event: 'logout_all',
    user_id: ctx.var.session.user_id,
    identity_id: ctx.var.session.identity_id,
    tokens_revoked: revoked,
  });
  return c.body(null, 204);
});

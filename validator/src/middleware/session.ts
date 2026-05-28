/**
 * Session JWT middleware.
 *
 * Pulls `Authorization: Bearer <jwt>` off the request, verifies it as
 * an access-typed token, loads the user, and attaches both to the Hono
 * context so route handlers can read `c.var.user` / `c.var.session`.
 *
 * On any failure (missing header, malformed token, expired, wrong type,
 * missing user) responds 401 with the same body — no enumeration about
 * why the auth failed.
 *
 * ── type='access' (NOT 'session') ──
 *
 * Earlier slices issued JWTs typed `'session'`. With the refresh-token
 * model, the short-lived (1h) bearer is now called an "access token"
 * and typed `'access'`; the refresh token is opaque and lives in DDB.
 * The middleware rejects `'session'` outright so legacy tokens cannot
 * piggy-back on the new auth shape.
 *
 * ── authn_age ──
 *
 * Access tokens carry an `authn_age` claim of either:
 *   - 'fresh'   — issued at password login (caller proved a credential)
 *   - 'rotated' — issued at refresh (caller only proved possession of a
 *                 previously-issued refresh token)
 *
 * The middleware does not gate on authn_age — that's the job of
 * sensitive-route middleware (not built yet because no sensitive routes
 * exist). We warn-log on missing values to surface old tokens minted
 * before this field was added.
 */
import { createMiddleware } from 'hono/factory';
import { verifyJwt, tokenIssuedBefore } from '../infra/jwt.js';
import { getUserById, type User } from '../repositories/users.js';

export type AuthnAge = 'fresh' | 'rotated';

export interface AccessPayload {
  sub: string;
  identity_id: string;
  type: 'access';
  authn_age?: AuthnAge;
  iat: number;
  exp: number;
}

/**
 * Legacy alias — earlier code called this SessionPayload. Kept so
 * importers don't need a touch-everything rename, but `type` now reads
 * 'access' rather than 'session'.
 */
export type SessionPayload = AccessPayload;

export interface SessionContext {
  user_id: string;
  identity_id: string;
  authn_age?: AuthnAge;
}

export type SessionVariables = {
  user: User;
  session: SessionContext;
};

const UNAUTHORIZED = { error: 'Unauthorized' } as const;

export const sessionMiddleware = createMiddleware<{
  Variables: SessionVariables;
}>(async (c, next) => {
  const header = c.req.header('authorization') ?? c.req.header('Authorization');
  if (!header || !header.toLowerCase().startsWith('bearer ')) {
    return c.json(UNAUTHORIZED, 401);
  }
  const token = header.slice(7).trim();
  if (!token) {
    return c.json(UNAUTHORIZED, 401);
  }

  let payload: AccessPayload;
  try {
    payload = verifyJwt<AccessPayload>(token);
  } catch {
    return c.json(UNAUTHORIZED, 401);
  }

  if (payload.type !== 'access' || !payload.sub || !payload.identity_id) {
    return c.json(UNAUTHORIZED, 401);
  }

  if (!payload.authn_age) {
    // Surface old tokens minted before the field was added. Not a
    // hard reject — those tokens are still cryptographically valid
    // until they expire (1h).
    console.warn(
      JSON.stringify({
        level: 'warn',
        event: 'access_token_missing_authn_age',
        user_id: payload.sub,
        identity_id: payload.identity_id,
      }),
    );
  }

  const user = await getUserById(payload.sub);
  if (!user) {
    return c.json(UNAUTHORIZED, 401);
  }

  // Reject access tokens minted before the account's token cutoff (bumped on
  // password reset / logout-all). Closes the ≤1h access-token tail of H1 with
  // no extra DDB read — `user` is already loaded above.
  if (tokenIssuedBefore(payload.iat, user.tokens_valid_after)) {
    return c.json(UNAUTHORIZED, 401);
  }

  c.set('user', user);
  c.set('session', {
    user_id: payload.sub,
    identity_id: payload.identity_id,
    authn_age: payload.authn_age,
  });

  await next();
});

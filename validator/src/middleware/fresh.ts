/**
 * requireFreshAuth — gate sensitive routes on a credential-proving
 * access token, not a refresh-rotated one.
 *
 * Access tokens carry `authn_age`:
 *   - 'fresh'   — issued at password (or other credential) login
 *   - 'rotated' — issued at /v1/auth/refresh (caller only proved
 *                 possession of a refresh token, NOT a credential)
 *
 * A stolen rotated access JWT is bad-enough by itself — but if it can
 * also call /v1/auth/logout-all, change-password, or delete-account,
 * the attacker can DOS the legitimate user with a single 1h token. We
 * gate those operations on a fresh authentication: the caller must
 * sign in again to prove they are the account holder.
 *
 * ── Usage ──
 *
 *   refreshRouter.post(
 *     '/logout-all',
 *     sessionMiddleware,    // MUST run first — sets c.var.session
 *     requireFreshAuth,
 *     handler,
 *   );
 *
 * This middleware ONLY reads `c.var.session.authn_age`; it assumes
 * sessionMiddleware (or anything that sets the same shape) has already
 * run. Mounting it without that upstream guard is a programming error
 * and will reject every request.
 *
 * Apply this to any new sensitive route: change-password, delete-account,
 * disable-2FA, rotate-recovery-codes, etc.
 */
import { createMiddleware } from 'hono/factory';
import type { SessionVariables } from './session.js';

const RE_AUTH_REQUIRED = {
  error: 'Re-authentication required for this operation. Sign in again.',
} as const;

export const requireFreshAuth = createMiddleware<{
  Variables: SessionVariables;
}>(async (c, next) => {
  const session = c.var.session;
  if (!session || session.authn_age !== 'fresh') {
    return c.json(RE_AUTH_REQUIRED, 401);
  }
  await next();
});

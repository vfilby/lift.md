/**
 * JWT signing + verification helpers.
 *
 * HS256 only — the same Lambda both issues and verifies tokens, so an
 * asymmetric algorithm would add ops cost without buying anything. The
 * shared secret comes from Secrets Manager (CDK wires it into the
 * Lambda env as JWT_SECRET).
 *
 * Throws on missing secret rather than silently issuing unverifiable
 * tokens — a misconfigured prod deploy should fail loud.
 */

import jwt, {
  type Secret,
  type SignOptions,
  type JwtPayload,
} from 'jsonwebtoken';

function getSecret(): Secret {
  const secret = process.env.JWT_SECRET;
  if (!secret) {
    throw new Error(
      'JWT_SECRET is not set — refusing to sign/verify tokens. ' +
        'In prod this is injected from Secrets Manager by CDK; ' +
        'for local dev export JWT_SECRET=<any-string> before starting the server.',
    );
  }
  return secret;
}

/**
 * Sign an arbitrary payload object. `expiresIn` accepts the same
 * vocabulary as jsonwebtoken: '1h', '7d', '30m', or a number of seconds.
 */
export function signJwt(
  payload: Record<string, unknown>,
  expiresIn: SignOptions['expiresIn'],
): string {
  const secret = getSecret();
  return jwt.sign(payload, secret, {
    algorithm: 'HS256',
    expiresIn,
  });
}

/**
 * Verify a token and return its payload cast to T. Throws on:
 *   - missing JWT_SECRET (configuration error)
 *   - invalid signature / malformed token (JsonWebTokenError)
 *   - expired token (TokenExpiredError)
 *
 * T is unchecked — callers should narrow further if they need runtime
 * validation of payload shape.
 */
export function verifyJwt<T = JwtPayload>(token: string): T {
  const secret = getSecret();
  const decoded = jwt.verify(token, secret, { algorithms: ['HS256'] });
  return decoded as T;
}

/**
 * Password-change staleness gate.
 *
 * Access tokens (1h) and reset tokens (1h) are stateless HS256 JWTs — the
 * server keeps no per-token row to revoke. A password change MUST still
 * invalidate every token minted before it, otherwise:
 *   - a stolen access JWT keeps working for up to an hour after the victim
 *     resets, and
 *   - a captured reset link is replayable for the full hour, even after the
 *     password has already been changed (i.e. the reset token is not
 *     single-use).
 *
 * Both holes close with one rule: reject any token whose `iat` predates the
 * identity's `password_updated_at`. The timestamp is stamped on every
 * signup/link/reset (see identities.updatePasswordHash), so the data already
 * exists — this is the read side.
 *
 * `iat` is in whole seconds (JWT convention); `password_updated_at` is an
 * ISO-8601 string with millisecond precision. To avoid a granularity
 * mismatch we floor BOTH to whole seconds and reject only when the token was
 * issued in a STRICTLY EARLIER second than the recorded password change
 * (`iatSec < changedSec`).
 *
 * This guarantees a token can never be falsely rejected on first use even
 * when issuance and a prior password stamp land in the same wall-clock
 * second (which happens constantly in fast tests, and harmlessly in prod).
 * After a reset stamps `password_updated_at = now`, a replay of the same
 * token — issued in an earlier second — is rejected. The durable
 * refresh-token hole is closed independently by revokeAllForUser on reset,
 * so the only residual is a sub-second reset-token replay window, which is
 * not meaningfully exploitable.
 *
 * Returns `true` when the token is stale (must be rejected). An identity with
 * no `password_updated_at` (legacy row) never invalidates tokens here.
 */
export function isTokenStaleForPassword(
  iatSeconds: number | undefined,
  passwordUpdatedAt: string | undefined,
): boolean {
  return tokenIssuedBefore(iatSeconds, passwordUpdatedAt);
}

/**
 * Generic counterpart of {@link isTokenStaleForPassword}: returns `true`
 * when a JWT's `iat` predates the given ISO-8601 cutoff (whole-second
 * granularity, strict `<`), and `false` when the cutoff is absent/unparseable
 * (legacy rows never invalidate).
 *
 * The middleware uses this with the account-scoped `users.tokens_valid_after`
 * cutoff to reject access tokens minted before a password reset / logout-all.
 * It is account-scoped (not identity-scoped like `password_updated_at`) on
 * purpose: a password reset is account recovery — it must also invalidate
 * access tokens that were minted via a *different* sign-in method, exactly as
 * `revokeAllForUser` already does for the refresh tokens.
 */
export function tokenIssuedBefore(
  iatSeconds: number | undefined,
  cutoffIso: string | undefined,
): boolean {
  if (!cutoffIso) return false;
  if (typeof iatSeconds !== 'number') return false;
  const cutoffMs = Date.parse(cutoffIso);
  if (Number.isNaN(cutoffMs)) return false;
  const cutoffSec = Math.floor(cutoffMs / 1000);
  return Math.floor(iatSeconds) < cutoffSec;
}

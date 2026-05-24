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

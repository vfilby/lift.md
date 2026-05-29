import { describe, it, expect, beforeAll, afterAll } from 'vitest';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';

describe('jwt helpers', () => {
  let originalSecret: string | undefined;

  beforeAll(() => {
    originalSecret = process.env.JWT_SECRET;
    process.env.JWT_SECRET = TEST_SECRET;
  });

  afterAll(() => {
    if (originalSecret === undefined) {
      delete process.env.JWT_SECRET;
    } else {
      process.env.JWT_SECRET = originalSecret;
    }
  });

  it('signs and verifies a payload (round-trip preserves fields)', async () => {
    const { signJwt, verifyJwt } = await import('../src/infra/jwt.js');
    const payload = { sub: 'user-123', role: 'member', count: 42 };
    const token = signJwt(payload, '1h');
    expect(token.split('.')).toHaveLength(3);

    const decoded = verifyJwt<typeof payload & { iat: number; exp: number }>(
      token,
    );
    expect(decoded.sub).toBe('user-123');
    expect(decoded.role).toBe('member');
    expect(decoded.count).toBe(42);
    expect(typeof decoded.iat).toBe('number');
    expect(typeof decoded.exp).toBe('number');
  });

  it('rejects an expired token', async () => {
    const { signJwt, verifyJwt } = await import('../src/infra/jwt.js');
    const token = signJwt({ sub: 'soon-expired' }, '1s');
    // Wait past the 1s expiry. jsonwebtoken's clock has 1s resolution,
    // so 1.1s isn't always enough on a busy CI box — bump to 2s.
    await new Promise((r) => setTimeout(r, 2000));
    expect(() => verifyJwt(token)).toThrowError(/jwt expired/i);
  }, 5000);

  it('rejects a tampered token', async () => {
    const { signJwt, verifyJwt } = await import('../src/infra/jwt.js');
    const token = signJwt({ sub: 'original' }, '1h');
    const [header, body, signature] = token.split('.');
    // Flip one character in the payload segment. base64url-safe chars
    // only; pick a char known to be in the alphabet either way.
    const tampered = body.startsWith('A')
      ? `B${body.slice(1)}`
      : `A${body.slice(1)}`;
    const badToken = `${header}.${tampered}.${signature}`;
    expect(() => verifyJwt(badToken)).toThrow();
  });

  it('isTokenStaleForPassword: rejects tokens issued before the password change', async () => {
    const { isTokenStaleForPassword } = await import('../src/infra/jwt.js');
    const changedAt = '2026-05-28T12:00:05.000Z';
    const changedSec = Math.floor(Date.parse(changedAt) / 1000);

    // Issued a full second before the change → stale.
    expect(isTokenStaleForPassword(changedSec - 1, changedAt)).toBe(true);
    // Issued in the same second → NOT stale (no false-reject on first use).
    expect(isTokenStaleForPassword(changedSec, changedAt)).toBe(false);
    // Issued after the change → fresh.
    expect(isTokenStaleForPassword(changedSec + 1, changedAt)).toBe(false);
  });

  it('isTokenStaleForPassword: never stale when no password timestamp or bad iat', async () => {
    const { isTokenStaleForPassword } = await import('../src/infra/jwt.js');
    expect(isTokenStaleForPassword(1_000_000, undefined)).toBe(false);
    expect(isTokenStaleForPassword(undefined, '2026-05-28T12:00:00Z')).toBe(
      false,
    );
    expect(isTokenStaleForPassword(1_000_000, 'not-a-date')).toBe(false);
  });

  it('tokenIssuedBefore: same whole-second semantics, generic cutoff', async () => {
    const { tokenIssuedBefore, isTokenStaleForPassword } = await import(
      '../src/infra/jwt.js'
    );
    const cutoff = '2026-05-28T12:00:05.000Z';
    const cutoffSec = Math.floor(Date.parse(cutoff) / 1000);
    expect(tokenIssuedBefore(cutoffSec - 1, cutoff)).toBe(true);
    expect(tokenIssuedBefore(cutoffSec, cutoff)).toBe(false);
    expect(tokenIssuedBefore(cutoffSec + 1, cutoff)).toBe(false);
    // Absent / unparseable cutoff and bad iat never invalidate (legacy rows).
    expect(tokenIssuedBefore(1_000_000, undefined)).toBe(false);
    expect(tokenIssuedBefore(undefined, cutoff)).toBe(false);
    expect(tokenIssuedBefore(1_000_000, 'not-a-date')).toBe(false);
    // isTokenStaleForPassword is the password-scoped alias of the same logic.
    expect(isTokenStaleForPassword(cutoffSec - 1, cutoff)).toBe(
      tokenIssuedBefore(cutoffSec - 1, cutoff),
    );
  });

  it('throws on signJwt when JWT_SECRET is unset', async () => {
    const saved = process.env.JWT_SECRET;
    delete process.env.JWT_SECRET;
    try {
      const { signJwt } = await import('../src/infra/jwt.js');
      expect(() => signJwt({ foo: 'bar' }, '1h')).toThrowError(/JWT_SECRET/);
    } finally {
      process.env.JWT_SECRET = saved;
    }
  });
});

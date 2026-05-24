import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { Hono } from 'hono';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';

// Needs DDB so sessionMiddleware can load the user row.
const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

liveDdb('requireFreshAuth middleware', () => {
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

  async function buildApp(): Promise<{
    app: Hono;
    createUser: typeof import('../../src/repositories/users.js').createUser;
    signJwt: typeof import('../../src/infra/jwt.js').signJwt;
  }> {
    const { sessionMiddleware } = await import(
      '../../src/middleware/session.js'
    );
    const { requireFreshAuth } = await import('../../src/middleware/fresh.js');
    const { createUser } = await import('../../src/repositories/users.js');
    const { signJwt } = await import('../../src/infra/jwt.js');

    const app = new Hono();
    app.get('/protected', sessionMiddleware, requireFreshAuth, (c) =>
      c.json({ ok: true }),
    );
    return { app, createUser, signJwt };
  }

  async function mintUser(label: string): Promise<string> {
    const { createUser } = await import('../../src/repositories/users.js');
    const u = await createUser({
      display_name: 'Fresh Test',
      primary_email: `${label}-${Date.now()}-${Math.random()}@example.com`,
    });
    return u.user_id;
  }

  it('accepts a valid access JWT with authn_age=fresh', async () => {
    const { app, signJwt } = await buildApp();
    const user_id = await mintUser('fresh-ok');
    const token = signJwt(
      { sub: user_id, identity_id: 'x', type: 'access', authn_age: 'fresh' },
      '1h',
    );
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });

  it('rejects a valid access JWT with authn_age=rotated with the re-auth message', async () => {
    const { app, signJwt } = await buildApp();
    const user_id = await mintUser('fresh-no');
    const token = signJwt(
      { sub: user_id, identity_id: 'x', type: 'access', authn_age: 'rotated' },
      '1h',
    );
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/re-authentication required/i);
  });

  it('rejects a valid access JWT missing authn_age altogether', async () => {
    // Old tokens minted before authn_age existed. We treat them as
    // not-fresh — defaulting permissive on an unknown claim would let
    // pre-fix tokens slip past the gate.
    const { app, signJwt } = await buildApp();
    const user_id = await mintUser('fresh-missing');
    const token = signJwt(
      { sub: user_id, identity_id: 'x', type: 'access' },
      '1h',
    );
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/re-authentication required/i);
  });

  it('rejects when sessionMiddleware was never mounted (defence in depth)', async () => {
    // Belt-and-braces: if someone forgets to chain sessionMiddleware
    // before requireFreshAuth, the gate must still close (not throw).
    const { requireFreshAuth } = await import('../../src/middleware/fresh.js');
    const app = new Hono();
    app.get('/no-session', requireFreshAuth, (c) => c.json({ ok: true }));
    const res = await app.request('/no-session');
    expect(res.status).toBe(401);
  });
});

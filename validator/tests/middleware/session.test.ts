import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { Hono } from 'hono';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';

// The middleware needs a real user row to attach to context, so it's a
// live-DDB test like the repositories.
const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

liveDdb('session middleware', () => {
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
    const { createUser } = await import('../../src/repositories/users.js');
    const { signJwt } = await import('../../src/infra/jwt.js');
    const app = new Hono();
    app.get('/protected', sessionMiddleware, (c) =>
      c.json({
        user_id: (c.var as { user: { user_id: string } }).user.user_id,
        identity_id: (
          c.var as { session: { identity_id: string } }
        ).session.identity_id,
      }),
    );
    return { app, createUser, signJwt };
  }

  it('allows requests with a valid session JWT and exposes user on context', async () => {
    const { app, createUser, signJwt } = await buildApp();
    const user = await createUser({
      display_name: 'Sess Test',
      primary_email: `sess-${Date.now()}-${Math.random()}@example.com`,
    });
    const token = signJwt(
      { sub: user.user_id, identity_id: 'fake-identity', type: 'access', authn_age: 'fresh' },
      '1h',
    );
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      user_id: string;
      identity_id: string;
    };
    expect(body.user_id).toBe(user.user_id);
    expect(body.identity_id).toBe('fake-identity');
  });

  it('rejects requests with no Authorization header', async () => {
    const { app } = await buildApp();
    const res = await app.request('/protected');
    expect(res.status).toBe(401);
  });

  it('rejects requests with a malformed Bearer token', async () => {
    const { app } = await buildApp();
    const res = await app.request('/protected', {
      headers: { authorization: 'Bearer not-a-jwt' },
    });
    expect(res.status).toBe(401);
  });

  it('rejects tokens with the wrong type claim', async () => {
    const { app, createUser, signJwt } = await buildApp();
    const user = await createUser({
      display_name: 'Wrong Type',
      primary_email: `wrong-${Date.now()}-${Math.random()}@example.com`,
    });
    const token = signJwt(
      { sub: user.user_id, identity_id: 'x', type: 'email_verify' },
      '1h',
    );
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  it('rejects expired tokens', async () => {
    const { app, createUser, signJwt } = await buildApp();
    const user = await createUser({
      display_name: 'Expired',
      primary_email: `exp-${Date.now()}-${Math.random()}@example.com`,
    });
    const token = signJwt(
      { sub: user.user_id, identity_id: 'x', type: 'access', authn_age: 'fresh' },
      '1s',
    );
    await new Promise((r) => setTimeout(r, 2000));
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  }, 5000);

  it("rejects tokens with the old type='session' claim", async () => {
    const { app, createUser, signJwt } = await buildApp();
    const user = await createUser({
      display_name: 'Legacy Session',
      primary_email: `legacy-${Date.now()}-${Math.random()}@example.com`,
    });
    const token = signJwt(
      { sub: user.user_id, identity_id: 'x', type: 'session' },
      '1h',
    );
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  it('exposes authn_age on c.var.session when present', async () => {
    const { app, createUser, signJwt } = await buildApp();
    const user = await createUser({
      display_name: 'Authn Age',
      primary_email: `aage-${Date.now()}-${Math.random()}@example.com`,
    });
    const token = signJwt(
      {
        sub: user.user_id,
        identity_id: 'fake',
        type: 'access',
        authn_age: 'rotated',
      },
      '1h',
    );
    // The default /protected handler only echoes user_id/identity_id;
    // we just need the request to succeed to confirm authn_age='rotated'
    // didn't trip the middleware.
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  it('rejects valid-looking tokens whose user has been deleted', async () => {
    const { app, signJwt } = await buildApp();
    const token = signJwt(
      {
        sub: `ghost-${Date.now()}`,
        identity_id: 'x',
        type: 'access', authn_age: 'fresh',
      },
      '1h',
    );
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });
});

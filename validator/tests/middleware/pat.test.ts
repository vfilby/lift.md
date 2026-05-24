import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { Hono } from 'hono';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';

const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

liveDdb('PAT auth middleware', () => {
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
    updateUserTier: typeof import('../../src/repositories/users.js').updateUserTier;
    createToken: typeof import('../../src/repositories/pat_tokens.js').createToken;
    revokeTokenByHash: typeof import('../../src/repositories/pat_tokens.js').revokeTokenByHash;
    hashToken: typeof import('../../src/repositories/pat_tokens.js').hashToken;
    getTokenByHash: typeof import('../../src/repositories/pat_tokens.js').getTokenByHash;
  }> {
    const { patAuth, requireScope } = await import('../../src/middleware/pat.js');
    const repo = await import('../../src/repositories/pat_tokens.js');
    const users = await import('../../src/repositories/users.js');
    const app = new Hono();
    app.get('/protected', patAuth, (c) => {
      const ctx = c as typeof c & {
        var: {
          user: { user_id: string };
          token: { token_id: string };
          pat_token_id: string;
        };
      };
      return c.json({
        user_id: ctx.var.user.user_id,
        token_id: ctx.var.token.token_id,
        pat_token_id: ctx.var.pat_token_id,
      });
    });
    app.get('/scoped', requireScope('workouts:write'), (c) => {
      const ctx = c as typeof c & { var: { user: { user_id: string } } };
      return c.json({ user_id: ctx.var.user.user_id });
    });
    return {
      app,
      createUser: users.createUser,
      updateUserTier: users.updateUserTier,
      createToken: repo.createToken,
      revokeTokenByHash: repo.revokeTokenByHash,
      hashToken: repo.hashToken,
      getTokenByHash: repo.getTokenByHash,
    };
  }

  it('allows a valid PAT and exposes user/token on context', async () => {
    const { app, createUser, createToken } = await buildApp();
    const user = await createUser({
      display_name: 'PAT User',
      primary_email: `pat-${Date.now()}-${Math.random()}@example.com`,
    });
    const { token, plaintext } = await createToken({
      user_id: user.user_id,
      name: 't',
      scopes: ['workouts:write'],
    });
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      user_id: string;
      token_id: string;
      pat_token_id: string;
    };
    expect(body.user_id).toBe(user.user_id);
    expect(body.token_id).toBe(token.token_id);
    expect(body.pat_token_id).toBe(token.token_id);
  });

  it('401 when Authorization header is missing', async () => {
    const { app } = await buildApp();
    const res = await app.request('/protected');
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/missing or invalid/i);
  });

  it('401 when token does not start with lm_pat_', async () => {
    const { app } = await buildApp();
    const res = await app.request('/protected', {
      headers: { authorization: 'Bearer sk_something_else' },
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/invalid token format/i);
  });

  it('401 when token is unknown', async () => {
    const { app } = await buildApp();
    const res = await app.request('/protected', {
      headers: {
        authorization:
          'Bearer lm_pat_live_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      },
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe('Invalid token');
  });

  it('401 when token is revoked', async () => {
    const { app, createUser, createToken, revokeTokenByHash } = await buildApp();
    const user = await createUser({
      display_name: 'Revoked',
      primary_email: `rev-${Date.now()}-${Math.random()}@example.com`,
    });
    const { token, plaintext } = await createToken({
      user_id: user.user_id,
      name: 't',
      scopes: ['workouts:write'],
    });
    await revokeTokenByHash(token.token_hash);
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe('Token revoked');
  });

  it('401 when token is expired', async () => {
    const { app, createUser, createToken } = await buildApp();
    const user = await createUser({
      display_name: 'Expired',
      primary_email: `exp-${Date.now()}-${Math.random()}@example.com`,
    });
    const { plaintext } = await createToken({
      user_id: user.user_id,
      name: 't',
      scopes: ['workouts:write'],
      expires_at: new Date(Date.now() - 1000).toISOString(),
    });
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe('Token expired');
  });

  it('402 when user is on free tier', async () => {
    const { app, createUser, updateUserTier, createToken } = await buildApp();
    const user = await createUser({
      display_name: 'Free',
      primary_email: `free-${Date.now()}-${Math.random()}@example.com`,
    });
    const { plaintext } = await createToken({
      user_id: user.user_id,
      name: 't',
      scopes: ['workouts:write'],
    });
    await updateUserTier(user.user_id, 'free');
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(402);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/subscription/i);
  });

  it('requireScope: 200 when token has the scope', async () => {
    const { app, createUser, createToken } = await buildApp();
    const user = await createUser({
      display_name: 'Scoped OK',
      primary_email: `scopeok-${Date.now()}-${Math.random()}@example.com`,
    });
    const { plaintext } = await createToken({
      user_id: user.user_id,
      name: 't',
      scopes: ['workouts:write', 'workouts:read'],
    });
    const res = await app.request('/scoped', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(200);
  });

  it('requireScope: 403 when token lacks the scope', async () => {
    const { app, createUser, createToken } = await buildApp();
    const user = await createUser({
      display_name: 'Scoped Nope',
      primary_email: `scopenope-${Date.now()}-${Math.random()}@example.com`,
    });
    const { plaintext } = await createToken({
      user_id: user.user_id,
      name: 't',
      scopes: ['workouts:read'],
    });
    const res = await app.request('/scoped', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/scope/i);
  });

  it('requireScope: 401 (not 403) when no token at all', async () => {
    const { app } = await buildApp();
    const res = await app.request('/scoped');
    expect(res.status).toBe(401);
  });

  it('markUsed runs in the background — response returns before stamp', async () => {
    const { app, createUser, createToken, getTokenByHash, hashToken } =
      await buildApp();
    const user = await createUser({
      display_name: 'Used',
      primary_email: `used-${Date.now()}-${Math.random()}@example.com`,
    });
    const { plaintext } = await createToken({
      user_id: user.user_id,
      name: 't',
      scopes: ['workouts:write'],
    });
    const res = await app.request('/protected', {
      headers: {
        authorization: `Bearer ${plaintext}`,
        'x-forwarded-for': '198.51.100.7, 10.0.0.1',
      },
    });
    expect(res.status).toBe(200);
    // Poll briefly — fire-and-forget should land within a few ms in
    // the local DDB.
    let fetched = null as Awaited<ReturnType<typeof getTokenByHash>>;
    for (let i = 0; i < 20; i++) {
      fetched = await getTokenByHash(hashToken(plaintext));
      if (fetched?.last_used_at) break;
      await new Promise((r) => setTimeout(r, 25));
    }
    expect(fetched?.last_used_at).toBeDefined();
    expect(fetched?.last_used_ip).toBe('198.51.100.7');
  });
});

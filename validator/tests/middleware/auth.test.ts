import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { Hono } from 'hono';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';

// Needs real user + token rows, so it's a live-DDB test.
const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

liveDdb('combined auth middleware (session JWT or PAT)', () => {
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
    createToken: typeof import('../../src/repositories/pat_tokens.js').createToken;
    revokeTokenByHash: typeof import('../../src/repositories/pat_tokens.js').revokeTokenByHash;
    signJwt: typeof import('../../src/infra/jwt.js').signJwt;
  }> {
    const { auth, requireScope } = await import(
      '../../src/middleware/auth.js'
    );
    const users = await import('../../src/repositories/users.js');
    const repo = await import('../../src/repositories/pat_tokens.js');
    const { signJwt } = await import('../../src/infra/jwt.js');
    const app = new Hono();
    app.get('/protected', auth, (c) => {
      const ctx = c as typeof c & {
        var: {
          user: { user_id: string };
          token?: { token_id: string };
          pat_token_id?: string;
          session?: { identity_id: string };
        };
      };
      return c.json({
        user_id: ctx.var.user.user_id,
        token_id: ctx.var.token?.token_id ?? null,
        pat_token_id: ctx.var.pat_token_id ?? null,
        identity_id: ctx.var.session?.identity_id ?? null,
      });
    });
    app.get('/scoped', requireScope('workouts:write'), (c) => {
      const ctx = c as typeof c & {
        var: {
          user: { user_id: string };
          token?: { token_id: string };
        };
      };
      return c.json({
        user_id: ctx.var.user.user_id,
        had_token: ctx.var.token !== undefined,
      });
    });
    return {
      app,
      createUser: users.createUser,
      createToken: repo.createToken,
      revokeTokenByHash: repo.revokeTokenByHash,
      signJwt,
    };
  }

  function uniqueEmail(label: string): string {
    return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
  }

  it('valid PAT populates user + token on context', async () => {
    const { app, createUser, createToken } = await buildApp();
    const user = await createUser({
      display_name: 'PAT path',
      primary_email: uniqueEmail('auth-pat'),
    });
    const { token, plaintext } = await createToken({
      user_id: user.user_id,
      name: 'auth-test',
      scopes: ['workouts:write'],
    });
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      user_id: string;
      token_id: string | null;
      pat_token_id: string | null;
      identity_id: string | null;
    };
    expect(body.user_id).toBe(user.user_id);
    expect(body.token_id).toBe(token.token_id);
    expect(body.pat_token_id).toBe(token.token_id);
    expect(body.identity_id).toBeNull();
  });

  it('valid session JWT populates user; token stays undefined', async () => {
    const { app, createUser, signJwt } = await buildApp();
    const user = await createUser({
      display_name: 'Session path',
      primary_email: uniqueEmail('auth-sess'),
    });
    const jwt = signJwt(
      { sub: user.user_id, identity_id: 'fake-identity', type: 'access', authn_age: 'fresh' },
      '1h',
    );
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${jwt}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      user_id: string;
      token_id: string | null;
      pat_token_id: string | null;
      identity_id: string | null;
    };
    expect(body.user_id).toBe(user.user_id);
    expect(body.token_id).toBeNull();
    expect(body.pat_token_id).toBeNull();
    expect(body.identity_id).toBe('fake-identity');
  });

  it('no Authorization header → 401', async () => {
    const { app } = await buildApp();
    const res = await app.request('/protected');
    expect(res.status).toBe(401);
  });

  it('garbage token (not a PAT, not a JWT) → 401', async () => {
    const { app } = await buildApp();
    const res = await app.request('/protected', {
      headers: { authorization: 'Bearer total-garbage-not-a-token' },
    });
    expect(res.status).toBe(401);
  });

  it('expired session JWT → 401', async () => {
    const { app, createUser, signJwt } = await buildApp();
    const user = await createUser({
      display_name: 'Expired sess',
      primary_email: uniqueEmail('auth-exp'),
    });
    const jwt = signJwt(
      { sub: user.user_id, identity_id: 'x', type: 'access', authn_age: 'fresh' },
      '1s',
    );
    await new Promise((r) => setTimeout(r, 2000));
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${jwt}` },
    });
    expect(res.status).toBe(401);
  }, 5000);

  it('revoked PAT → 401', async () => {
    const { app, createUser, createToken, revokeTokenByHash } = await buildApp();
    const user = await createUser({
      display_name: 'Revoked',
      primary_email: uniqueEmail('auth-rev'),
    });
    const { token, plaintext } = await createToken({
      user_id: user.user_id,
      name: 'rev',
      scopes: ['workouts:write'],
    });
    await revokeTokenByHash(token.token_hash);
    const res = await app.request('/protected', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(401);
  });

  it('requireScope: session JWT passes scope check (sessions are full-power)', async () => {
    const { app, createUser, signJwt } = await buildApp();
    const user = await createUser({
      display_name: 'Sess scope',
      primary_email: uniqueEmail('auth-sess-scope'),
    });
    const jwt = signJwt(
      { sub: user.user_id, identity_id: 'x', type: 'access', authn_age: 'fresh' },
      '1h',
    );
    const res = await app.request('/scoped', {
      headers: { authorization: `Bearer ${jwt}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { user_id: string; had_token: boolean };
    expect(body.user_id).toBe(user.user_id);
    expect(body.had_token).toBe(false);
  });

  it('requireScope: PAT lacking the scope → 403', async () => {
    const { app, createUser, createToken } = await buildApp();
    const user = await createUser({
      display_name: 'PAT no scope',
      primary_email: uniqueEmail('auth-pat-no-scope'),
    });
    const { plaintext } = await createToken({
      user_id: user.user_id,
      name: 'read-only',
      scopes: ['workouts:read'],
    });
    const res = await app.request('/scoped', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/scope/i);
  });
});

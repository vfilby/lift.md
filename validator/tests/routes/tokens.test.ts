import { describe, it, expect, beforeAll, afterAll } from 'vitest';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';

// /v1/tokens is pure session-JWT-auth; no SMTP needed. The full
// signup→verify→login flow is exercised by password.test.ts; here we
// short-circuit by minting a session JWT against a freshly-created user.
const live = process.env.DDB_ENDPOINT ? describe : describe.skip;

live('PAT issuance routes (/v1/tokens)', () => {
  let originalSecret: string | undefined;
  let app: typeof import('../../src/app.js').app;
  let updateUserTier: typeof import('../../src/repositories/users.js').updateUserTier;
  let createUser: typeof import('../../src/repositories/users.js').createUser;
  let signJwt: typeof import('../../src/infra/jwt.js').signJwt;

  beforeAll(async () => {
    originalSecret = process.env.JWT_SECRET;
    process.env.JWT_SECRET = TEST_SECRET;
    ({ app } = await import('../../src/app.js'));
    ({ updateUserTier, createUser } = await import(
      '../../src/repositories/users.js'
    ));
    ({ signJwt } = await import('../../src/infra/jwt.js'));
  });

  afterAll(() => {
    if (originalSecret === undefined) {
      delete process.env.JWT_SECRET;
    } else {
      process.env.JWT_SECRET = originalSecret;
    }
  });

  function uniqueEmail(label: string): string {
    return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
  }

  async function signupAndLogin(label: string): Promise<{
    user_id: string;
    session_jwt: string;
    email: string;
  }> {
    const email = uniqueEmail(label);
    const user = await createUser({
      display_name: 'Token Tester',
      primary_email: email,
    });
    const session_jwt = signJwt(
      {
        sub: user.user_id,
        identity_id: `test-identity-${user.user_id}`,
        type: 'access',
        authn_age: 'fresh',
      },
      '1h',
    );
    return { user_id: user.user_id, session_jwt, email };
  }

  async function createPat(
    session_jwt: string,
    body: Record<string, unknown> = { name: 'CLI' },
  ): Promise<Response> {
    return app.request('/v1/tokens', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${session_jwt}`,
      },
      body: JSON.stringify(body),
    });
  }

  it('POST /v1/tokens issues a PAT with plaintext shown once', async () => {
    const { session_jwt } = await signupAndLogin('happy');
    const res = await createPat(session_jwt, { name: 'My CLI' });
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      token_id: string;
      prefix: string;
      name: string;
      scopes: string[];
      created_at: string;
      expires_at?: string;
      plaintext: string;
      message: string;
    };
    expect(body.token_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(body.plaintext).toMatch(/^lm_pat_(live|test)_[A-Za-z0-9_-]{32}$/);
    expect(body.prefix).toBe(
      body.plaintext.slice(body.plaintext.length - 32, body.plaintext.length - 24),
    );
    expect(body.name).toBe('My CLI');
    expect(body.scopes).toEqual(['workouts:write', 'workouts:read']);
    expect(body.message).toMatch(/will not be shown again/i);
  });

  it('GET /v1/tokens lists tokens without plaintext or hash', async () => {
    const { session_jwt } = await signupAndLogin('list');
    const created = (await (await createPat(session_jwt, { name: 'one' })).json()) as {
      token_id: string;
    };

    const res = await app.request('/v1/tokens', {
      headers: { authorization: `Bearer ${session_jwt}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      tier: string;
      trial_ends_at: string;
      tokens: Array<Record<string, unknown>>;
    };
    expect(body.tier).toBe('trial');
    expect(typeof body.trial_ends_at).toBe('string');
    expect(body.tokens).toHaveLength(1);
    const t = body.tokens[0];
    expect(t.token_id).toBe(created.token_id);
    expect(t.token_hash).toBeUndefined();
    expect((t as { plaintext?: unknown }).plaintext).toBeUndefined();
  });

  it('DELETE /v1/tokens/:id revokes and GET shows revoked_at', async () => {
    const { session_jwt } = await signupAndLogin('revoke');
    const created = (await (await createPat(session_jwt, { name: 'rev' })).json()) as {
      token_id: string;
    };

    const del = await app.request(`/v1/tokens/${created.token_id}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${session_jwt}` },
    });
    expect(del.status).toBe(204);

    const list = (await (
      await app.request('/v1/tokens', {
        headers: { authorization: `Bearer ${session_jwt}` },
      })
    ).json()) as { tokens: Array<{ token_id: string; revoked_at?: string }> };
    const found = list.tokens.find((t) => t.token_id === created.token_id);
    expect(found?.revoked_at).toBeDefined();
  });

  it('DELETE non-existent token returns 204 (idempotent, no enumeration)', async () => {
    const { session_jwt } = await signupAndLogin('idem');
    const res = await app.request(
      '/v1/tokens/00000000-0000-0000-0000-000000000000',
      {
        method: 'DELETE',
        headers: { authorization: `Bearer ${session_jwt}` },
      },
    );
    expect(res.status).toBe(204);
  });

  it('POST without session JWT returns 401', async () => {
    const res = await app.request('/v1/tokens', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'nope' }),
    });
    expect(res.status).toBe(401);
  });

  it('GET without session JWT returns 401', async () => {
    const res = await app.request('/v1/tokens');
    expect(res.status).toBe(401);
  });

  it('trial user at 2-token limit gets 429 on third POST', async () => {
    const { session_jwt } = await signupAndLogin('triallimit');
    const a = await createPat(session_jwt, { name: 'one' });
    expect(a.status).toBe(201);
    const b = await createPat(session_jwt, { name: 'two' });
    expect(b.status).toBe(201);
    const c = await createPat(session_jwt, { name: 'three' });
    expect(c.status).toBe(429);
    const body = (await c.json()) as { error: string; upgrade_url: string };
    expect(body.error).toMatch(/trial limit/i);
    expect(body.upgrade_url).toMatch(/^https?:\/\//);
  });

  it('revoked tokens do not count against trial cap', async () => {
    const { session_jwt } = await signupAndLogin('trial-revoked');
    const t1 = (await (await createPat(session_jwt, { name: '1' })).json()) as {
      token_id: string;
    };
    await createPat(session_jwt, { name: '2' });
    // Revoke t1, should be able to create a third token now.
    const del = await app.request(`/v1/tokens/${t1.token_id}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${session_jwt}` },
    });
    expect(del.status).toBe(204);
    const t3 = await createPat(session_jwt, { name: '3' });
    expect(t3.status).toBe(201);
  });

  it('free tier gets 402 on POST', async () => {
    const { session_jwt, user_id } = await signupAndLogin('freetier');
    await updateUserTier(user_id, 'free');
    const res = await createPat(session_jwt, { name: 'nope' });
    expect(res.status).toBe(402);
    const body = (await res.json()) as { error: string; upgrade_url: string };
    expect(body.error).toMatch(/subscription/i);
    expect(body.upgrade_url).toBeDefined();
  });

  it('rejects empty name with 400', async () => {
    const { session_jwt } = await signupAndLogin('emptyname');
    const res = await createPat(session_jwt, { name: '' });
    expect(res.status).toBe(400);
  });

  it('rejects expires_at in the past', async () => {
    const { session_jwt } = await signupAndLogin('pastexp');
    const res = await createPat(session_jwt, {
      name: 'past',
      expires_at: new Date(Date.now() - 1000).toISOString(),
    });
    expect(res.status).toBe(400);
  });

  it('rejects malformed expires_at', async () => {
    const { session_jwt } = await signupAndLogin('badexp');
    const res = await createPat(session_jwt, {
      name: 'bad',
      expires_at: 'not-a-date',
    });
    expect(res.status).toBe(400);
  });

  it('accepts custom scopes', async () => {
    const { session_jwt } = await signupAndLogin('scopes');
    const res = await createPat(session_jwt, {
      name: 'narrow',
      scopes: ['workouts:read'],
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { scopes: string[] };
    expect(body.scopes).toEqual(['workouts:read']);
  });

  it('rejects an unknown scope with 400 (allowlist) and surfaces allowed_scopes', async () => {
    const { session_jwt } = await signupAndLogin('bad-scope');
    const res = await createPat(session_jwt, {
      name: 'evil',
      scopes: ['workouts:read', 'admin'],
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      error: string;
      allowed_scopes: string[];
    };
    expect(body.error).toMatch(/unknown scope/i);
    expect(body.allowed_scopes).toEqual(['workouts:read', 'workouts:write']);
  });

  it('rejects a scopes array over the length cap with 400', async () => {
    const { session_jwt } = await signupAndLogin('many-scopes');
    const res = await createPat(session_jwt, {
      name: 'flood',
      // 17 entries (cap is 16) — all valid strings, rejected purely on length.
      scopes: Array.from({ length: 17 }, () => 'workouts:read'),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/at most/i);
  });

  // ── I1: cross-user IDOR regression (PAT) ────────────────────────────
  // User A cannot revoke user B's token. Revoke is owner-scoped and silently
  // idempotent (204, no enumeration), so the assertion is that B's token is
  // still usable afterward — A's call had no effect on B's resource.
  it("user A's revoke of user B's token_id is a no-op (B's token still active)", async () => {
    const userA = await signupAndLogin('idor-pat-a');
    const userB = await signupAndLogin('idor-pat-b');
    const bToken = (await (
      await createPat(userB.session_jwt, { name: 'b-token' })
    ).json()) as { token_id: string };

    // A attempts to revoke B's token by its public id.
    const del = await app.request(`/v1/tokens/${bToken.token_id}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${userA.session_jwt}` },
    });
    // Idempotent / no enumeration — never 404, but it must not actually revoke.
    expect(del.status).toBe(204);

    // B's token is untouched (no revoked_at).
    const list = (await (
      await app.request('/v1/tokens', {
        headers: { authorization: `Bearer ${userB.session_jwt}` },
      })
    ).json()) as { tokens: Array<{ token_id: string; revoked_at?: string }> };
    const found = list.tokens.find((t) => t.token_id === bToken.token_id);
    expect(found).toBeDefined();
    expect(found?.revoked_at).toBeUndefined();
  });

  it("user A's token list never includes user B's tokens", async () => {
    const userA = await signupAndLogin('idor-list-a');
    const userB = await signupAndLogin('idor-list-b');
    const bToken = (await (
      await createPat(userB.session_jwt, { name: 'b-only' })
    ).json()) as { token_id: string };

    const list = (await (
      await app.request('/v1/tokens', {
        headers: { authorization: `Bearer ${userA.session_jwt}` },
      })
    ).json()) as { tokens: Array<{ token_id: string }> };
    expect(list.tokens.find((t) => t.token_id === bToken.token_id)).toBeUndefined();
  });
});

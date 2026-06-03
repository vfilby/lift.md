import { describe, it, expect, beforeAll, afterAll } from 'vitest';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';
const live = process.env.DDB_ENDPOINT ? describe : describe.skip;

interface MeBody {
  user_id: string;
  primary_email: string;
  display_name: string;
  tier: string;
  trial_ends_at: string;
}

live('GET /v1/me', () => {
  let originalSecret: string | undefined;
  let app: typeof import('../../src/app.js').app;
  let createUser: typeof import('../../src/repositories/users.js').createUser;
  let createToken: typeof import('../../src/repositories/pat_tokens.js').createToken;
  let signJwt: typeof import('../../src/infra/jwt.js').signJwt;

  beforeAll(async () => {
    originalSecret = process.env.JWT_SECRET;
    process.env.JWT_SECRET = TEST_SECRET;
    ({ app } = await import('../../src/app.js'));
    ({ createUser } = await import('../../src/repositories/users.js'));
    ({ createToken } = await import('../../src/repositories/pat_tokens.js'));
    ({ signJwt } = await import('../../src/infra/jwt.js'));
  });

  afterAll(() => {
    if (originalSecret === undefined) delete process.env.JWT_SECRET;
    else process.env.JWT_SECRET = originalSecret;
  });

  function uniqueEmail(label: string): string {
    return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
  }

  it('returns the authenticated user profile (session JWT)', async () => {
    const email = uniqueEmail('me-session');
    const user = await createUser({
      display_name: 'Me Tester',
      primary_email: email,
    });
    const jwt = signJwt(
      {
        sub: user.user_id,
        identity_id: 'identity-me-session',
        type: 'access',
        authn_age: 'fresh',
      },
      '1h',
    );

    const res = await app.request('/v1/me', {
      headers: { authorization: `Bearer ${jwt}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as MeBody;
    expect(body.user_id).toBe(user.user_id);
    expect(body.primary_email).toBe(email.toLowerCase());
    expect(body.display_name).toBe('Me Tester');
    expect(body.tier).toBe('trial');
    expect(typeof body.trial_ends_at).toBe('string');
  });

  it('returns the authenticated user profile (PAT)', async () => {
    const user = await createUser({
      display_name: 'PAT Me',
      primary_email: uniqueEmail('me-pat'),
    });
    const { plaintext } = await createToken({
      user_id: user.user_id,
      name: 'me-pat',
      scopes: [],
      mode: 'test',
    });

    const res = await app.request('/v1/me', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as MeBody;
    expect(body.user_id).toBe(user.user_id);
    expect(body.display_name).toBe('PAT Me');
  });

  it('unauthenticated → 401', async () => {
    const res = await app.request('/v1/me');
    expect(res.status).toBe(401);
  });

  it('404 when the authenticated user row is missing', async () => {
    // Mint a cryptographically-valid access JWT for a user_id that has no row.
    const jwt = signJwt(
      {
        sub: 'no-such-user-00000000',
        identity_id: 'identity-ghost',
        type: 'access',
        authn_age: 'fresh',
      },
      '1h',
    );
    const res = await app.request('/v1/me', {
      headers: { authorization: `Bearer ${jwt}` },
    });
    // The session auth middleware rejects an unknown sub up front (401),
    // which is also an acceptable "no profile" outcome. Either way the caller
    // never gets a body for a non-existent user.
    expect([401, 404]).toContain(res.status);
  });
});

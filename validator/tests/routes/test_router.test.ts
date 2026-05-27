import { describe, it, expect, beforeAll, afterAll } from 'vitest';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';
const E2E_SECRET = 'e2e-secret-do-not-use-in-prod-1234567890abcdef';

const live = process.env.DDB_ENDPOINT ? describe : describe.skip;

live('Test-only router (/v1/__test__)', () => {
  let originalJwt: string | undefined;
  let originalE2E: string | undefined;
  let originalEnv: string | undefined;
  let app: typeof import('../../src/app.js').app;
  let createUser: typeof import('../../src/repositories/users.js').createUser;
  let createIdentity: typeof import('../../src/repositories/identities.js').createIdentity;
  let verifyJwt: typeof import('../../src/infra/jwt.js').verifyJwt;

  beforeAll(async () => {
    originalJwt = process.env.JWT_SECRET;
    originalE2E = process.env.E2E_TEST_SECRET;
    originalEnv = process.env.LMWF_ENV;
    process.env.JWT_SECRET = TEST_SECRET;
    process.env.E2E_TEST_SECRET = E2E_SECRET;
    process.env.LMWF_ENV = 'beta';
    ({ app } = await import('../../src/app.js'));
    ({ createUser } = await import('../../src/repositories/users.js'));
    ({ createIdentity } = await import(
      '../../src/repositories/identities.js'
    ));
    ({ verifyJwt } = await import('../../src/infra/jwt.js'));
  });

  afterAll(() => {
    if (originalJwt === undefined) delete process.env.JWT_SECRET;
    else process.env.JWT_SECRET = originalJwt;
    if (originalE2E === undefined) delete process.env.E2E_TEST_SECRET;
    else process.env.E2E_TEST_SECRET = originalE2E;
    if (originalEnv === undefined) delete process.env.LMWF_ENV;
    else process.env.LMWF_ENV = originalEnv;
  });

  function uniqueEmail(label: string): string {
    return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
  }

  async function seedIdentity(email: string): Promise<string> {
    const user = await createUser({
      display_name: 'E2E Test User',
      primary_email: email,
    });
    const identity = await createIdentity({
      user_id: user.user_id,
      provider: 'password',
      provider_sub: email,
      email,
      email_verified: false,
      password_hash: 'x'.repeat(80),
      password_updated_at: new Date().toISOString(),
    });
    return identity.identity_id;
  }

  async function mint(
    body: unknown,
    headers: Record<string, string> = { 'x-test-secret': E2E_SECRET },
  ): Promise<Response> {
    return app.request('/v1/__test__/mint-token', {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body: JSON.stringify(body),
    });
  }

  it('404s when the X-Test-Secret header is missing', async () => {
    const res = await mint({ email: 'whoever@example.com', type: 'email_verify' }, {});
    expect(res.status).toBe(404);
  });

  it('404s when the X-Test-Secret header is wrong', async () => {
    const res = await mint(
      { email: 'whoever@example.com', type: 'email_verify' },
      { 'x-test-secret': 'wrong-secret' },
    );
    expect(res.status).toBe(404);
  });

  it('404s when the email does not match an identity', async () => {
    const res = await mint({
      email: `nobody-${Date.now()}@example.com`,
      type: 'email_verify',
    });
    expect(res.status).toBe(404);
  });

  it('400s when type is not a known token type', async () => {
    const email = uniqueEmail('bad-type');
    await seedIdentity(email);
    const res = await mint({ email, type: 'access' });
    expect(res.status).toBe(400);
  });

  it('mints a verifiable email_verify JWT on the happy path', async () => {
    const email = uniqueEmail('verify');
    const identityId = await seedIdentity(email);
    const res = await mint({ email, type: 'email_verify' });
    expect(res.status).toBe(200);
    const { token } = (await res.json()) as { token: string };
    const payload = verifyJwt<{ sub: string; type: string }>(token);
    expect(payload.sub).toBe(identityId);
    expect(payload.type).toBe('email_verify');
  });

  it('mints a verifiable password_reset JWT on the happy path', async () => {
    const email = uniqueEmail('reset');
    const identityId = await seedIdentity(email);
    const res = await mint({ email, type: 'password_reset' });
    expect(res.status).toBe(200);
    const { token } = (await res.json()) as { token: string };
    const payload = verifyJwt<{ sub: string; type: string }>(token);
    expect(payload.sub).toBe(identityId);
    expect(payload.type).toBe('password_reset');
  });

  it('treats email case-insensitively', async () => {
    const email = uniqueEmail('case').toLowerCase();
    await seedIdentity(email);
    const res = await mint({ email: email.toUpperCase(), type: 'email_verify' });
    expect(res.status).toBe(200);
  });
});

describe('Test-only router gating', () => {
  // These do NOT need DDB — pure middleware gate behavior.

  it('404s every request when E2E_TEST_SECRET is unset', async () => {
    const originalE2E = process.env.E2E_TEST_SECRET;
    const originalEnv = process.env.LMWF_ENV;
    const originalJwt = process.env.JWT_SECRET;
    delete process.env.E2E_TEST_SECRET;
    process.env.LMWF_ENV = 'beta';
    process.env.JWT_SECRET = TEST_SECRET;
    try {
      // Re-import to ensure middleware sees the cleared env at request time.
      const { app } = await import('../../src/app.js');
      const res = await app.request('/v1/__test__/mint-token', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-test-secret': 'anything',
        },
        body: JSON.stringify({ email: 'a@b.com', type: 'email_verify' }),
      });
      expect(res.status).toBe(404);
    } finally {
      if (originalE2E !== undefined) process.env.E2E_TEST_SECRET = originalE2E;
      if (originalEnv !== undefined) process.env.LMWF_ENV = originalEnv;
      if (originalJwt !== undefined) process.env.JWT_SECRET = originalJwt;
      else delete process.env.JWT_SECRET;
    }
  });

  it('404s every request when LMWF_ENV is prod, even with a valid secret', async () => {
    const originalE2E = process.env.E2E_TEST_SECRET;
    const originalEnv = process.env.LMWF_ENV;
    const originalJwt = process.env.JWT_SECRET;
    process.env.E2E_TEST_SECRET = E2E_SECRET;
    process.env.LMWF_ENV = 'prod';
    process.env.JWT_SECRET = TEST_SECRET;
    try {
      const { app } = await import('../../src/app.js');
      const res = await app.request('/v1/__test__/mint-token', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-test-secret': E2E_SECRET,
        },
        body: JSON.stringify({ email: 'a@b.com', type: 'email_verify' }),
      });
      expect(res.status).toBe(404);
    } finally {
      if (originalE2E !== undefined) process.env.E2E_TEST_SECRET = originalE2E;
      else delete process.env.E2E_TEST_SECRET;
      if (originalEnv !== undefined) process.env.LMWF_ENV = originalEnv;
      else delete process.env.LMWF_ENV;
      if (originalJwt !== undefined) process.env.JWT_SECRET = originalJwt;
      else delete process.env.JWT_SECRET;
    }
  });
});

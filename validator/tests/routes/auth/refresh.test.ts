import { describe, it, expect, beforeAll, afterAll } from 'vitest';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';
const MAILPIT_API = process.env.MAILPIT_API ?? 'http://localhost:8025';

// Needs DDB + Mailpit (signup verification email).
const live =
  process.env.DDB_ENDPOINT && process.env.SMTP_HOST ? describe : describe.skip;

interface MailpitListResponse {
  messages: { ID: string; To: { Address: string }[]; Subject: string }[];
  total: number;
}

interface MailpitMessageDetail {
  ID: string;
  Subject: string;
  Text: string;
  HTML: string;
}

async function fetchMailTo(addr: string): Promise<MailpitMessageDetail> {
  const list = (await (
    await fetch(`${MAILPIT_API}/api/v1/messages`)
  ).json()) as MailpitListResponse;
  const summary = list.messages.find((m) =>
    m.To.some((t) => t.Address === addr),
  );
  if (!summary) throw new Error(`No mail captured for ${addr}`);
  return (await (
    await fetch(`${MAILPIT_API}/api/v1/message/${summary.ID}`)
  ).json()) as MailpitMessageDetail;
}

function extractToken(body: string): string {
  const m = body.match(/[?&]token=([^\s"'<>&]+)/);
  if (!m) throw new Error(`No token in body`);
  return decodeURIComponent(m[1]);
}

interface LoginBody {
  access_jwt: string;
  refresh_token: string;
  user: { user_id: string; email: string };
}

interface RefreshBody {
  access_jwt: string;
  refresh_token: string;
}

live('refresh-token routes', () => {
  let originalSecret: string | undefined;
  let app: typeof import('../../../src/app.js').app;

  beforeAll(async () => {
    originalSecret = process.env.JWT_SECRET;
    process.env.JWT_SECRET = TEST_SECRET;
    process.env.SMTP_PORT ??= '1025';
    process.env.SMTP_FROM ??= 'test@local.dev';

    const { _resetEmailTransportForTests } = await import(
      '../../../src/infra/email.js'
    );
    _resetEmailTransportForTests();

    ({ app } = await import('../../../src/app.js'));
  });

  afterAll(() => {
    if (originalSecret === undefined) {
      delete process.env.JWT_SECRET;
    } else {
      process.env.JWT_SECRET = originalSecret;
    }
  });

  // Intentionally NO deleteAllMail() — refresh.test.ts and
  // password.test.ts both share the Mailpit container and run in
  // parallel under vitest. Wiping the mailbox here would race-delete
  // verification emails password.test.ts is mid-flight on. Each test
  // here uses uniqueEmail(), so fetchMailTo finds its message by
  // recipient regardless of unrelated mail in the box.

  function uniqueEmail(label: string): string {
    return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
  }

  async function signupAndLogin(): Promise<LoginBody> {
    const email = uniqueEmail('refresh-test');
    const password = 'correct-horse-battery-staple';

    const signupRes = await app.request('/v1/auth/password/signup', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email, password, display_name: 'Refresh User' }),
    });
    expect(signupRes.status).toBe(201);

    const mail = await fetchMailTo(email);
    const verifyTok = extractToken(mail.Text || mail.HTML);
    const verifyRes = await app.request('/v1/auth/password/verify', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ token: verifyTok }),
    });
    expect(verifyRes.status).toBe(200);

    const loginRes = await app.request('/v1/auth/password/login', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email, password, device_label: 'vitest' }),
    });
    expect(loginRes.status).toBe(200);
    return (await loginRes.json()) as LoginBody;
  }

  async function refresh(refresh_token: string): Promise<Response> {
    return app.request('/v1/auth/refresh', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ refresh_token }),
    });
  }

  it('login returns a refresh token of the documented shape', async () => {
    const login = await signupAndLogin();
    expect(login.refresh_token).toMatch(/^lm_refresh_[A-Za-z0-9_-]{32}$/);
    expect(login.access_jwt.split('.')).toHaveLength(3);
  });

  it('refresh: returns new access + refresh; old refresh is revoked and cannot reuse', async () => {
    const login = await signupAndLogin();

    const res = await refresh(login.refresh_token);
    expect(res.status).toBe(200);
    const body = (await res.json()) as RefreshBody;
    expect(body.access_jwt.split('.')).toHaveLength(3);
    expect(body.refresh_token).toMatch(/^lm_refresh_[A-Za-z0-9_-]{32}$/);
    expect(body.refresh_token).not.toBe(login.refresh_token);

    // Old refresh used twice → reuse detected → 401.
    const reuse = await refresh(login.refresh_token);
    expect(reuse.status).toBe(401);
    const reuseBody = (await reuse.json()) as { error: string };
    expect(reuseBody.error).toMatch(/reuse detected/i);

    // And reuse detection nukes the whole family — the NEW refresh
    // (legitimate descendant) must also be invalidated.
    const cascadedDeny = await refresh(body.refresh_token);
    expect(cascadedDeny.status).toBe(401);
  });

  it('refresh: rotated access JWT carries authn_age=rotated', async () => {
    const login = await signupAndLogin();
    const res = await refresh(login.refresh_token);
    const body = (await res.json()) as RefreshBody;

    // Decode the JWT payload without verifying — vitest doesn't need
    // to re-validate signatures, the middleware tests cover that.
    const payload = JSON.parse(
      Buffer.from(body.access_jwt.split('.')[1], 'base64url').toString('utf8'),
    ) as { type: string; authn_age: string };
    expect(payload.type).toBe('access');
    expect(payload.authn_age).toBe('rotated');
  });

  it('refresh: absolute expiry inherited; 5 rotations do not extend expires_at', async () => {
    const login = await signupAndLogin();

    // Pull the original row's expires_at directly from DDB.
    const { getRefreshTokenByHash, hashRefreshToken } = await import(
      '../../../src/repositories/refresh_tokens.js'
    );
    const root = await getRefreshTokenByHash(
      hashRefreshToken(login.refresh_token),
    );
    expect(root).not.toBeNull();
    const rootExpiry = root!.expires_at;

    let current = login.refresh_token;
    for (let i = 0; i < 5; i++) {
      const res = await refresh(current);
      expect(res.status).toBe(200);
      const body = (await res.json()) as RefreshBody;
      current = body.refresh_token;

      const row = await getRefreshTokenByHash(hashRefreshToken(current));
      expect(row?.expires_at).toBe(rootExpiry);
      expect(row?.family_root_hash).toBe(root!.family_root_hash);
    }
  });

  it('refresh: unknown token → 401', async () => {
    const res = await refresh('lm_refresh_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx');
    expect(res.status).toBe(401);
  });

  it('refresh: missing/malformed body → 400 or 401', async () => {
    const noBody = await app.request('/v1/auth/refresh', { method: 'POST' });
    expect(noBody.status).toBe(400);

    const wrongShape = await app.request('/v1/auth/refresh', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ refresh_token: 'not-an-lm-refresh' }),
    });
    expect(wrongShape.status).toBe(401);
  });

  it('refresh: token in query string is explicitly rejected (defense in depth)', async () => {
    const login = await signupAndLogin();
    const res = await app.request(
      `/v1/auth/refresh?refresh_token=${encodeURIComponent(login.refresh_token)}`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ refresh_token: login.refresh_token }),
      },
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/body, not the url/i);

    // And the legit token is still usable (the rejection happens
    // before we touch the row).
    const ok = await refresh(login.refresh_token);
    expect(ok.status).toBe(200);
  });

  it('logout: valid refresh + matching access JWT → 204, refresh becomes unusable', async () => {
    const login = await signupAndLogin();

    const res = await app.request('/v1/auth/logout', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${login.access_jwt}`,
      },
      body: JSON.stringify({ refresh_token: login.refresh_token }),
    });
    expect(res.status).toBe(204);

    // The refresh is gone.
    const denied = await refresh(login.refresh_token);
    expect(denied.status).toBe(401);
    const deniedBody = (await denied.json()) as { error: string };
    expect(deniedBody.error).toMatch(/revoked/i);
    // ...and importantly NOT "reuse detected" — straight revocation
    // (logout) should not look like theft.
    expect(deniedBody.error).not.toMatch(/reuse/i);
  });

  it('logout: missing/foreign refresh_token still 204 (no enumeration oracle)', async () => {
    const login = await signupAndLogin();
    const other = await signupAndLogin();

    // Refresh belongs to a different user.
    const res = await app.request('/v1/auth/logout', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${login.access_jwt}`,
      },
      body: JSON.stringify({ refresh_token: other.refresh_token }),
    });
    expect(res.status).toBe(204);
    // The other user's refresh is unaffected.
    const stillOk = await refresh(other.refresh_token);
    expect(stillOk.status).toBe(200);
  });

  it('refresh: two concurrent rotations of the same token → exactly one 200, exactly one 401; family has 2 rows total', async () => {
    const login = await signupAndLogin();

    // Fire both refresh calls in parallel against the SAME plaintext.
    // Without atomic rotation both would pass the not-revoked check
    // and both would insert distinct new children, producing a
    // three-row family + a guaranteed reuse cascade on next refresh.
    const [a, b] = await Promise.allSettled([
      refresh(login.refresh_token),
      refresh(login.refresh_token),
    ]);

    expect(a.status).toBe('fulfilled');
    expect(b.status).toBe('fulfilled');
    const resA = (a as PromiseFulfilledResult<Response>).value;
    const resB = (b as PromiseFulfilledResult<Response>).value;

    const statuses = [resA.status, resB.status].sort();
    expect(statuses).toEqual([200, 401]);

    const winnerRes = resA.status === 200 ? resA : resB;
    const loserRes = resA.status === 401 ? resA : resB;

    const winnerBody = (await winnerRes.json()) as RefreshBody;
    expect(winnerBody.access_jwt.split('.')).toHaveLength(3);
    expect(winnerBody.refresh_token).toMatch(/^lm_refresh_[A-Za-z0-9_-]{32}$/);

    const loserBody = (await loserRes.json()) as { error: string };
    expect(loserBody.error).toMatch(/already rotated/i);

    // The family has exactly TWO rows: the original root + the one
    // winning child. No orphan loser row exists.
    const {
      hashRefreshToken: hash,
      getRefreshTokenByHash: getRow,
    } = await import('../../../src/repositories/refresh_tokens.js');
    const { ddb, tableName } = await import('../../../src/infra/ddb.js');
    const { QueryCommand } = await import('@aws-sdk/lib-dynamodb');

    const root = await getRow(hash(login.refresh_token));
    expect(root).not.toBeNull();
    const family = await ddb.send(
      new QueryCommand({
        TableName: tableName('refresh_tokens'),
        IndexName: 'family-index',
        KeyConditionExpression: 'family_root_hash = :r',
        ExpressionAttributeValues: { ':r': root!.family_root_hash },
      }),
    );
    const items = (family.Items as { token_hash: string }[]) ?? [];
    expect(items.length).toBe(2);
    const hashes = items.map((i) => i.token_hash).sort();
    expect(hashes).toEqual(
      [root!.token_hash, hash(winnerBody.refresh_token)].sort(),
    );

    // And the winner's new token is fully usable — the loser's 401
    // did NOT trip reuse detection / cascade-revoke the family.
    const followUp = await refresh(winnerBody.refresh_token);
    expect(followUp.status).toBe(200);
  });

  it('logout-all: revokes every refresh for the user', async () => {
    // Two logins for the same email simulate two devices.
    const login1 = await signupAndLogin();
    // Re-login via password to get a second refresh on the same user
    // would require the email; signupAndLogin always creates a new
    // user. Instead, simulate a 2nd device by minting a second refresh
    // directly with the repo (faster than re-logging in).
    const { createRefreshToken } = await import(
      '../../../src/repositories/refresh_tokens.js'
    );
    const second = await createRefreshToken({
      user_id: login1.user.user_id,
      identity_id: 'second-device-identity',
    });

    const res = await app.request('/v1/auth/logout-all', {
      method: 'POST',
      headers: { authorization: `Bearer ${login1.access_jwt}` },
    });
    expect(res.status).toBe(204);

    expect((await refresh(login1.refresh_token)).status).toBe(401);
    expect((await refresh(second.plaintext)).status).toBe(401);
  });

  it('logout-all: rotated access JWT is rejected with re-auth message; user tokens stay valid', async () => {
    const login = await signupAndLogin();

    // Exchange the fresh refresh token for a rotated access JWT.
    const refRes = await refresh(login.refresh_token);
    expect(refRes.status).toBe(200);
    const refBody = (await refRes.json()) as RefreshBody;

    // Confirm the new JWT is genuinely 'rotated'.
    const payload = JSON.parse(
      Buffer.from(refBody.access_jwt.split('.')[1], 'base64url').toString('utf8'),
    ) as { authn_age: string };
    expect(payload.authn_age).toBe('rotated');

    // Attempt logout-all with the rotated JWT → 401 + re-auth message.
    const res = await app.request('/v1/auth/logout-all', {
      method: 'POST',
      headers: { authorization: `Bearer ${refBody.access_jwt}` },
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/re-authentication required/i);

    // CRITICAL security property: the user's tokens MUST remain valid.
    // A stolen rotated JWT must not be able to DOS the legitimate user.
    const stillUsable = await refresh(refBody.refresh_token);
    expect(stillUsable.status).toBe(200);
  });

  it('logout / logout-all require session auth', async () => {
    const res1 = await app.request('/v1/auth/logout', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ refresh_token: 'lm_refresh_anything' }),
    });
    expect(res1.status).toBe(401);

    const res2 = await app.request('/v1/auth/logout-all', { method: 'POST' });
    expect(res2.status).toBe(401);
  });

  it('identity deletion cascades to refresh tokens for that identity only', async () => {
    const login = await signupAndLogin();

    // Link a second password identity so the first can be deleted.
    const secondEmail = uniqueEmail('cascade-2nd');
    const linkRes = await app.request('/v1/auth/link', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${login.access_jwt}`,
      },
      body: JSON.stringify({
        provider: 'password',
        email: secondEmail,
        password: 'correct-horse-battery-staple',
      }),
    });
    expect(linkRes.status).toBe(201);
    const linkBody = (await linkRes.json()) as { identity_id: string };

    // Mint a refresh against the 2nd identity (simulates a session
    // that authed via the linked sign-in method).
    const { createRefreshToken } = await import(
      '../../../src/repositories/refresh_tokens.js'
    );
    const secondId = await createRefreshToken({
      user_id: login.user.user_id,
      identity_id: linkBody.identity_id,
    });

    // Now figure out which identity_id the original login was on and
    // delete the OTHER one (we need to keep the linked one so we have
    // a valid session JWT for the request).
    const { listIdentitiesByUserId } = await import(
      '../../../src/repositories/identities.js'
    );
    const all = await listIdentitiesByUserId(login.user.user_id);
    const otherIdentity = all.find(
      (i) => i.identity_id !== linkBody.identity_id,
    );
    expect(otherIdentity).toBeDefined();

    const delRes = await app.request(
      `/v1/auth/identities/${otherIdentity!.identity_id}`,
      {
        method: 'DELETE',
        headers: { authorization: `Bearer ${login.access_jwt}` },
      },
    );
    expect(delRes.status).toBe(204);

    // login.refresh_token was bound to the deleted identity → gone.
    expect((await refresh(login.refresh_token)).status).toBe(401);
    // secondId.plaintext was bound to the surviving identity → still works.
    expect((await refresh(secondId.plaintext)).status).toBe(200);
  });
});

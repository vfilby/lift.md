import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';
const MAILPIT_API = process.env.MAILPIT_API ?? 'http://localhost:8025';

// Requires both DDB Local + Mailpit. Same skip pattern as the other
// live-integration tests.
const live =
  process.env.DDB_ENDPOINT && process.env.SMTP_HOST ? describe : describe.skip;

interface MailpitListResponse {
  messages: { ID: string; To: { Address: string }[]; Subject: string }[];
  total: number;
}

interface MailpitMessageDetail {
  ID: string;
  To: { Address: string }[];
  Subject: string;
  Text: string;
  HTML: string;
}

async function deleteAllMail(): Promise<void> {
  await fetch(`${MAILPIT_API}/api/v1/messages`, { method: 'DELETE' });
}

async function fetchMailTo(addr: string): Promise<MailpitMessageDetail> {
  const list = (await (
    await fetch(`${MAILPIT_API}/api/v1/messages`)
  ).json()) as MailpitListResponse;
  const summary = list.messages.find((m) =>
    m.To.some((t) => t.Address === addr),
  );
  if (!summary) {
    throw new Error(
      `No mail captured for ${addr} (have ${list.total} message(s))`,
    );
  }
  return (await (
    await fetch(`${MAILPIT_API}/api/v1/message/${summary.ID}`)
  ).json()) as MailpitMessageDetail;
}

function extractToken(body: string): string {
  const m = body.match(/[?&]token=([^\s"'<>&]+)/);
  if (!m) throw new Error(`No token found in body: ${body}`);
  return decodeURIComponent(m[1]);
}

live('password auth routes', () => {
  let originalSecret: string | undefined;
  let app: typeof import('../../../src/app.js').app;
  let signJwt: typeof import('../../../src/infra/jwt.js').signJwt;

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
    ({ signJwt } = await import('../../../src/infra/jwt.js'));
  });

  afterAll(() => {
    if (originalSecret === undefined) {
      delete process.env.JWT_SECRET;
    } else {
      process.env.JWT_SECRET = originalSecret;
    }
  });

  beforeEach(async () => {
    await deleteAllMail();
  });

  function uniqueEmail(label: string): string {
    return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
  }

  async function signup(
    email: string,
    password: string,
    displayName = 'Test User',
  ): Promise<Response> {
    return app.request('/v1/auth/password/signup', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email, password, display_name: displayName }),
    });
  }

  async function login(email: string, password: string): Promise<Response> {
    return app.request('/v1/auth/password/login', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email, password }),
    });
  }

  async function postJson(
    path: string,
    body: unknown,
    headers: Record<string, string> = {},
  ): Promise<Response> {
    return app.request(path, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body: JSON.stringify(body),
    });
  }

  it('full happy path: signup → verify → login → returns access_jwt + refresh_token', async () => {
    const email = uniqueEmail('happy');
    const password = 'correct-horse-battery-staple';

    const signupRes = await signup(email, password, 'Happy User');
    expect(signupRes.status).toBe(201);
    const signupBody = (await signupRes.json()) as {
      user_id: string;
      email: string;
      message: string;
    };
    expect(signupBody.email).toBe(email);
    expect(signupBody.user_id).toMatch(/^[0-9a-f-]{36}$/);

    const mail = await fetchMailTo(email);
    expect(mail.Subject).toMatch(/verify/i);
    const token = extractToken(mail.Text || mail.HTML);

    // login before verify → uniform 401 (no "email not verified" oracle).
    // Unverified state is surfaced only via resend-verification, never by
    // a distinguishable response that would confirm the password (L3).
    const preVerify = await login(email, password);
    expect(preVerify.status).toBe(401);
    const preVerifyBody = (await preVerify.json()) as { error: string };
    expect(preVerifyBody.error).toBe('Invalid credentials');

    const verifyRes = await postJson('/v1/auth/password/verify', { token });
    expect(verifyRes.status).toBe(200);
    const verifyBody = (await verifyRes.json()) as {
      verified: boolean;
      user_id: string;
    };
    expect(verifyBody.verified).toBe(true);
    expect(verifyBody.user_id).toBe(signupBody.user_id);

    // Idempotent — second verify also succeeds.
    const verifyAgain = await postJson('/v1/auth/password/verify', { token });
    expect(verifyAgain.status).toBe(200);

    const loginRes = await login(email, password);
    expect(loginRes.status).toBe(200);
    const loginBody = (await loginRes.json()) as {
      access_jwt: string;
      refresh_token: string;
      user: {
        user_id: string;
        email: string;
        display_name: string;
        tier: string;
        trial_ends_at: string;
      };
    };
    expect(loginBody.access_jwt.split('.')).toHaveLength(3);
    expect(loginBody.refresh_token).toMatch(/^lm_refresh_[A-Za-z0-9_-]{32}$/);
    expect(loginBody.user.user_id).toBe(signupBody.user_id);
    expect(loginBody.user.email).toBe(email);
    expect(loginBody.user.display_name).toBe('Happy User');
    expect(loginBody.user.tier).toBe('trial');
    expect(typeof loginBody.user.trial_ends_at).toBe('string');
  });

  it('GET /verify redirects to the website success page on a valid token', async () => {
    const email = uniqueEmail('get-verify');
    const password = 'correct-horse-battery-staple';
    const signupRes = await signup(email, password);
    expect(signupRes.status).toBe(201);
    const mail = await fetchMailTo(email);
    const token = extractToken(mail.Text || mail.HTML);

    const res = await app.request(
      `/v1/auth/password/verify?token=${encodeURIComponent(token)}`,
      { redirect: 'manual' },
    );
    expect(res.status).toBe(302);
    const location = res.headers.get('location') ?? '';
    expect(location).toMatch(/\/account\/email-verified$/);
    expect(location).not.toContain('error=');
  });

  it('GET /verify redirects to the error page on an invalid token', async () => {
    const res = await app.request(
      '/v1/auth/password/verify?token=not-a-real-token',
      { redirect: 'manual' },
    );
    expect(res.status).toBe(302);
    const location = res.headers.get('location') ?? '';
    expect(location).toContain('/account/email-verified');
    expect(location).toContain('error=invalid');
  });

  it('GET /verify with no token redirects to the error page', async () => {
    const res = await app.request('/v1/auth/password/verify', {
      redirect: 'manual',
    });
    expect(res.status).toBe(302);
    expect(res.headers.get('location') ?? '').toContain('error=invalid');
  });

  it('login fails with 401 on bad password', async () => {
    const email = uniqueEmail('bad-pw');
    const password = 'correct-horse-battery-staple';
    await signup(email, password);
    const mail = await fetchMailTo(email);
    const token = extractToken(mail.Text || mail.HTML);
    await postJson('/v1/auth/password/verify', { token });

    const res = await login(email, 'wrong-but-long-enough-pw');
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe('Invalid credentials');
  });

  it('login on unknown email returns 401 with same error (no enumeration)', async () => {
    const res = await login(uniqueEmail('nobody'), 'anything-long-enough');
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe('Invalid credentials');
  });

  it('signup with existing email returns 409', async () => {
    const email = uniqueEmail('dupe');
    const password = 'correct-horse-battery-staple';
    const first = await signup(email, password);
    expect(first.status).toBe(201);
    const second = await signup(email, password);
    expect(second.status).toBe(409);
  });

  it('signup rolls back user + identity if email send fails (retry works)', async () => {
    // Point SMTP at a port nothing is listening on so the send throws.
    // We rebuild the transport so the next sendEmail call picks up the
    // bad host, then restore + rebuild after.
    const origPort = process.env.SMTP_PORT;
    const origHost = process.env.SMTP_HOST;
    const { _resetEmailTransportForTests } = await import(
      '../../../src/infra/email.js'
    );
    process.env.SMTP_HOST = '127.0.0.1';
    process.env.SMTP_PORT = '1'; // refused
    _resetEmailTransportForTests();

    const email = uniqueEmail('rollback');
    const password = 'correct-horse-battery-staple';

    try {
      const res = await signup(email, password);
      expect(res.status).toBe(503);

      // Same email must signup cleanly on retry — proves the row was rolled
      // back. (Restoring SMTP first so the retry's send actually succeeds.)
      if (origHost !== undefined) process.env.SMTP_HOST = origHost;
      else delete process.env.SMTP_HOST;
      if (origPort !== undefined) process.env.SMTP_PORT = origPort;
      else delete process.env.SMTP_PORT;
      _resetEmailTransportForTests();

      const retry = await signup(email, password);
      expect(retry.status).toBe(201);
    } finally {
      // Ensure env is restored even on failure.
      if (origHost !== undefined) process.env.SMTP_HOST = origHost;
      else delete process.env.SMTP_HOST;
      if (origPort !== undefined) process.env.SMTP_PORT = origPort;
      else delete process.env.SMTP_PORT;
      _resetEmailTransportForTests();
    }
  });

  it('signup rejects short passwords', async () => {
    const res = await signup(uniqueEmail('short'), 'short');
    expect(res.status).toBe(400);
  });

  it('signup rejects invalid email', async () => {
    const res = await signup('not-an-email', 'correct-horse-battery-staple');
    expect(res.status).toBe(400);
  });

  it('reset-request returns 204 even for unknown email', async () => {
    const res = await postJson('/v1/auth/password/reset-request', {
      email: uniqueEmail('ghost'),
    });
    expect(res.status).toBe(204);
  });

  it('reset flow: request → reset → can login with new password', async () => {
    const email = uniqueEmail('reset');
    const oldPassword = 'correct-horse-battery-staple';
    const newPassword = 'a-brand-new-passphrase-here';

    await signup(email, oldPassword);
    const verifyMail = await fetchMailTo(email);
    const verifyTok = extractToken(verifyMail.Text || verifyMail.HTML);
    await postJson('/v1/auth/password/verify', { token: verifyTok });
    await deleteAllMail();

    const reqRes = await postJson('/v1/auth/password/reset-request', {
      email,
    });
    expect(reqRes.status).toBe(204);

    const resetMail = await fetchMailTo(email);
    expect(resetMail.Subject).toMatch(/reset/i);
    const resetTok = extractToken(resetMail.Text || resetMail.HTML);

    const resetRes = await postJson('/v1/auth/password/reset', {
      token: resetTok,
      new_password: newPassword,
    });
    expect(resetRes.status).toBe(200);

    // Reset bumped the account access-token cutoff (H1): in-flight access
    // JWTs minted before the reset are now rejected by the auth middleware.
    // (The middleware gate itself is exercised in middleware/session.test.ts.)
    const { getIdentityByProviderSub } = await import(
      '../../../src/repositories/identities.js'
    );
    const { getUserById } = await import('../../../src/repositories/users.js');
    const identity = await getIdentityByProviderSub('password', email);
    const user = await getUserById(identity!.user_id);
    expect(user?.tokens_valid_after).toBeTruthy();

    // Old password no longer works.
    const oldLogin = await login(email, oldPassword);
    expect(oldLogin.status).toBe(401);

    // New password does.
    const newLogin = await login(email, newPassword);
    expect(newLogin.status).toBe(200);
  });

  it('reset rejects a verify token (wrong type)', async () => {
    const email = uniqueEmail('cross-type');
    await signup(email, 'correct-horse-battery-staple');
    const mail = await fetchMailTo(email);
    const verifyTok = extractToken(mail.Text || mail.HTML);

    const res = await postJson('/v1/auth/password/reset', {
      token: verifyTok,
      new_password: 'another-good-password-here',
    });
    expect(res.status).toBe(400);
  });

  it('verify rejects a reset token (wrong type)', async () => {
    const email = uniqueEmail('cross-type-2');
    await signup(email, 'correct-horse-battery-staple');
    const verifyMail = await fetchMailTo(email);
    const verifyTok = extractToken(verifyMail.Text || verifyMail.HTML);
    await postJson('/v1/auth/password/verify', { token: verifyTok });
    await deleteAllMail();

    await postJson('/v1/auth/password/reset-request', { email });
    const resetMail = await fetchMailTo(email);
    const resetTok = extractToken(resetMail.Text || resetMail.HTML);

    const res = await postJson('/v1/auth/password/verify', {
      token: resetTok,
    });
    expect(res.status).toBe(400);
  });

  it('resend-verification returns 204 (and sends mail when applicable)', async () => {
    // Unknown email — still 204.
    const ghost = await postJson('/v1/auth/password/resend-verification', {
      email: uniqueEmail('ghost-resend'),
    });
    expect(ghost.status).toBe(204);

    // Real, unverified user — 204 and a new email lands.
    const email = uniqueEmail('resend');
    await signup(email, 'correct-horse-battery-staple');
    await deleteAllMail();
    const res = await postJson('/v1/auth/password/resend-verification', {
      email,
    });
    expect(res.status).toBe(204);
    const mail = await fetchMailTo(email);
    expect(mail.Subject).toMatch(/verify/i);
  });

  it('DELETE last identity is refused', async () => {
    const email = uniqueEmail('lastid');
    const password = 'correct-horse-battery-staple';
    const signupRes = await signup(email, password);
    expect(signupRes.status).toBe(201);
    const verifyMail = await fetchMailTo(email);
    await postJson('/v1/auth/password/verify', {
      token: extractToken(verifyMail.Text || verifyMail.HTML),
    });
    const loginRes = await login(email, password);
    const { access_jwt, user } = (await loginRes.json()) as {
      access_jwt: string;
      user: { user_id: string };
    };

    // Look up the identity_id from the session JWT.
    const { listIdentitiesByUserId } = await import(
      '../../../src/repositories/identities.js'
    );
    const ids = await listIdentitiesByUserId(user.user_id);
    expect(ids).toHaveLength(1);
    const identityId = ids[0].identity_id;

    const res = await app.request(
      `/v1/auth/identities/${identityId}`,
      {
        method: 'DELETE',
        headers: { authorization: `Bearer ${access_jwt}` },
      },
    );
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toMatch(/last sign-in method/i);
  });

  it('DELETE an identity that does not belong to the user returns 404', async () => {
    const email = uniqueEmail('not-mine');
    const password = 'correct-horse-battery-staple';
    await signup(email, password);
    const mail = await fetchMailTo(email);
    await postJson('/v1/auth/password/verify', {
      token: extractToken(mail.Text || mail.HTML),
    });
    const { access_jwt } = (await (
      await login(email, password)
    ).json()) as { access_jwt: string };

    // An identity that belongs to a different (fresh) account.
    const otherEmail = uniqueEmail('other');
    await signup(otherEmail, password);
    const { listIdentitiesByUserId } = await import(
      '../../../src/repositories/identities.js'
    );
    const { getIdentityByProviderSub } = await import(
      '../../../src/repositories/identities.js'
    );
    const otherIdentity = await getIdentityByProviderSub(
      'password',
      otherEmail,
    );
    expect(otherIdentity).not.toBeNull();
    expect(listIdentitiesByUserId).toBeDefined();

    const res = await app.request(
      `/v1/auth/identities/${otherIdentity!.identity_id}`,
      {
        method: 'DELETE',
        headers: { authorization: `Bearer ${access_jwt}` },
      },
    );
    expect(res.status).toBe(404);
  });

  it('link adds a second identity and DELETE then succeeds on the first', async () => {
    const email = uniqueEmail('link-base');
    const password = 'correct-horse-battery-staple';
    await signup(email, password);
    const mail = await fetchMailTo(email);
    await postJson('/v1/auth/password/verify', {
      token: extractToken(mail.Text || mail.HTML),
    });
    const loginRes = await login(email, password);
    const { access_jwt, user } = (await loginRes.json()) as {
      access_jwt: string;
      user: { user_id: string };
    };

    const secondEmail = uniqueEmail('link-second');
    const linkRes = await postJson(
      '/v1/auth/link',
      {
        provider: 'password',
        email: secondEmail,
        password,
      },
      { authorization: `Bearer ${access_jwt}` },
    );
    expect(linkRes.status).toBe(201);
    const linkBody = (await linkRes.json()) as {
      identity_id: string;
      provider: string;
      email: string;
    };
    expect(linkBody.provider).toBe('password');
    expect(linkBody.email).toBe(secondEmail);

    // Now there are two identities — deleting the first one succeeds.
    const { listIdentitiesByUserId } = await import(
      '../../../src/repositories/identities.js'
    );
    const all = await listIdentitiesByUserId(user.user_id);
    expect(all).toHaveLength(2);
    const first = all.find((i) => i.email === email);
    expect(first).toBeDefined();

    const delRes = await app.request(
      `/v1/auth/identities/${first!.identity_id}`,
      {
        method: 'DELETE',
        headers: { authorization: `Bearer ${access_jwt}` },
      },
    );
    expect(delRes.status).toBe(204);

    // And the second delete (now the last) is refused.
    const lastDel = await app.request(
      `/v1/auth/identities/${linkBody.identity_id}`,
      {
        method: 'DELETE',
        headers: { authorization: `Bearer ${access_jwt}` },
      },
    );
    expect(lastDel.status).toBe(400);
  });

  it('link refuses a collision with an existing password identity', async () => {
    const email = uniqueEmail('link-coll-1');
    const password = 'correct-horse-battery-staple';
    await signup(email, password);
    const mail = await fetchMailTo(email);
    await postJson('/v1/auth/password/verify', {
      token: extractToken(mail.Text || mail.HTML),
    });
    const { access_jwt } = (await (
      await login(email, password)
    ).json()) as { access_jwt: string };

    // Someone else already owns this email.
    const otherEmail = uniqueEmail('link-coll-2');
    await signup(otherEmail, password);

    const res = await postJson(
      '/v1/auth/link',
      { provider: 'password', email: otherEmail, password },
      { authorization: `Bearer ${access_jwt}` },
    );
    expect(res.status).toBe(409);
  });

  it('link requires a session', async () => {
    const res = await postJson('/v1/auth/link', {
      provider: 'password',
      email: uniqueEmail('no-sess'),
      password: 'correct-horse-battery-staple',
    });
    expect(res.status).toBe(401);
  });

  // ── L3: unverified login surfaces only via resend, never via login ──

  it('login for an unverified account returns uniform 401 (no 403 oracle); resend still works', async () => {
    const email = uniqueEmail('unverified');
    const password = 'correct-horse-battery-staple';
    await signup(email, password);

    const res = await login(email, password);
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: string; resend_url?: string };
    expect(body.error).toBe('Invalid credentials');
    // The response must NOT hint that the email is merely unverified, nor
    // expose a resend_url — that would confirm the password is correct.
    expect(body.resend_url).toBeUndefined();
    expect(JSON.stringify(body)).not.toMatch(/verif/i);

    // The unverified user still learns their state through the
    // password-less resend-verification flow.
    await deleteAllMail();
    const resend = await postJson('/v1/auth/password/resend-verification', {
      email,
    });
    expect(resend.status).toBe(204);
    const mail = await fetchMailTo(email);
    expect(mail.Subject).toMatch(/verify/i);
  });

  // ── H1: reset revokes all sessions/refresh tokens ──

  it('reset revokes every existing refresh token for the account (H1)', async () => {
    const email = uniqueEmail('reset-revoke');
    const oldPassword = 'correct-horse-battery-staple';
    const newPassword = 'a-brand-new-passphrase-here';

    await signup(email, oldPassword);
    const verifyMail = await fetchMailTo(email);
    await postJson('/v1/auth/password/verify', {
      token: extractToken(verifyMail.Text || verifyMail.HTML),
    });

    // Establish an active session (refresh token) — the "attacker's"
    // foothold that a reset must evict.
    const loginRes = await login(email, oldPassword);
    const { refresh_token } = (await loginRes.json()) as {
      refresh_token: string;
    };
    // Sanity: the refresh token works before reset.
    const beforeReset = await app.request('/v1/auth/refresh', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ refresh_token }),
    });
    expect(beforeReset.status).toBe(200);
    const rotated = (await beforeReset.json()) as { refresh_token: string };

    // Reset the password.
    await deleteAllMail();
    await postJson('/v1/auth/password/reset-request', { email });
    const resetMail = await fetchMailTo(email);
    const resetTok = extractToken(resetMail.Text || resetMail.HTML);
    const resetRes = await postJson('/v1/auth/password/reset', {
      token: resetTok,
      new_password: newPassword,
    });
    expect(resetRes.status).toBe(200);

    // The previously-rotated refresh token must now be dead — the reset
    // cascaded revokeAllForUser, so the attacker's foothold is gone.
    const afterReset = await app.request('/v1/auth/refresh', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ refresh_token: rotated.refresh_token }),
    });
    expect(afterReset.status).toBe(401);
  });

  // ── L1: reset token is single-use (replay rejected after the change) ──

  it('reset token cannot be replayed after the password has changed (L1)', async () => {
    const email = uniqueEmail('reset-replay');
    const oldPassword = 'correct-horse-battery-staple';
    const firstNew = 'first-new-passphrase-aaa';
    const secondNew = 'second-new-passphrase-bbb';

    await signup(email, oldPassword);
    const verifyMail = await fetchMailTo(email);
    await postJson('/v1/auth/password/verify', {
      token: extractToken(verifyMail.Text || verifyMail.HTML),
    });

    await deleteAllMail();
    await postJson('/v1/auth/password/reset-request', { email });
    const resetMail = await fetchMailTo(email);
    const resetTok = extractToken(resetMail.Text || resetMail.HTML);

    // Reset-token iat has 1s granularity; the single-use gate rejects a
    // token issued in a strictly earlier second than the stamped
    // password_updated_at. Sleep just over 1s so the reset lands in a
    // later second than the token was issued, making the replay
    // deterministically detectable.
    await new Promise((r) => setTimeout(r, 1100));

    const first = await postJson('/v1/auth/password/reset', {
      token: resetTok,
      new_password: firstNew,
    });
    expect(first.status).toBe(200);

    // Replaying the SAME token must now fail — even though the JWT itself
    // is still within its 1h validity.
    const replay = await postJson('/v1/auth/password/reset', {
      token: resetTok,
      new_password: secondNew,
    });
    expect(replay.status).toBe(400);

    // And the attacker's chosen password never took effect: only the
    // legitimate first reset password works.
    expect((await login(email, firstNew)).status).toBe(200);
    expect((await login(email, secondNew)).status).toBe(401);
  });

  // ── M2: httpOnly refresh cookie on login ──

  it('login sets an httpOnly lmwf_refresh cookie scoped to /v1/auth (M2)', async () => {
    const email = uniqueEmail('cookie-login');
    const password = 'correct-horse-battery-staple';
    await signup(email, password);
    const mail = await fetchMailTo(email);
    await postJson('/v1/auth/password/verify', {
      token: extractToken(mail.Text || mail.HTML),
    });

    const res = await login(email, password);
    expect(res.status).toBe(200);
    const setCookie = res.headers.get('set-cookie') ?? '';
    expect(setCookie).toMatch(/lmwf_refresh=lm_refresh_[A-Za-z0-9_-]{32}/);
    expect(setCookie).toMatch(/HttpOnly/i);
    expect(setCookie).toMatch(/Secure/i);
    expect(setCookie).toMatch(/SameSite=Strict/i);
    expect(setCookie).toMatch(/Path=\/v1\/auth/i);
    expect(setCookie).toMatch(/Max-Age=\d+/i);

    // The cookie value matches the JSON body token (one credential, two
    // delivery channels).
    const body = (await res.json()) as { refresh_token: string };
    expect(setCookie).toContain(`lmwf_refresh=${body.refresh_token}`);
  });
});

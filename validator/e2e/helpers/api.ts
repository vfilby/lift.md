/**
 * Thin wrappers over the validator HTTP API for fixture seeding.
 *
 * Tests should prefer driving the UI for behavior they want to assert.
 * These helpers are for steps that are NOT what the test is testing —
 * e.g. "given an already-verified user, when they log in, then …" gets
 * the verified-user state via signupAndVerify() so the test body can
 * focus on the login step.
 */
import { getBaseUrl, getTestSecret } from './env.js';
import { getLatestToken } from './tokens.js';

const STRONG_PASSWORD = 'correct horse battery staple';

export interface VerifiedUser {
  email: string;
  password: string;
  displayName: string;
  userId: string;
}

export interface SeededUser {
  email: string;
  password: string;
  userId: string;
  identityId: string;
  tier: 'pro' | 'trial' | 'free';
  sessionJwt: string;
}

/**
 * Fast path: create a verified user via /v1/__test__/seed-user. Use
 * this for tests that aren't exercising the signup → verify UI.
 */
export async function seedUser(opts: {
  email: string;
  password?: string;
  tier?: 'pro' | 'trial' | 'free';
}): Promise<SeededUser> {
  const password = opts.password ?? STRONG_PASSWORD;
  const res = await fetch(`${getBaseUrl()}/v1/__test__/seed-user`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-test-secret': getTestSecret(),
    },
    body: JSON.stringify({
      email: opts.email,
      password,
      tier: opts.tier ?? 'trial',
      display_name: `E2E ${opts.email}`,
    }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`seed-user failed (${res.status}): ${text}`);
  }
  const json = (await res.json()) as {
    user_id: string;
    identity_id: string;
    email: string;
    tier: 'pro' | 'trial' | 'free';
    session_jwt: string;
  };
  return {
    email: json.email,
    password,
    userId: json.user_id,
    identityId: json.identity_id,
    tier: json.tier,
    sessionJwt: json.session_jwt,
  };
}

export async function createPat(opts: {
  sessionJwt: string;
  name: string;
}): Promise<{ token_id: string; plaintext: string }> {
  const res = await fetch(`${getBaseUrl()}/v1/tokens`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${opts.sessionJwt}`,
    },
    body: JSON.stringify({ name: opts.name }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`PAT create failed (${res.status}): ${text}`);
  }
  return (await res.json()) as { token_id: string; plaintext: string };
}

/**
 * Revoke a PAT via the session-authed `DELETE /v1/tokens/:token_id`
 * (idempotent 204). Mirrors the per-row revoke the dashboard drives, but
 * at the API layer so a topology test can assert the deployed authorizer
 * stops honouring the token immediately after.
 */
export async function revokePat(opts: {
  sessionJwt: string;
  tokenId: string;
}): Promise<void> {
  const res = await fetch(`${getBaseUrl()}/v1/tokens/${opts.tokenId}`, {
    method: 'DELETE',
    headers: { authorization: `Bearer ${opts.sessionJwt}` },
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`PAT revoke failed (${res.status}): ${text}`);
  }
}

export async function signupAndVerify(opts: {
  email: string;
  password?: string;
  displayName?: string;
}): Promise<VerifiedUser> {
  const password = opts.password ?? STRONG_PASSWORD;
  const displayName = opts.displayName ?? 'E2E Test User';

  const signupRes = await fetch(`${getBaseUrl()}/v1/auth/password/signup`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: opts.email,
      password,
      display_name: displayName,
    }),
  });
  if (!signupRes.ok) {
    const text = await signupRes.text().catch(() => '');
    throw new Error(`signup failed (${signupRes.status}): ${text}`);
  }
  const { user_id } = (await signupRes.json()) as { user_id: string };

  const token = await getLatestToken(opts.email, 'email_verify');
  const verifyRes = await fetch(`${getBaseUrl()}/v1/auth/password/verify`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token }),
  });
  if (!verifyRes.ok) {
    const text = await verifyRes.text().catch(() => '');
    throw new Error(`verify failed (${verifyRes.status}): ${text}`);
  }

  return { email: opts.email, password, displayName, userId: user_id };
}

/**
 * Drive the real `POST /v1/auth/password/login` and return the parsed
 * response — both the JSON body fields AND the raw `Set-Cookie` header so
 * cookie-attribute (topology) tests can inspect it.
 *
 * NOTE: this endpoint returns `access_jwt` (NOT `session_jwt`). The earlier
 * version of this helper destructured `session_jwt`, which is always
 * `undefined` on this route — that field only exists on the test-only
 * `/v1/__test__/seed-user` backdoor (see seedUser). We expose the access
 * JWT to callers as `accessJwt`, with a `sessionJwt` alias so call sites
 * can read whichever name reads best in context.
 */
export async function login(opts: {
  email: string;
  password?: string;
}): Promise<{
  accessJwt: string;
  sessionJwt: string;
  refreshToken: string;
  setCookie: string | null;
}> {
  const res = await fetch(`${getBaseUrl()}/v1/auth/password/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: opts.email,
      // Default to the shared test password (mirrors seedUser /
      // signupAndVerify) so callers can `login({ email })` after a
      // default-password seedUser without restating the literal.
      password: opts.password ?? STRONG_PASSWORD,
      device_label: 'e2e',
    }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`login failed (${res.status}): ${text}`);
  }
  const setCookie = res.headers.get('set-cookie');
  const json = (await res.json()) as {
    access_jwt: string;
    refresh_token: string;
  };
  return {
    accessJwt: json.access_jwt,
    sessionJwt: json.access_jwt,
    refreshToken: json.refresh_token,
    setCookie,
  };
}

/**
 * Hard-delete any user matching this email (and all their related rows)
 * via /v1/__test__/delete-user-by-email. No-op when the user doesn't
 * exist. Used to make signup tests rerunnable when SES sandbox forces
 * us to reuse a verified address.
 */
export async function deleteTestUser(email: string): Promise<void> {
  const res = await fetch(`${getBaseUrl()}/v1/__test__/delete-user-by-email`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-test-secret': getTestSecret(),
    },
    body: JSON.stringify({ email }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`delete-user-by-email failed (${res.status}): ${text}`);
  }
}

export async function seedOutboxItem(opts: {
  userId: string;
  sessionName?: string;
}): Promise<{ outbox_id: string }> {
  const res = await fetch(`${getBaseUrl()}/v1/__test__/seed-outbox-item`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-test-secret': getTestSecret(),
    },
    body: JSON.stringify({
      user_id: opts.userId,
      session_name: opts.sessionName,
    }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`seed-outbox-item failed (${res.status}): ${text}`);
  }
  return (await res.json()) as { outbox_id: string };
}

/**
 * Establish a logged-in dashboard session for the seeded user.
 *
 * The dashboard no longer stores tokens in localStorage — the access JWT
 * lives in memory and the refresh token is an httpOnly cookie the API sets
 * on login (see website/src/scripts/api.js). There is therefore no token to
 * inject; we drive the real login form once. The httpOnly refresh cookie it
 * sets is what lets subsequent navigations re-mint the access JWT via the
 * page's ensureSession() bootstrap.
 */
export async function setBrowserSession(
  page: import('@playwright/test').Page,
  user: SeededUser,
): Promise<void> {
  await page.goto('/account/login');
  await page.locator('#email').fill(user.email);
  await page.locator('#password').fill(user.password);
  await Promise.all([
    page.waitForURL('**/account/'),
    page.locator('#submit-btn').click(),
  ]);
}

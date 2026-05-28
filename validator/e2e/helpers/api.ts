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

export async function login(opts: {
  email: string;
  password: string;
}): Promise<{ session_jwt: string; refresh_token: string }> {
  const res = await fetch(`${getBaseUrl()}/v1/auth/password/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: opts.email,
      password: opts.password,
      device_label: 'e2e',
    }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`login failed (${res.status}): ${text}`);
  }
  return (await res.json()) as {
    session_jwt: string;
    refresh_token: string;
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
 * Inject the seeded user's tokens into localStorage on the active page
 * so the dashboard treats it as a returning logged-in session — no UI
 * login required. The page must already be on the same origin as the
 * validator (i.e. baseURL).
 */
export async function setBrowserSession(
  page: import('@playwright/test').Page,
  user: SeededUser,
): Promise<void> {
  // Must be on the target origin before localStorage writes apply to it.
  await page.goto('/');
  await page.evaluate(
    ({ jwt, userId, email }) => {
      localStorage.setItem('lmwf_access_jwt', jwt);
      localStorage.setItem(
        'lmwf_user',
        JSON.stringify({ user_id: userId, email, display_name: email }),
      );
    },
    { jwt: user.sessionJwt, userId: user.userId, email: user.email },
  );
}

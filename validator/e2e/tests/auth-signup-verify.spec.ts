import { expect, test } from '@playwright/test';
import { deleteTestUser } from '../helpers/api.js';
import {
  expectedEmailLinkHost,
  getMode,
  signupTestEmail,
  uniqueEmail,
} from '../helpers/env.js';
import { getLatestEmailLink, getLatestToken } from '../helpers/tokens.js';

test('full signup → email verify flow', async ({ page, request }) => {
  const email = signupTestEmail();
  const password = 'correct horse battery staple';

  // In remote mode `email` is a single verified-in-SES address that
  // gets reused across runs; wipe any leftover user from a prior run so
  // the signup endpoint doesn't 409. No-op when the user doesn't exist.
  await deleteTestUser(email);

  await page.goto('/account/signup');

  await page.locator('#display_name').fill('E2E Signup');
  await page.locator('#email').fill(email);
  await page.locator('#password').fill(password);
  await page.locator('#password_confirm').fill(password);

  // The signup POST returning 201 is itself a topology assertion (test (d)
  // in spec/services/validator-e2e.md): the email send is the LAST step
  // before the 201 and the handler ROLLS BACK + returns 503 if the send
  // throws (password.ts:282-325). So in remote/beta mode a 201 for the
  // SES-verified address proves SES credentials resolve on the deployed
  // stack — it cannot be reached if SES rejects with placeholder creds (the
  // #137 SES-placeholder class). No separate signup POST is needed; this is
  // the existing real send, now asserted. (Beta SES only — the prod-side
  // SES-creds check remains a separate concern; see spec.)
  await Promise.all([
    page.waitForResponse(
      (r) => r.url().endsWith('/v1/auth/password/signup') && r.status() === 201,
    ),
    page.locator('#submit-btn').click(),
  ]);

  // Form swaps to the "Check your email" state.
  await expect(page.locator('#success-state')).toBeVisible();
  await expect(page.locator('#sent-email')).toHaveText(email);

  // Topology assertion (b): the verification link host must match the env's
  // appBaseUrl. A misconfigured LMWF_ENV on the Lambda builds links for the
  // wrong host (the #137 reset-link-misrouting class). Only assertable where
  // we can read the email body = local/Mailpit mode (which still gates prod
  // via e2e-local). Remote mode mints the token directly, so there is no
  // email body to read — skip cleanly there.
  if (getMode() === 'local') {
    const link = await getLatestEmailLink(email, 'email_verify');
    expect(new URL(link).host).toBe(expectedEmailLinkHost());
  }

  // Pull the token (Mailpit local / mint-token remote) and verify it via
  // the same JSON endpoint the email link's GET redirector hits. Goes
  // through the real verify code path, not a back-door.
  const token = await getLatestToken(email, 'email_verify');
  const verifyRes = await request.post('/v1/auth/password/verify', {
    headers: { 'content-type': 'application/json' },
    data: { token },
  });
  expect(verifyRes.status()).toBe(200);

  // After verify, the identity is email_verified — login should now work.
  const loginRes = await request.post('/v1/auth/password/login', {
    headers: { 'content-type': 'application/json' },
    data: { email, password, device_label: 'e2e' },
  });
  expect(loginRes.status()).toBe(200);
  const loginBody = (await loginRes.json()) as {
    access_jwt: string;
    refresh_token: string;
  };
  expect(loginBody.access_jwt).toBeTruthy();
  expect(loginBody.refresh_token).toBeTruthy();
});

test('signup rejects mismatched password confirmation client-side', async ({
  page,
}) => {
  await page.goto('/account/signup');
  await page.locator('#display_name').fill('E2E Mismatch');
  await page.locator('#email').fill(uniqueEmail('mismatch'));
  await page.locator('#password').fill('correct horse battery staple');
  await page.locator('#password_confirm').fill('wrong horse battery staple');
  await page.locator('#submit-btn').click();
  await expect(
    page.locator('#signup-msg .inline-msg.err'),
  ).toContainText(/match/i);
});

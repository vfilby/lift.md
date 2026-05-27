import { expect, test } from '@playwright/test';
import { uniqueEmail } from '../helpers/env.js';
import { getLatestToken } from '../helpers/tokens.js';

test('full signup → email verify flow', async ({ page, request }) => {
  const email = uniqueEmail('signup');
  const password = 'correct horse battery staple';

  await page.goto('/account/signup');

  await page.locator('#display_name').fill('E2E Signup');
  await page.locator('#email').fill(email);
  await page.locator('#password').fill(password);
  await page.locator('#password_confirm').fill(password);

  await Promise.all([
    page.waitForResponse(
      (r) => r.url().endsWith('/v1/auth/password/signup') && r.status() === 201,
    ),
    page.locator('#submit-btn').click(),
  ]);

  // Form swaps to the "Check your email" state.
  await expect(page.locator('#success-state')).toBeVisible();
  await expect(page.locator('#sent-email')).toHaveText(email);

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

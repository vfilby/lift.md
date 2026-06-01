import { expect, test } from '@playwright/test';
import { seedUser } from '../helpers/api.js';
import { expectedEmailLinkHost, getMode, uniqueEmail } from '../helpers/env.js';
import { getLatestEmailLink, getLatestToken } from '../helpers/tokens.js';

test('forgot → reset → login with new password', async ({ page, request }) => {
  const email = uniqueEmail('reset');
  const oldPassword = 'correct horse battery staple';
  const newPassword = 'totally different new password';
  await seedUser({ email, password: oldPassword });

  // Request a reset link.
  await page.goto('/account/forgot');
  await page.locator('#email').fill(email);
  await page.locator('#submit-btn').click();
  await expect(page.locator('#forgot-msg .inline-msg.ok')).toBeVisible();

  // Topology assertion (b): the reset link host must match the env's
  // appBaseUrl. This is the exact #137 reset-misrouting class — a Lambda
  // with the wrong LMWF_ENV emails a link pointing at the wrong host, so
  // the user lands on the wrong environment's reset page. Only assertable
  // where the email body is readable = local/Mailpit mode (gates prod via
  // e2e-local). Remote mode mints the token directly with no email to read.
  if (getMode() === 'local') {
    const link = await getLatestEmailLink(email, 'password_reset');
    const url = new URL(link);
    expect(url.host).toBe(expectedEmailLinkHost());
    // The reset link must target the website page, not the POST-only API
    // route (a GET on /v1/auth/password/reset would 405).
    expect(url.pathname).toBe('/account/reset');
  }

  // Pull the reset token and land on /account/reset?token=...
  const token = await getLatestToken(email, 'password_reset');
  await page.goto(`/account/reset?token=${encodeURIComponent(token)}`);
  await expect(page.locator('#reset-form')).toBeVisible();

  await page.locator('#password').fill(newPassword);
  await page.locator('#password_confirm').fill(newPassword);
  await page.locator('#submit-btn').click();

  await expect(page.locator('#reset-msg .inline-msg.ok')).toContainText(
    /Password updated/i,
  );

  // Old password no longer works; new one does.
  const oldRes = await request.post('/v1/auth/password/login', {
    headers: { 'content-type': 'application/json' },
    data: { email, password: oldPassword, device_label: 'e2e' },
  });
  expect(oldRes.status()).toBe(401);
  const newRes = await request.post('/v1/auth/password/login', {
    headers: { 'content-type': 'application/json' },
    data: { email, password: newPassword, device_label: 'e2e' },
  });
  expect(newRes.status()).toBe(200);
});

test('/account/reset with no token shows the missing-token state', async ({
  page,
}) => {
  await page.goto('/account/reset');
  await expect(page.locator('#no-token')).toBeVisible();
  // The form keeps its `hidden` HTML attribute set when no token is
  // present. Assert directly on the attribute rather than visibility —
  // some browsers report the hidden-attr form as having layout in the
  // accessibility tree even though it's display:none.
  await expect(page.locator('#reset-form')).toHaveAttribute('hidden', '');
});

test('forgot endpoint always reports the same success (anti-enumeration)', async ({
  page,
}) => {
  await page.goto('/account/forgot');
  await page.locator('#email').fill('never-existed@example.com');
  await page.locator('#submit-btn').click();
  // The UI shows the same success message whether or not the address exists.
  await expect(page.locator('#forgot-msg .inline-msg.ok')).toBeVisible();
});

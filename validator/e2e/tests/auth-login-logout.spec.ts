import { expect, test } from '@playwright/test';
import { seedUser } from '../helpers/api.js';
import { uniqueEmail } from '../helpers/env.js';

test('login → dashboard → sign out', async ({ page }) => {
  const email = uniqueEmail('login');
  const password = 'correct horse battery staple';
  await seedUser({ email, password });

  await page.goto('/account/login');
  await page.locator('#email').fill(email);
  await page.locator('#password').fill(password);
  await Promise.all([
    page.waitForURL('**/account/'),
    page.locator('#submit-btn').click(),
  ]);

  // Dashboard rendered with the seeded user's email visible.
  await expect(page.locator('#user-email')).toHaveText(email);

  // Sign out clears the session and bounces to /account/login on next request.
  await page.locator('#signout-btn').click();
  await page.waitForURL('**/account/login');
  // localStorage should be cleared.
  const jwt = await page.evaluate(() => localStorage.getItem('lmwf_access_jwt'));
  expect(jwt).toBeNull();
});

test('login with wrong password shows "Invalid credentials"', async ({
  page,
}) => {
  const email = uniqueEmail('bad-creds');
  await seedUser({ email, password: 'correct horse battery staple' });

  await page.goto('/account/login');
  await page.locator('#email').fill(email);
  await page.locator('#password').fill('wrong horse battery staple');
  await page.locator('#submit-btn').click();

  await expect(page.locator('#login-msg .inline-msg.err')).toContainText(
    /invalid/i,
  );
  expect(page.url()).toContain('/account/login');
});

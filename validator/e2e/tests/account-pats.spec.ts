import { expect, test } from '@playwright/test';
import { seedUser, setBrowserSession } from '../helpers/api.js';
import { uniqueEmail } from '../helpers/env.js';

test('create + revoke a personal access token', async ({ page }) => {
  const user = await seedUser({ email: uniqueEmail('pat'), tier: 'trial' });
  await setBrowserSession(page, user);

  await page.goto('/account/');
  await expect(page.locator('#user-email')).toHaveText(user.email);

  await page.locator('#new-token-btn').click();
  const tokenName = `e2e-pat-${Date.now()}`;
  await page.locator('#tok-name').fill(tokenName);
  await page.locator('#new-token-form button[type=submit]').click();

  // Plaintext block surfaces once after create.
  await expect(page.locator('#token-plaintext')).toContainText(/lm_pat_/);
  // Token row shows up in the table.
  await expect(
    page.locator('#tokens-wrap').getByText(tokenName, { exact: true }),
  ).toBeVisible();

  // Revoke via the per-row button. Stub window.confirm so the test doesn't
  // hang on the native dialog.
  await page.evaluate(() => {
    (window as unknown as { confirm: () => boolean }).confirm = () => true;
  });
  const revokeBtn = page
    .locator('#tokens-wrap tr', { hasText: tokenName })
    .locator('[data-revoke]');
  await revokeBtn.click();

  await expect(
    page
      .locator('#tokens-wrap tr', { hasText: tokenName })
      .locator('.badge'),
  ).toContainText(/Revoked/i);
});

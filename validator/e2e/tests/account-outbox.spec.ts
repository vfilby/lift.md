import { expect, test } from '@playwright/test';
import { seedOutboxItem, seedUser, setBrowserSession } from '../helpers/api.js';
import { uniqueEmail } from '../helpers/env.js';

test('outbox list shows seeded workout; detail page renders it', async ({
  page,
}) => {
  const user = await seedUser({ email: uniqueEmail('outbox'), tier: 'trial' });
  const sessionName = `E2E Session ${Date.now()}`;
  const { outbox_id } = await seedOutboxItem({
    userId: user.userId,
    sessionName,
  });
  await setBrowserSession(page, user);

  await page.goto('/account/outbox');
  await expect(page.locator('#outbox-wrap')).toBeVisible();
  const row = page.locator('#outbox-wrap').getByText(sessionName, {
    exact: false,
  });
  await expect(row).toBeVisible();

  // Detail page.
  await page.goto(`/account/outbox/view?id=${encodeURIComponent(outbox_id)}`);
  await expect(page.locator('#session-name')).toContainText(sessionName);
});

import { expect, test } from '@playwright/test';

test.describe('Marketing landing page', () => {
  test('renders the brand hero and the CTA to /format', async ({ page }) => {
    const consoleErrors: string[] = [];
    page.on('pageerror', (err) => consoleErrors.push(String(err)));
    page.on('console', (msg) => {
      if (msg.type() === 'error') consoleErrors.push(msg.text());
    });

    await page.goto('/');

    // Brand hero headline.
    await expect(
      page.getByRole('heading', {
        level: 1,
        name: /own your training/i,
      }),
    ).toBeVisible();

    // CTA that routes to the format hub (the format content moved off home).
    await expect(
      page.getByRole('link', { name: /explore the format/i }),
    ).toBeVisible();

    // The marketing landing must NOT carry the format examples anymore —
    // those live on /format.
    await expect(page.locator('pre code')).toHaveCount(0);

    // No format/validator widget on home.
    await expect(page.locator('#validator-form')).toHaveCount(0);

    // No JS errors on first paint.
    expect(consoleErrors, consoleErrors.join('\n')).toEqual([]);
  });
});

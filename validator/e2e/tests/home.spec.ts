import { expect, test } from '@playwright/test';

test.describe('Marketing landing page', () => {
  test('renders the brand hero and the CTA to /format', async ({ page }) => {
    const consoleErrors: string[] = [];
    page.on('pageerror', (err) => consoleErrors.push(String(err)));
    page.on('console', (msg) => {
      if (msg.type() === 'error') consoleErrors.push(msg.text());
    });

    await page.goto('/');

    // Brand hero tagline.
    await expect(
      page.getByText(/track your workouts with simple, markdown-based workout plans/i),
    ).toBeVisible();

    // CTA that routes to the format hub (the format content moved off home).
    // The page carries more than one "Explore the format" link now (a pillar
    // CTA and the button below the pillars), so assert at least one is visible
    // and that every match points at /format.
    const formatCtas = page.getByRole('link', { name: /explore the format/i });
    await expect(formatCtas.first()).toBeVisible();
    for (const cta of await formatCtas.all()) {
      await expect(cta).toHaveAttribute('href', '/format');
    }

    // The marketing landing must NOT carry the format examples anymore —
    // those live on /format.
    await expect(page.locator('pre code')).toHaveCount(0);

    // No format/validator widget on home.
    await expect(page.locator('#validator-form')).toHaveCount(0);

    // No JS errors on first paint.
    expect(consoleErrors, consoleErrors.join('\n')).toEqual([]);
  });
});

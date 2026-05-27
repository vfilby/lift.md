import { expect, test } from '@playwright/test';

test.describe('LMWF landing page', () => {
  test('renders title, both example blocks, and links to /spec', async ({
    page,
  }) => {
    const consoleErrors: string[] = [];
    page.on('pageerror', (err) => consoleErrors.push(String(err)));
    page.on('console', (msg) => {
      if (msg.type() === 'error') consoleErrors.push(msg.text());
    });

    await page.goto('/');

    await expect(
      page.getByRole('heading', { level: 1, name: /LiftMark Workout Format/i }),
    ).toBeVisible();

    // Both the minimal and rich example markdown blocks should be on the page.
    const codeBlocks = page.locator('pre code');
    await expect(codeBlocks.first()).toContainText('# Bench Day');
    await expect(codeBlocks.nth(1)).toContainText('# Push Day');

    // No JS errors on first paint.
    expect(consoleErrors, consoleErrors.join('\n')).toEqual([]);
  });
});

import { expect, test } from '@playwright/test';

test.describe('Format hub (/format)', () => {
  test('renders the pitch, both example blocks, the validator, and links to the spec', async ({
    page,
  }) => {
    const consoleErrors: string[] = [];
    page.on('pageerror', (err) => consoleErrors.push(String(err)));
    page.on('console', (msg) => {
      if (msg.type() === 'error') consoleErrors.push(msg.text());
    });

    await page.goto('/format');

    // Both the minimal and rich example markdown blocks moved here from `/`.
    const codeBlocks = page.locator('pre code');
    await expect(codeBlocks.first()).toContainText('# Bench Day');
    await expect(codeBlocks.nth(1)).toContainText('# Push Day');

    // The live validator widget lives on the format hub now.
    await expect(page.locator('#validator-form')).toBeVisible();
    await expect(page.locator('#markdown')).toBeVisible();

    // Links to the full spec under /format/spec.
    await expect(
      page.getByRole('link', { name: /full specification/i }),
    ).toHaveAttribute('href', '/format/spec');

    expect(consoleErrors, consoleErrors.join('\n')).toEqual([]);
  });

  test('validator validates the prefilled example against the live API', async ({
    page,
  }) => {
    await page.goto('/format');
    // The textarea is prefilled with the rich example, which is valid LMWF.
    await Promise.all([
      page.waitForResponse(
        (r) =>
          r.url().endsWith('/validate') &&
          r.request().method() === 'POST',
      ),
      page.locator('#validate-btn').click(),
    ]);
    await expect(page.locator('#validator-result .result.ok')).toBeVisible();
  });
});

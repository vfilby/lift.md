import { expect, test } from '@playwright/test';

test('/spec renders the LMWF specification', async ({ page }) => {
  await page.goto('/spec');
  await expect(
    page.getByRole('heading', { name: /LiftMark Workout Format/i }).first(),
  ).toBeVisible();
  // Markdown view served at /spec.md should resolve too — used by LLM agents.
  // Content-type is set by the static-asset origin (CloudFront/S3 in prod,
  // node-server in local mode) and varies; assert on body shape instead.
  const specMd = await page.request.get('/spec.md');
  expect(specMd.ok()).toBeTruthy();
  const body = await specMd.text();
  expect(body).toMatch(/^# /);
});

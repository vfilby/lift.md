import { expect, test } from '@playwright/test';

test('/format/spec renders the LiftMark Format specification', async ({
  page,
}) => {
  await page.goto('/format/spec');
  await expect(
    page.getByRole('heading', { name: /LiftMark Workout Format/i }).first(),
  ).toBeVisible();
  // Markdown view served at /spec.md should resolve too — used by LLM agents.
  // Stays at the root path for stable agent/tooling references.
  // Content-type is set by the static-asset origin (CloudFront/S3 in prod,
  // node-server in local mode) and varies; assert on body shape instead.
  const specMd = await page.request.get('/spec.md');
  expect(specMd.ok()).toBeTruthy();
  const body = await specMd.text();
  expect(body).toMatch(/^# /);
});

test('/spec redirects to /format/spec', async ({ page }) => {
  // Astro emits a meta-refresh redirect page in the static build. Landing on
  // /spec must end up on the spec under the new IA.
  await page.goto('/spec');
  await page.waitForURL('**/format/spec');
  await expect(
    page.getByRole('heading', { name: /LiftMark Workout Format/i }).first(),
  ).toBeVisible();
});

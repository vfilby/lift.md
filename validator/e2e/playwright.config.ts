import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright config for the validator E2E suite.
 *
 * Modes (env LMWF_E2E_MODE):
 *   - local  → baseURL http://localhost:3001 (validator with WEBSITE_DIST,
 *              DDB Local, Mailpit). Pre-merge in CI + local dev.
 *   - remote → baseURL https://beta.liftmark.app, uses /v1/__test__
 *              endpoint for token mint. Post-Beta-deploy gate.
 *
 * Override baseURL via LMWF_E2E_BASE_URL if needed (e.g. for ad-hoc
 * pointing at a different env).
 *
 * See spec/services/validator-e2e.md for the suite's contract.
 */
const mode = (process.env.LMWF_E2E_MODE ?? 'local') as 'local' | 'remote';
const defaultBaseUrl =
  mode === 'remote' ? 'https://beta.liftmark.app' : 'http://localhost:3001';
const baseURL = process.env.LMWF_E2E_BASE_URL ?? defaultBaseUrl;

const isCI = Boolean(process.env.CI);

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: isCI,
  // 0 locally so devs see flakes immediately; 1 on CI to absorb network
  // blips against beta CloudFront. Anything that needs >1 retry is
  // quarantined per the reliability budget in the spec.
  retries: isCI ? 1 : 0,
  workers: isCI ? 4 : undefined,
  reporter: isCI
    ? [['github'], ['html', { open: 'never' }]]
    : [['list'], ['html', { open: 'never' }]],
  timeout: 30_000,
  expect: { timeout: 5_000 },
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: isCI ? 'retain-on-failure' : 'off',
    actionTimeout: 10_000,
    navigationTimeout: 15_000,
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});

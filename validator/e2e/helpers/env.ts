/**
 * Mode + URL resolution for the E2E suite.
 *
 * One source of truth so tests + fixtures don't drift apart from
 * playwright.config.ts.
 */
export type E2EMode = 'local' | 'remote';

export function getMode(): E2EMode {
  const raw = process.env.LMWF_E2E_MODE ?? 'local';
  if (raw !== 'local' && raw !== 'remote') {
    throw new Error(
      `Invalid LMWF_E2E_MODE: ${raw}. Expected 'local' or 'remote'.`,
    );
  }
  return raw;
}

export function getBaseUrl(): string {
  const explicit = process.env.LMWF_E2E_BASE_URL;
  if (explicit) return explicit.replace(/\/$/, '');
  return getMode() === 'remote'
    ? 'https://beta.liftmark.app'
    : 'http://localhost:3001';
}

export function getTestSecret(): string {
  const s = process.env.LMWF_E2E_TEST_SECRET;
  if (!s) {
    throw new Error(
      "LMWF_E2E_TEST_SECRET is not set. In 'remote' mode this is required to mint verify/reset tokens. In 'local' mode it must match the validator's E2E_TEST_SECRET.",
    );
  }
  return s;
}

export function getMailpitUrl(): string {
  return process.env.LMWF_E2E_MAILPIT_URL ?? 'http://localhost:8025';
}

/**
 * Each test run uses a unique email prefix so reruns + parallel workers
 * don't collide on the (provider, provider_sub) uniqueness check in
 * createIdentity.
 */
export function uniqueEmail(label: string): string {
  return `e2e-${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
}

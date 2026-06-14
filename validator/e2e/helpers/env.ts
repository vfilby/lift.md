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
    ? 'https://beta.getlift.md'
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
 * Host that transactional-email links MUST point at, derived the same way
 * the server derives it (password.ts:appBaseUrl → LMWF_ENV). Used by the
 * "email link host == env appBaseUrl" topology assertion to catch a
 * misconfigured Lambda env building links for the wrong environment (the
 * #137 reset-link-misrouting class).
 *
 * The e2e process doesn't share the server's LMWF_ENV directly, so this is
 * configurable via LMWF_E2E_EXPECTED_EMAIL_HOST. The default matches the
 * local stack, which `scripts/e2e-local.sh` boots with LMWF_ENV=beta →
 * links resolve to beta.getlift.md (appBaseUrl's beta fallback, GH #248).
 */
export function expectedEmailLinkHost(): string {
  const explicit = process.env.LMWF_E2E_EXPECTED_EMAIL_HOST;
  if (explicit) return explicit;
  // The local stack runs with LMWF_ENV=beta (see scripts/e2e-local.sh).
  return 'beta.getlift.md';
}

/**
 * Each test run uses a unique email prefix so reruns + parallel workers
 * don't collide on the (provider, provider_sub) uniqueness check in
 * createIdentity.
 */
export function uniqueEmail(label: string): string {
  return `e2e-${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
}

/**
 * Address that's verified in SES sandbox for the target env. Used by
 * the signup test in `remote` mode, where SES rejects any unverified
 * recipient and `@example.com` would 503 the signup endpoint.
 *
 * SES sandbox compares the full recipient verbatim (no plus-addressing
 * normalization), so re-using one verified address is the only viable
 * option without leaving the sandbox. The test pairs this with
 * /v1/__test__/delete-user-by-email pre-cleanup so successive runs
 * don't trip the 409 dupe-check on signup.
 *
 * In `local` mode SES is replaced by Mailpit, so we still want unique
 * addresses per run for parallel-worker safety.
 */
export function signupTestEmail(): string {
  return getMode() === 'remote'
    ? 'crusted_staid_0k@icloud.com'
    : uniqueEmail('signup');
}

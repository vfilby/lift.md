/**
 * Verification + reset token retrieval.
 *
 * Two strategies, chosen by LMWF_E2E_MODE:
 *   - local  → poll Mailpit's REST API for the latest message to the
 *              given recipient, then extract the JWT from the link in
 *              the body. Exercises the full email-send path.
 *   - remote → POST to /v1/__test__/mint-token with the shared secret.
 *              SES can't be reliably scraped, so we mint the token
 *              directly. Email-send is implicitly exercised by the
 *              signup endpoint returning 200; the rendered content is
 *              covered by validator/tests/email.test.ts.
 *
 * See spec/services/validator-e2e.md → "Modes".
 */
import { getBaseUrl, getMailpitUrl, getMode, getTestSecret } from './env.js';

export type TokenType = 'email_verify' | 'password_reset';

interface MailpitMessageSummary {
  ID: string;
  To: { Address: string }[];
  Subject: string;
  Created: string;
}

interface MailpitMessageDetail {
  ID: string;
  Text: string;
  HTML: string;
}

interface MailpitListResponse {
  messages: MailpitMessageSummary[];
}

// Match group 1 = the token; the full match (group 0) = the whole link,
// which the host-assertion helper below parses to verify the link points
// at the env-correct host (beta vs prod).
const VERIFY_LINK_RE =
  /https?:\/\/[^\s<>'"]+\/v1\/auth\/password\/verify\?token=([^\s<>'")]+)/;
const RESET_LINK_RE =
  /https?:\/\/[^\s<>'"]+\/account\/reset\?token=([^\s<>'")]+)/;

async function fetchLatestMailpitToken(
  email: string,
  type: TokenType,
  timeoutMs: number,
): Promise<string> {
  const re = type === 'email_verify' ? VERIFY_LINK_RE : RESET_LINK_RE;
  const mailpit = getMailpitUrl();
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    // Mailpit's `?query=` supports `to:` filtering.
    const listRes = await fetch(
      `${mailpit}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`,
    );
    if (!listRes.ok) {
      await sleep(200);
      continue;
    }
    const list = (await listRes.json()) as MailpitListResponse;
    // Mailpit returns newest-first.
    for (const summary of list.messages) {
      const detailRes = await fetch(`${mailpit}/api/v1/message/${summary.ID}`);
      if (!detailRes.ok) continue;
      const detail = (await detailRes.json()) as MailpitMessageDetail;
      const body = `${detail.Text}\n${detail.HTML}`;
      const match = re.exec(body);
      if (match?.[1]) return decodeURIComponent(match[1]);
    }
    await sleep(200);
  }

  throw new Error(
    `Timed out after ${timeoutMs}ms waiting for ${type} email to ${email} in Mailpit at ${mailpit}.`,
  );
}

async function mintRemoteToken(
  email: string,
  type: TokenType,
): Promise<string> {
  const res = await fetch(`${getBaseUrl()}/v1/__test__/mint-token`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-test-secret': getTestSecret(),
    },
    body: JSON.stringify({ email, type }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(
      `mint-token returned ${res.status} for ${email} (${type}): ${text}. Is E2E_TEST_SECRET set on the target env and matching LMWF_E2E_TEST_SECRET?`,
    );
  }
  const { token } = (await res.json()) as { token: string };
  return token;
}

/**
 * Fetch the most recent verify/reset token for `email`. Polls up to
 * `timeoutMs` (default 5s) in local mode; remote mode is synchronous.
 */
export async function getLatestToken(
  email: string,
  type: TokenType,
  timeoutMs = 5_000,
): Promise<string> {
  return getMode() === 'local'
    ? fetchLatestMailpitToken(email, type, timeoutMs)
    : mintRemoteToken(email, type);
}

/**
 * Local-only: return the FULL verify/reset link from the latest Mailpit
 * email to `email`. Used by the "email link host == env appBaseUrl"
 * topology assertion — a misconfigured LMWF_ENV on the Lambda builds links
 * pointing at the wrong host (the #137 reset-misrouting class). The link
 * body is only readable where Mailpit is the transport, i.e. local mode,
 * which still gates prod via the e2e-local required check.
 *
 * Throws if called outside local mode — callers must guard on getMode().
 */
export async function getLatestEmailLink(
  email: string,
  type: TokenType,
  timeoutMs = 5_000,
): Promise<string> {
  if (getMode() !== 'local') {
    throw new Error(
      'getLatestEmailLink is local-only (Mailpit transport). Guard callers on getMode() === "local".',
    );
  }
  const re = type === 'email_verify' ? VERIFY_LINK_RE : RESET_LINK_RE;
  const mailpit = getMailpitUrl();
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const listRes = await fetch(
      `${mailpit}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`,
    );
    if (!listRes.ok) {
      await sleep(200);
      continue;
    }
    const list = (await listRes.json()) as MailpitListResponse;
    for (const summary of list.messages) {
      const detailRes = await fetch(`${mailpit}/api/v1/message/${summary.ID}`);
      if (!detailRes.ok) continue;
      const detail = (await detailRes.json()) as MailpitMessageDetail;
      const body = `${detail.Text}\n${detail.HTML}`;
      const match = re.exec(body);
      if (match?.[0]) return match[0];
    }
    await sleep(200);
  }

  throw new Error(
    `Timed out after ${timeoutMs}ms waiting for ${type} email link to ${email} in Mailpit at ${mailpit}.`,
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

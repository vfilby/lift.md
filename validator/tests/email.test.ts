import { describe, it, expect, beforeAll, afterEach } from 'vitest';

// Live Mailpit integration test — mirrors the ddb-smoke skip pattern.
// Skipped unless SMTP_HOST is exported (the make dev-up target brings up
// the Mailpit container and exposes localhost:1025 / localhost:8025).
const liveSmtp = process.env.SMTP_HOST ? describe : describe.skip;

const MAILPIT_API = process.env.MAILPIT_API ?? 'http://localhost:8025';

interface MailpitMessageSummary {
  ID: string;
  To: { Address: string }[];
  Subject: string;
}

interface MailpitListResponse {
  messages: MailpitMessageSummary[];
  total: number;
}

async function deleteAllMail(): Promise<void> {
  const res = await fetch(`${MAILPIT_API}/api/v1/messages`, {
    method: 'DELETE',
  });
  if (!res.ok) {
    throw new Error(`Mailpit cleanup failed: ${res.status} ${res.statusText}`);
  }
}

async function listMail(): Promise<MailpitListResponse> {
  const res = await fetch(`${MAILPIT_API}/api/v1/messages`);
  if (!res.ok) {
    throw new Error(`Mailpit list failed: ${res.status} ${res.statusText}`);
  }
  return (await res.json()) as MailpitListResponse;
}

liveSmtp('email transport (Mailpit)', () => {
  beforeAll(async () => {
    // Ensure SMTP_PORT defaults align with Mailpit if the user only
    // exported SMTP_HOST=localhost.
    process.env.SMTP_PORT ??= '1025';
    process.env.SMTP_FROM ??= 'test@local.dev';
    // Clear any backlog from previous runs.
    await deleteAllMail();
  });

  afterEach(async () => {
    await deleteAllMail();
  });

  it('sends an email that Mailpit captures', async () => {
    // Reset the cached transporter so any env tweaks above take effect.
    const { sendEmail, _resetEmailTransportForTests } = await import(
      '../src/infra/email.js'
    );
    _resetEmailTransportForTests();

    const subject = `vitest-${Date.now()}`;
    const to = 'recipient@example.com';

    await sendEmail({
      to,
      subject,
      text: 'Hello from the LMWF validator email integration test.',
    });

    const messages = await listMail();
    expect(messages.total).toBeGreaterThan(0);
    const match = messages.messages.find((m) => m.Subject === subject);
    expect(match, `expected a message with subject ${subject}`).toBeDefined();
    expect(match!.To.some((addr) => addr.Address === to)).toBe(true);
  });
});

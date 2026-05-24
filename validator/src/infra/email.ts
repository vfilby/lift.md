/**
 * SMTP email transport.
 *
 * Single nodemailer-based helper used everywhere we send mail (sign-in
 * codes, receipts, transactional notifications). Local dev points at the
 * Mailpit container brought up by `make dev-up`; production points at
 * Amazon SES SMTP via env vars set by CDK.
 *
 * Env:
 *   SMTP_HOST   — required; throws on first send if unset
 *   SMTP_PORT   — defaults to 1025 (Mailpit's listener)
 *   SMTP_USER   — optional; forces STARTTLS when present
 *   SMTP_PASS   — optional; paired with SMTP_USER
 *   SMTP_FROM   — defaults to "noreply@<SMTP_HOST>"
 *
 * Port 587 OR a non-empty SMTP_USER triggers STARTTLS auth (SES path).
 * Anything else stays in plain SMTP so Mailpit accepts it without fuss.
 */

import nodemailer, { type Transporter } from 'nodemailer';

export interface SendEmailInput {
  to: string;
  subject: string;
  text: string;
  html?: string;
}

let cachedTransporter: Transporter | undefined;
let cachedFrom: string | undefined;

function buildTransporter(): { transporter: Transporter; from: string } {
  const host = process.env.SMTP_HOST;
  if (!host) {
    throw new Error(
      'SMTP_HOST is not set — refusing to send email. ' +
        'Set SMTP_HOST (and SMTP_PORT / SMTP_USER / SMTP_PASS as needed) ' +
        'or point at the local Mailpit container via `make dev-up`.',
    );
  }

  const port = Number(process.env.SMTP_PORT ?? 1025);
  const user = process.env.SMTP_USER;
  const pass = process.env.SMTP_PASS;
  const from = process.env.SMTP_FROM ?? `noreply@${host}`;

  // STARTTLS path: SES (587) or any explicitly-authenticated relay.
  const useStartTls = port === 587 || !!user;

  const transporter = nodemailer.createTransport({
    host,
    port,
    // `secure: false` + STARTTLS upgrade on port 587 matches SES SMTP.
    // Plain SMTP (no TLS) on 1025 matches Mailpit's default.
    secure: false,
    requireTLS: useStartTls,
    auth: user ? { user, pass: pass ?? '' } : undefined,
  });

  return { transporter, from };
}

function getTransporter(): { transporter: Transporter; from: string } {
  if (!cachedTransporter || !cachedFrom) {
    const built = buildTransporter();
    cachedTransporter = built.transporter;
    cachedFrom = built.from;
  }
  return { transporter: cachedTransporter, from: cachedFrom };
}

/**
 * Send a single email. Throws on transport error so callers can decide
 * how to handle (retry, surface to user, etc.).
 *
 * Exported as the only public API of this module — keep transport
 * construction private so swapping providers stays a one-file change.
 */
export async function sendEmail(input: SendEmailInput): Promise<void> {
  const { transporter, from } = getTransporter();
  await transporter.sendMail({
    from,
    to: input.to,
    subject: input.subject,
    text: input.text,
    html: input.html,
  });
}

/**
 * Test-only hook for resetting the cached transporter between cases that
 * mutate SMTP_* env vars. Not part of the public API.
 */
export function _resetEmailTransportForTests(): void {
  cachedTransporter = undefined;
  cachedFrom = undefined;
}

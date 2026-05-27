/**
 * Transactional email template.
 *
 * One layout shared by every outbound email the validator sends (signup
 * verification, password reset, future security notifications). Renders
 * to a self-contained HTML string with inlined CSS — email clients
 * (Gmail, Outlook, Apple Mail) strip <style> tags and don't load
 * stylesheets, so all styling has to live on the elements themselves.
 *
 * The brand orange (#c2410c) matches `--color-accent` in
 * website/src/layouts/Base.astro. Keep these two in sync if the site
 * accent ever changes.
 *
 * Plain-text bodies are still authored separately at the call site —
 * this module only owns the HTML half. The two-part MIME body is built
 * by sendEmail() in infra/email.ts.
 */

const BRAND = '#c2410c';
const FG = '#1a1a1a';
const MUTED = '#5a5a57';
const BORDER = '#e4e3df';
const BG_SUBTLE = '#f5f4f2';
const BG = '#fdfdfc';

interface TransactionalEmailInput {
  /** Top-of-card heading. */
  heading: string;
  /** First paragraph above the CTA. Keep to one or two short sentences. */
  intro: string;
  /** Button label. */
  ctaLabel: string;
  /** Where the button links. */
  ctaUrl: string;
  /** Note shown directly under the CTA (e.g. "This link expires in 24 hours."). */
  footnote?: string;
  /** Optional reassurance line at the bottom of the card. */
  closingNote?: string;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/// Render the full HTML body for a transactional email. The result is a
/// complete `<!doctype html>` document so it can be passed straight to
/// `sendEmail({ html, ... })`.
export function renderTransactionalEmail(input: TransactionalEmailInput): string {
  const { heading, intro, ctaLabel, ctaUrl, footnote, closingNote } = input;
  // URL is intentionally NOT escaped — it goes inside `href="..."` which
  // already requires URL-safe characters from the caller, and we don't
  // want double-encoding of the token query param.
  const safeHeading = escapeHtml(heading);
  const safeIntro = escapeHtml(intro);
  const safeCtaLabel = escapeHtml(ctaLabel);
  const safeFootnote = footnote ? escapeHtml(footnote) : '';
  const safeClosing = closingNote ? escapeHtml(closingNote) : '';

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${safeHeading}</title>
  </head>
  <body style="margin:0; padding:0; background:${BG_SUBTLE}; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Oxygen,Ubuntu,sans-serif; color:${FG}; line-height:1.5;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${BG_SUBTLE}; padding:24px 12px;">
      <tr>
        <td align="center">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:540px; background:${BG}; border:1px solid ${BORDER}; border-radius:10px; overflow:hidden;">
            <tr>
              <td style="background:${BRAND}; padding:18px 24px;">
                <div style="font-size:18px; font-weight:600; letter-spacing:0.02em; color:#ffffff;">LiftMark</div>
              </td>
            </tr>
            <tr>
              <td style="padding:28px 28px 8px 28px;">
                <h1 style="margin:0 0 14px 0; font-size:22px; font-weight:600; color:${FG};">${safeHeading}</h1>
                <p style="margin:0 0 22px 0; font-size:15px; color:${FG};">${safeIntro}</p>
                <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 14px 0;">
                  <tr>
                    <td style="border-radius:999px; background:${BRAND};">
                      <a href="${ctaUrl}" style="display:inline-block; padding:11px 22px; font-size:15px; font-weight:500; color:#ffffff; text-decoration:none; border-radius:999px;">${safeCtaLabel}</a>
                    </td>
                  </tr>
                </table>
                ${footnote ? `<p style="margin:0 0 18px 0; font-size:13px; color:${MUTED};">${safeFootnote}</p>` : ''}
                <p style="margin:0 0 4px 0; font-size:13px; color:${MUTED};">If the button doesn't work, copy this link into your browser:</p>
                <p style="margin:0 0 18px 0; font-size:12px; color:${MUTED}; word-break:break-all;"><a href="${ctaUrl}" style="color:${MUTED}; text-decoration:underline;">${ctaUrl}</a></p>
                ${closingNote ? `<p style="margin:0; font-size:13px; color:${MUTED};">${safeClosing}</p>` : ''}
              </td>
            </tr>
            <tr>
              <td style="padding:18px 28px 22px 28px; border-top:1px solid ${BORDER};">
                <p style="margin:0; font-size:12px; color:${MUTED};">LiftMark &middot; <a href="https://liftmark.app" style="color:${MUTED}; text-decoration:underline;">liftmark.app</a></p>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>`;
}

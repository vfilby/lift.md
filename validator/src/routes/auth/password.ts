/**
 * Email + password auth routes.
 *
 * All endpoints mounted under /v1/auth/password/* by the parent router.
 * Tokens (verify, reset) are HS256 JWTs typed via the `type` claim so a
 * verify token can't be reused as a reset token and vice versa.
 *
 * Email-enumeration safety: signup/login report a single generic error
 * on bad creds; reset-request and resend-verification always 204
 * regardless of whether the address exists.
 *
 * NOTE: no rate limiting here — that belongs at the API Gateway / WAF
 * layer (or an in-memory bucket per IP in front of these handlers).
 */
import { Hono } from 'hono';
import { signJwt, verifyJwt } from '../../infra/jwt.js';
import { sendEmail } from '../../infra/email.js';
import { renderTransactionalEmail } from '../../infra/email_template.js';
import { hashPassword, verifyPassword } from '../../infra/password.js';
import { audit } from '../../infra/audit.js';
import {
  createIdentity,
  deleteIdentity,
  getIdentityById,
  getIdentityByProviderSub,
  markEmailVerified,
  updatePasswordHash,
} from '../../repositories/identities.js';
import { createRefreshToken } from '../../repositories/refresh_tokens.js';
import { createUser, deleteUser, getUserById } from '../../repositories/users.js';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MIN_PASSWORD_LEN = 12;
const MAX_DISPLAY_NAME = 80;

interface SignupBody {
  email?: unknown;
  password?: unknown;
  display_name?: unknown;
}

interface VerifyBody {
  token?: unknown;
}

interface LoginBody {
  email?: unknown;
  password?: unknown;
  device_label?: unknown;
}

interface ResetRequestBody {
  email?: unknown;
}

interface ResetBody {
  token?: unknown;
  new_password?: unknown;
}

interface ResendBody {
  email?: unknown;
}

interface VerifyTokenPayload {
  sub: string;
  type: 'email_verify';
}

interface ResetTokenPayload {
  sub: string;
  type: 'password_reset';
}

function appBaseUrl(): string {
  // Hardcoded host derivation per spec — LMWF_ENV picks beta vs prod.
  // In local dev SMTP_HOST=localhost; the link still points at the
  // public host, which is fine for Mailpit inspection (we just read it
  // out of the captured email rather than clicking through).
  const env = process.env.LMWF_ENV;
  return env === 'beta' ? 'https://beta.liftmark.app' : 'https://liftmark.app';
}

async function sendVerificationEmail(
  email: string,
  identityId: string,
): Promise<void> {
  const token = signJwt(
    { sub: identityId, type: 'email_verify' satisfies 'email_verify' },
    '24h',
  );
  const link = `${appBaseUrl()}/v1/auth/password/verify?token=${encodeURIComponent(token)}`;
  await sendEmail({
    to: email,
    subject: 'Verify your LiftMark email',
    text: `Welcome to LiftMark.\n\nConfirm your email by opening this link (it expires in 24 hours):\n\n${link}\n\nIf you didn't sign up, you can safely ignore this message.\n\n— LiftMark · https://liftmark.app`,
    html: renderTransactionalEmail({
      heading: 'Confirm your email',
      intro: 'Thanks for signing up for LiftMark. Tap the button below to confirm this email address and finish setting up your account.',
      ctaLabel: 'Confirm email',
      ctaUrl: link,
      footnote: 'This link expires in 24 hours.',
      closingNote: "If you didn't sign up, you can safely ignore this message.",
    }),
  });
}

async function sendResetEmail(
  email: string,
  identityId: string,
): Promise<void> {
  const token = signJwt(
    { sub: identityId, type: 'password_reset' satisfies 'password_reset' },
    '1h',
  );
  // Reset link targets the website's /account/reset page (which POSTs the
  // token + new password back to the API). The /v1/auth/password/reset
  // route is POST-only, so a GET click on a link pointing there would 405.
  const link = `${appBaseUrl()}/account/reset?token=${encodeURIComponent(token)}`;
  await sendEmail({
    to: email,
    subject: 'Reset your LiftMark password',
    text: `A password reset was requested for your LiftMark account.\n\nOpen this link to choose a new password (it expires in 1 hour):\n\n${link}\n\nIf you didn't request a reset, you can safely ignore this message — your password is unchanged.\n\n— LiftMark · https://liftmark.app`,
    html: renderTransactionalEmail({
      heading: 'Reset your password',
      intro: 'A password reset was requested for your LiftMark account. Tap the button below to choose a new password.',
      ctaLabel: 'Choose a new password',
      ctaUrl: link,
      footnote: 'This link expires in 1 hour.',
      closingNote: "If you didn't request a reset, you can safely ignore this message — your password is unchanged.",
    }),
  });
}

export const passwordRouter = new Hono();

passwordRouter.post('/signup', async (c) => {
  let body: SignupBody;
  try {
    body = await c.req.json<SignupBody>();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const emailRaw = body.email;
  const password = body.password;
  const displayName = body.display_name;

  if (typeof emailRaw !== 'string' || !EMAIL_RE.test(emailRaw)) {
    return c.json({ error: 'Invalid email' }, 400);
  }
  if (typeof password !== 'string' || password.length < MIN_PASSWORD_LEN) {
    return c.json(
      { error: `Password must be at least ${MIN_PASSWORD_LEN} characters` },
      400,
    );
  }
  if (
    typeof displayName !== 'string' ||
    displayName.trim().length < 1 ||
    displayName.length > MAX_DISPLAY_NAME
  ) {
    return c.json(
      { error: `display_name must be 1-${MAX_DISPLAY_NAME} characters` },
      400,
    );
  }

  const email = emailRaw.toLowerCase();

  const existing = await getIdentityByProviderSub('password', email);
  if (existing) {
    return c.json({ error: 'An account with that email already exists' }, 409);
  }

  const forwarded = c.req.header('x-forwarded-for');
  const signupIp = forwarded?.split(',')[0]?.trim();
  const userAgent = c.req.header('user-agent');

  const user = await createUser({
    display_name: displayName.trim(),
    primary_email: email,
    signup_ip: signupIp,
    signup_user_agent: userAgent,
  });

  const passwordHash = await hashPassword(password);

  const identity = await createIdentity({
    user_id: user.user_id,
    provider: 'password',
    provider_sub: email,
    email,
    email_verified: false,
    password_hash: passwordHash,
    password_updated_at: new Date().toISOString(),
  });

  // Email send is the last step that can fail. If it throws (e.g. SES
  // sandbox rejecting an unverified recipient, transient SMTP error), the
  // user + identity rows we just wrote would otherwise be orphans — and
  // the next signup attempt from the same address would 409 on the dupe
  // check, even though the first attempt never sent an email. Roll back
  // both rows on failure so retries work.
  try {
    await sendVerificationEmail(email, identity.identity_id);
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    console.error(JSON.stringify({
      level: 'error',
      event: 'signup_email_failed_rolling_back',
      user_id: user.user_id,
      identity_id: identity.identity_id,
      email,
      error: errMsg,
    }));
    // Best-effort cleanup. If either delete fails the orphan persists and
    // will need manual cleanup — logged separately so it's findable.
    try {
      await deleteIdentity(identity.identity_id);
    } catch (cleanupErr) {
      console.error(JSON.stringify({
        level: 'error',
        event: 'signup_rollback_identity_delete_failed',
        identity_id: identity.identity_id,
        error: cleanupErr instanceof Error ? cleanupErr.message : String(cleanupErr),
      }));
    }
    try {
      await deleteUser(user.user_id);
    } catch (cleanupErr) {
      console.error(JSON.stringify({
        level: 'error',
        event: 'signup_rollback_user_delete_failed',
        user_id: user.user_id,
        error: cleanupErr instanceof Error ? cleanupErr.message : String(cleanupErr),
      }));
    }
    return c.json(
      {
        error: 'Could not send verification email. Please try again, or contact support if this persists.',
      },
      503,
    );
  }

  return c.json(
    {
      user_id: user.user_id,
      email,
      message: 'Check your email to verify',
    },
    201,
  );
});

async function verifyToken(token: string): Promise<{
  ok: true;
  user_id: string;
  identity_id: string;
} | { ok: false }> {
  let payload: VerifyTokenPayload & { iat: number; exp: number };
  try {
    payload = verifyJwt<VerifyTokenPayload & { iat: number; exp: number }>(token);
  } catch {
    return { ok: false };
  }
  if (payload.type !== 'email_verify' || !payload.sub) {
    return { ok: false };
  }
  const identity = await getIdentityById(payload.sub);
  if (!identity) {
    return { ok: false };
  }
  if (!identity.email_verified) {
    await markEmailVerified(identity.identity_id);
  }
  return { ok: true, user_id: identity.user_id, identity_id: identity.identity_id };
}

// GET /verify redirects to a website page rather than serving HTML from
// the Lambda — the website's AccountLayout owns the visual story, the
// Lambda only owns state. Success → /account/email-verified, failure →
// /account/email-verified?error=invalid (the page reads the param).
passwordRouter.get('/verify', async (c) => {
  const token = c.req.query('token');
  const successUrl = `${appBaseUrl()}/account/email-verified`;
  const errorUrl = `${appBaseUrl()}/account/email-verified?error=invalid`;
  if (!token) {
    return c.redirect(errorUrl, 302);
  }
  const result = await verifyToken(token);
  if (!result.ok) {
    return c.redirect(errorUrl, 302);
  }
  return c.redirect(successUrl, 302);
});

passwordRouter.post('/verify', async (c) => {
  let body: VerifyBody;
  try {
    body = await c.req.json<VerifyBody>();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }
  const token = body.token;
  if (typeof token !== 'string' || !token) {
    return c.json({ error: 'Invalid or expired verification token' }, 400);
  }
  const result = await verifyToken(token);
  if (!result.ok) {
    return c.json({ error: 'Invalid or expired verification token' }, 400);
  }
  return c.json({ verified: true, user_id: result.user_id }, 200);
});

passwordRouter.post('/login', async (c) => {
  let body: LoginBody;
  try {
    body = await c.req.json<LoginBody>();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }
  const emailRaw = body.email;
  const password = body.password;
  if (typeof emailRaw !== 'string' || typeof password !== 'string') {
    return c.json({ error: 'Invalid credentials' }, 401);
  }
  const email = emailRaw.toLowerCase();

  const identity = await getIdentityByProviderSub('password', email);
  if (!identity || !identity.password_hash) {
    return c.json({ error: 'Invalid credentials' }, 401);
  }
  const ok = await verifyPassword(password, identity.password_hash);
  if (!ok) {
    return c.json({ error: 'Invalid credentials' }, 401);
  }
  if (!identity.email_verified) {
    return c.json(
      {
        error: 'Email not verified',
        resend_url: '/v1/auth/password/resend-verification',
      },
      403,
    );
  }
  const user = await getUserById(identity.user_id);
  if (!user) {
    // Identity exists but the user row is gone — treat as failed login.
    return c.json({ error: 'Invalid credentials' }, 401);
  }

  // Access JWT: short-lived (1h), `type='access'`, marked `fresh`
  // because the caller just proved a credential. The `type` claim
  // prevents cross-purpose reuse (reset/verify tokens cannot be used
  // here, and vice versa). The `authn_age` claim is the toehold for
  // future sensitive-operation gating (change-password / delete-account)
  // — only `fresh` access tokens will be accepted there.
  const access_jwt = signJwt(
    {
      sub: user.user_id,
      identity_id: identity.identity_id,
      type: 'access',
      authn_age: 'fresh',
    },
    '1h',
  );

  // Refresh token: opaque random, hashed at rest, 1-year absolute
  // expiry rooted at this login. The plaintext is returned exactly
  // once and the caller (web dashboard / iOS app) must store it for
  // the rotation flow.
  const deviceLabel =
    typeof body.device_label === 'string' && body.device_label.length <= 80
      ? body.device_label
      : c.req.header('user-agent')?.slice(0, 80);
  const { token: refreshRow, plaintext: refresh_token } =
    await createRefreshToken({
      user_id: user.user_id,
      identity_id: identity.identity_id,
      device_label: deviceLabel,
    });

  audit({
    event: 'login_success',
    user_id: user.user_id,
    identity_id: identity.identity_id,
    token_hash: refreshRow.token_hash,
    family_root_hash: refreshRow.family_root_hash,
    device_label: deviceLabel,
  });

  return c.json(
    {
      access_jwt,
      refresh_token,
      user: {
        user_id: user.user_id,
        email: user.primary_email,
        display_name: user.display_name,
        tier: user.tier,
        trial_ends_at: user.trial_ends_at,
      },
    },
    200,
  );
});

passwordRouter.post('/reset-request', async (c) => {
  let body: ResetRequestBody;
  try {
    body = await c.req.json<ResetRequestBody>();
  } catch {
    // Silent — no enumeration even on malformed bodies.
    return c.body(null, 204);
  }
  const emailRaw = body.email;
  if (typeof emailRaw === 'string') {
    const email = emailRaw.toLowerCase();
    const identity = await getIdentityByProviderSub('password', email);
    if (identity) {
      await sendResetEmail(email, identity.identity_id);
    }
  }
  return c.body(null, 204);
});

passwordRouter.post('/reset', async (c) => {
  let body: ResetBody;
  try {
    body = await c.req.json<ResetBody>();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }
  const token = body.token;
  const newPassword = body.new_password;
  if (typeof token !== 'string' || !token) {
    return c.json({ error: 'Invalid or expired reset token' }, 400);
  }
  if (
    typeof newPassword !== 'string' ||
    newPassword.length < MIN_PASSWORD_LEN
  ) {
    return c.json(
      { error: `Password must be at least ${MIN_PASSWORD_LEN} characters` },
      400,
    );
  }
  let payload: ResetTokenPayload & { iat: number; exp: number };
  try {
    payload = verifyJwt<ResetTokenPayload & { iat: number; exp: number }>(
      token,
    );
  } catch {
    return c.json({ error: 'Invalid or expired reset token' }, 400);
  }
  if (payload.type !== 'password_reset' || !payload.sub) {
    return c.json({ error: 'Invalid or expired reset token' }, 400);
  }
  const identity = await getIdentityById(payload.sub);
  if (!identity) {
    return c.json({ error: 'Invalid or expired reset token' }, 400);
  }
  const hashed = await hashPassword(newPassword);
  await updatePasswordHash(identity.identity_id, hashed);
  return c.json({ message: 'Password updated' }, 200);
});

passwordRouter.post('/resend-verification', async (c) => {
  let body: ResendBody;
  try {
    body = await c.req.json<ResendBody>();
  } catch {
    return c.body(null, 204);
  }
  const emailRaw = body.email;
  if (typeof emailRaw === 'string') {
    const email = emailRaw.toLowerCase();
    const identity = await getIdentityByProviderSub('password', email);
    if (identity && !identity.email_verified) {
      await sendVerificationEmail(email, identity.identity_id);
    }
  }
  return c.body(null, 204);
});

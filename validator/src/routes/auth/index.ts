/**
 * /v1/auth router.
 *
 * Mounts the password sub-router and exposes the session-authenticated
 * link / identity-delete endpoints that aren't provider-specific.
 *
 * Only `provider: 'password'` is implementable here today — Apple
 * (Slice ?) and Google/GitHub (later) will plug into the same /link
 * route by extending the provider switch.
 */
import { Hono } from 'hono';
import { passwordRouter } from './password.js';
import { refreshRouter } from './refresh.js';
import {
  sessionMiddleware,
  type SessionVariables,
} from '../../middleware/session.js';
import {
  createIdentity,
  deleteIdentity,
  getIdentityById,
  getIdentityByProviderSub,
  listIdentitiesByUserId,
} from '../../repositories/identities.js';
import { revokeAllForIdentity } from '../../repositories/refresh_tokens.js';
import { hashPassword } from '../../infra/password.js';
import { audit } from '../../infra/audit.js';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MIN_PASSWORD_LEN = 12;

interface LinkBody {
  provider?: unknown;
  email?: unknown;
  password?: unknown;
}

export const authRouter = new Hono();

authRouter.route('/password', passwordRouter);
// /v1/auth/refresh, /v1/auth/logout, /v1/auth/logout-all
authRouter.route('/', refreshRouter);

authRouter.post(
  '/link',
  sessionMiddleware,
  async (c) => {
    const ctx = c as typeof c & { var: SessionVariables };
    let body: LinkBody;
    try {
      body = await c.req.json<LinkBody>();
    } catch {
      return c.json({ error: 'Invalid JSON body' }, 400);
    }

    const provider = body.provider;
    if (provider !== 'password') {
      // apple/google/github will land here later; for now reject explicitly.
      return c.json({ error: 'Unsupported provider' }, 400);
    }

    const emailRaw = body.email;
    const password = body.password;
    if (typeof emailRaw !== 'string' || !EMAIL_RE.test(emailRaw)) {
      return c.json({ error: 'Invalid email' }, 400);
    }
    if (typeof password !== 'string' || password.length < MIN_PASSWORD_LEN) {
      return c.json(
        { error: `Password must be at least ${MIN_PASSWORD_LEN} characters` },
        400,
      );
    }

    const email = emailRaw.toLowerCase();
    const existing = await getIdentityByProviderSub('password', email);
    if (existing) {
      return c.json(
        { error: 'That sign-in method is already in use' },
        409,
      );
    }

    const passwordHash = await hashPassword(password);
    const identity = await createIdentity({
      user_id: ctx.var.session.user_id,
      provider: 'password',
      provider_sub: email,
      email,
      // Linking a new password identity to an already-authenticated
      // session is its own proof of email-control for that session, but
      // not for the *new* email. Keep verified=false and let the user
      // run the verify flow (resend-verification) to confirm.
      email_verified: false,
      password_hash: passwordHash,
      password_updated_at: new Date().toISOString(),
    });

    return c.json(
      {
        identity_id: identity.identity_id,
        provider: identity.provider,
        email: identity.email,
        email_verified: identity.email_verified,
      },
      201,
    );
  },
);

authRouter.delete(
  '/identities/:identity_id',
  sessionMiddleware,
  async (c) => {
    const ctx = c as typeof c & { var: SessionVariables };
    const identityId = c.req.param('identity_id');
    const identity = await getIdentityById(identityId);
    if (!identity || identity.user_id !== ctx.var.session.user_id) {
      // Don't leak whether the id exists vs. belongs to someone else.
      return c.json({ error: 'Identity not found' }, 404);
    }
    const all = await listIdentitiesByUserId(ctx.var.session.user_id);
    if (all.length <= 1) {
      return c.json(
        { error: 'Cannot remove your last sign-in method' },
        400,
      );
    }
    // Cascade: revoke every refresh token bound to this identity
    // BEFORE deleting the identity row. Order matters — if the delete
    // succeeded but the cascade failed, an attacker who already had a
    // refresh token would retain access despite the identity being
    // gone. Running the cascade first means the worst case is a
    // partially-revoked-but-still-present identity, which the user can
    // simply try to delete again.
    const cascaded = await revokeAllForIdentity(
      ctx.var.session.user_id,
      identityId,
      'identity_deleted',
    );
    await deleteIdentity(identityId);
    audit({
      event: 'identity_deleted',
      user_id: ctx.var.session.user_id,
      identity_id: identityId,
      refresh_tokens_revoked: cascaded,
    });
    return c.body(null, 204);
  },
);

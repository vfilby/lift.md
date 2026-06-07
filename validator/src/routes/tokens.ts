/**
 * /v1/tokens — Personal access token management (session-auth).
 *
 * - POST   /v1/tokens               issue a new PAT; plaintext returned once
 * - GET    /v1/tokens               list this user's tokens (no plaintext/hash)
 * - DELETE /v1/tokens/:token_id     revoke; idempotent 204
 *
 * Gating per spec:
 *   free  → 402 on POST
 *   trial → max 2 active (non-revoked, non-expired) tokens; 429 at limit
 *   pro   → unlimited
 */
import { Hono } from 'hono';
import {
  sessionMiddleware,
  type SessionVariables,
} from '../middleware/session.js';
import {
  createToken,
  listTokensByUserId,
  revokeToken,
  type PatToken,
  type TokenMode,
} from '../repositories/pat_tokens.js';

interface CreateTokenBody {
  name?: unknown;
  scopes?: unknown;
  expires_at?: unknown;
}

const MAX_NAME_LEN = 80;
const DEFAULT_SCOPES = ['workouts:write', 'workouts:read'];
// Server-side allowlist of scopes a self-service PAT may carry. This is
// exactly the set the API enforces today via `requireScope` (see
// src/routes/workouts.ts and workout_outbox.ts). Any future privileged
// scope is deny-by-default here: a user cannot pre-mint a token carrying a
// scope the server hasn't deliberately added to this set.
const ALLOWED_SCOPES = new Set(['workouts:read', 'workouts:write']);
// Generous cap — there are only two scopes today; this just bounds abuse.
const MAX_SCOPES = 16;
const TRIAL_MAX_ACTIVE_TOKENS = 2;
const UPGRADE_URL = 'https://getlift.md/account';

function patMode(): TokenMode {
  return process.env.STRIPE_MODE === 'live' ? 'live' : 'test';
}

function isActive(t: PatToken, now: number): boolean {
  if (t.revoked_at) return false;
  if (t.expires_at && new Date(t.expires_at).getTime() < now) return false;
  return true;
}

function publicView(t: PatToken): Omit<PatToken, 'token_hash'> {
  // Strip token_hash; everything else is safe to surface.
  const { token_hash: _hash, ...rest } = t;
  return rest;
}

export const tokensRouter = new Hono();

tokensRouter.use('*', sessionMiddleware);

tokensRouter.post('/', async (c) => {
  const ctx = c as typeof c & { var: SessionVariables };
  const user = ctx.var.user;

  let body: CreateTokenBody;
  try {
    body = await c.req.json<CreateTokenBody>();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const nameRaw = body.name;
  if (
    typeof nameRaw !== 'string' ||
    nameRaw.trim().length < 1 ||
    nameRaw.length > MAX_NAME_LEN
  ) {
    return c.json(
      { error: `name must be 1-${MAX_NAME_LEN} characters` },
      400,
    );
  }
  const name = nameRaw.trim();

  let scopes: string[];
  if (body.scopes === undefined) {
    scopes = DEFAULT_SCOPES;
  } else if (
    Array.isArray(body.scopes) &&
    body.scopes.every((s) => typeof s === 'string')
  ) {
    const requested = body.scopes as string[];
    if (requested.length > MAX_SCOPES) {
      return c.json(
        { error: `scopes may list at most ${MAX_SCOPES} entries` },
        400,
      );
    }
    const unknown = requested.filter((s) => !ALLOWED_SCOPES.has(s));
    if (unknown.length > 0) {
      return c.json(
        {
          error: `Unknown scope(s): ${unknown.join(', ')}`,
          allowed_scopes: [...ALLOWED_SCOPES],
        },
        400,
      );
    }
    scopes = requested;
  } else {
    return c.json({ error: 'scopes must be an array of strings' }, 400);
  }

  let expiresAt: string | undefined;
  if (body.expires_at !== undefined && body.expires_at !== null) {
    if (typeof body.expires_at !== 'string') {
      return c.json({ error: 'expires_at must be an ISO date string' }, 400);
    }
    const parsed = Date.parse(body.expires_at);
    if (Number.isNaN(parsed)) {
      return c.json({ error: 'expires_at must be a valid ISO date' }, 400);
    }
    if (parsed <= Date.now()) {
      return c.json({ error: 'expires_at must be in the future' }, 400);
    }
    expiresAt = new Date(parsed).toISOString();
  }

  if (user.tier === 'free') {
    return c.json(
      { error: 'Subscription required', upgrade_url: UPGRADE_URL },
      402,
    );
  }

  if (user.tier === 'trial') {
    const existing = await listTokensByUserId(user.user_id);
    const now = Date.now();
    const active = existing.filter((t) => isActive(t, now));
    if (active.length >= TRIAL_MAX_ACTIVE_TOKENS) {
      return c.json(
        {
          error: `Trial limit reached: ${TRIAL_MAX_ACTIVE_TOKENS} active tokens`,
          upgrade_url: UPGRADE_URL,
        },
        429,
      );
    }
  }

  const { token, plaintext } = await createToken({
    user_id: user.user_id,
    name,
    scopes,
    expires_at: expiresAt,
    mode: patMode(),
  });

  return c.json(
    {
      token_id: token.token_id,
      prefix: token.prefix,
      name: token.name,
      scopes: token.scopes,
      created_at: token.created_at,
      expires_at: token.expires_at,
      plaintext,
      message: 'Save this token now — it will not be shown again.',
    },
    201,
  );
});

tokensRouter.get('/', async (c) => {
  const ctx = c as typeof c & { var: SessionVariables };
  const user = ctx.var.user;
  const tokens = await listTokensByUserId(user.user_id);
  return c.json({
    tier: user.tier,
    trial_ends_at: user.trial_ends_at,
    tokens: tokens.map(publicView),
  });
});

tokensRouter.delete('/:token_id', async (c) => {
  const ctx = c as typeof c & { var: SessionVariables };
  const tokenId = c.req.param('token_id');
  // Idempotent — repository is silent on not-found; never 404 (no enum).
  await revokeToken(ctx.var.user.user_id, tokenId);
  return c.body(null, 204);
});

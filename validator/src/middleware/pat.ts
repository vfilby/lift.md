/**
 * Personal access token (PAT) auth middleware.
 *
 * Reads `Authorization: Bearer lm_pat_<mode>_…`, hashes the plaintext,
 * looks up the row, and rejects on missing/revoked/expired/free-tier.
 * On success attaches `user`, `token`, and `pat_token_id` to the Hono
 * context and fires off a non-blocking markUsed() to stamp last-used
 * metadata.
 *
 * Two exports:
 *   - `patAuth`       — base middleware, no scope check
 *   - `requireScope(scope)` — factory that wraps patAuth and 403s if the
 *                              token's scopes don't include `scope`
 *
 * Free tier returns 402 here (not 401) so clients can distinguish "fix
 * your token" from "upgrade your plan".
 */
import { createMiddleware } from 'hono/factory';
import {
  getTokenByHash,
  hashToken,
  markUsed,
  type PatToken,
} from '../repositories/pat_tokens.js';
import { getUserById, type User } from '../repositories/users.js';

export type PatVariables = {
  user: User;
  token: PatToken;
  pat_token_id: string;
};

const PAT_PREFIX = 'lm_pat_';

function sourceIp(headerVal: string | undefined, fallback?: string): string {
  if (headerVal) {
    const first = headerVal.split(',')[0]?.trim();
    if (first) return first;
  }
  if (fallback) return fallback;
  return 'unknown';
}

type PatContext = Parameters<
  Parameters<typeof createMiddleware<{ Variables: PatVariables }>>[0]
>[0];

async function authenticate(c: PatContext): Promise<Response | null> {
  const header =
    c.req.header('authorization') ?? c.req.header('Authorization');
  if (!header || !header.toLowerCase().startsWith('bearer ')) {
    return c.json({ error: 'Missing or invalid authorization header' }, 401);
  }
  const plaintext = header.slice(7).trim();
  if (!plaintext.startsWith(PAT_PREFIX)) {
    return c.json({ error: 'Invalid token format' }, 401);
  }

  const token = await getTokenByHash(hashToken(plaintext));
  if (!token) {
    return c.json({ error: 'Invalid token' }, 401);
  }
  if (token.revoked_at) {
    return c.json({ error: 'Token revoked' }, 401);
  }
  if (token.expires_at && new Date(token.expires_at).getTime() < Date.now()) {
    return c.json({ error: 'Token expired' }, 401);
  }

  const user = await getUserById(token.user_id);
  if (!user) {
    return c.json({ error: 'Invalid token' }, 401);
  }
  if (user.tier === 'free') {
    return c.json({ error: 'Subscription required' }, 402);
  }

  c.set('user', user);
  c.set('token', token);
  c.set('pat_token_id', token.token_id);

  // Fire-and-forget last-used stamp. Never let a write failure crash
  // the hot path — log and move on.
  const ip = sourceIp(
    c.req.header('x-forwarded-for'),
    c.req.header('x-real-ip'),
  );
  void markUsed(token.token_hash, ip).catch((err) => {
    console.warn(
      JSON.stringify({
        level: 'warn',
        event: 'pat_mark_used_failed',
        token_id: token.token_id,
        error: err instanceof Error ? err.message : String(err),
      }),
    );
  });

  return null;
}

export const patAuth = createMiddleware<{ Variables: PatVariables }>(
  async (c, next) => {
    const failure = await authenticate(c);
    if (failure) return failure;
    await next();
  },
);

/**
 * Factory: authenticates the PAT *and* requires the given scope.
 * 403s if authenticated but missing the scope.
 */
export function requireScope(scope: string) {
  return createMiddleware<{ Variables: PatVariables }>(async (c, next) => {
    const failure = await authenticate(c);
    if (failure) return failure;
    if (!c.var.token.scopes.includes(scope)) {
      return c.json({ error: `Missing required scope: ${scope}` }, 403);
    }
    await next();
  });
}

/**
 * Combined auth middleware — accepts either a session JWT or a PAT.
 *
 * Routes that should be reachable by both the web dashboard (which carries
 * a session JWT) and third-party clients (which carry PATs) use this
 * instead of `sessionMiddleware` or `patAuth` directly.
 *
 * Dispatch is by token prefix:
 *   - `lm_pat_…` → delegates to the PAT-auth path (look up by hash, scope
 *                  check if a scope was required, fire-and-forget markUsed,
 *                  set c.var.user + c.var.token + c.var.pat_token_id).
 *   - anything else → delegates to the session-JWT path (verify, load
 *                  user, set c.var.user + c.var.session). c.var.token
 *                  stays undefined so handlers can tell the two apart.
 *
 * Scopes:
 *   - PATs are scope-restricted (a write-only PAT cannot read the inbox).
 *   - Session JWTs are full-power — the user is logged in and inspecting
 *     their own account, so every scope is implicitly granted.
 *
 * The original `pat.ts` / `session.ts` middlewares stay intact; routes
 * that must reject one auth shape outright can still import them.
 */
import { createMiddleware } from 'hono/factory';
import { verifyJwt, tokenIssuedBefore } from '../infra/jwt.js';
import {
  getTokenByHash,
  hashToken,
  markUsed,
  type PatToken,
} from '../repositories/pat_tokens.js';
import { getUserById, type User } from '../repositories/users.js';
import type { AccessPayload, SessionContext } from './session.js';

export type AuthVariables = {
  user: User;
  token?: PatToken;
  pat_token_id?: string;
  session?: SessionContext;
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

type AuthContext = Parameters<
  Parameters<typeof createMiddleware<{ Variables: AuthVariables }>>[0]
>[0];

interface PatAuthSuccess {
  kind: 'pat';
  user: User;
  token: PatToken;
}

interface SessionAuthSuccess {
  kind: 'session';
  user: User;
  session: SessionContext;
}

type AuthResult =
  | PatAuthSuccess
  | SessionAuthSuccess
  | { kind: 'fail'; response: Response };

async function authenticatePat(
  c: AuthContext,
  plaintext: string,
): Promise<AuthResult> {
  const token = await getTokenByHash(hashToken(plaintext));
  if (!token) {
    return { kind: 'fail', response: c.json({ error: 'Invalid token' }, 401) };
  }
  if (token.revoked_at) {
    return { kind: 'fail', response: c.json({ error: 'Token revoked' }, 401) };
  }
  if (token.expires_at && new Date(token.expires_at).getTime() < Date.now()) {
    return { kind: 'fail', response: c.json({ error: 'Token expired' }, 401) };
  }
  const user = await getUserById(token.user_id);
  if (!user) {
    return { kind: 'fail', response: c.json({ error: 'Invalid token' }, 401) };
  }
  if (user.tier === 'free') {
    return {
      kind: 'fail',
      response: c.json({ error: 'Subscription required' }, 402),
    };
  }

  // Fire-and-forget last-used stamp. Mirror pat.ts — never let a write
  // failure crash the hot path.
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

  return { kind: 'pat', user, token };
}

async function authenticateSession(
  c: AuthContext,
  jwt: string,
): Promise<AuthResult> {
  let payload: AccessPayload;
  try {
    payload = verifyJwt<AccessPayload>(jwt);
  } catch {
    return { kind: 'fail', response: c.json({ error: 'Unauthorized' }, 401) };
  }
  if (payload.type !== 'access' || !payload.sub || !payload.identity_id) {
    return { kind: 'fail', response: c.json({ error: 'Unauthorized' }, 401) };
  }
  const user = await getUserById(payload.sub);
  if (!user) {
    return { kind: 'fail', response: c.json({ error: 'Unauthorized' }, 401) };
  }
  // Reject access tokens minted before the account token cutoff (password
  // reset / logout-all) — mirrors sessionMiddleware. No extra DDB read.
  if (tokenIssuedBefore(payload.iat, user.tokens_valid_after)) {
    return { kind: 'fail', response: c.json({ error: 'Unauthorized' }, 401) };
  }
  return {
    kind: 'session',
    user,
    session: {
      user_id: payload.sub,
      identity_id: payload.identity_id,
      authn_age: payload.authn_age,
    },
  };
}

async function authenticate(c: AuthContext): Promise<AuthResult> {
  const header =
    c.req.header('authorization') ?? c.req.header('Authorization');
  if (!header || !header.toLowerCase().startsWith('bearer ')) {
    return { kind: 'fail', response: c.json({ error: 'Unauthorized' }, 401) };
  }
  const plaintext = header.slice(7).trim();
  if (!plaintext) {
    return { kind: 'fail', response: c.json({ error: 'Unauthorized' }, 401) };
  }

  if (plaintext.startsWith(PAT_PREFIX)) {
    return authenticatePat(c, plaintext);
  }
  return authenticateSession(c, plaintext);
}

function applyAuth(c: AuthContext, result: PatAuthSuccess | SessionAuthSuccess): void {
  if (result.kind === 'pat') {
    c.set('user', result.user);
    c.set('token', result.token);
    c.set('pat_token_id', result.token.token_id);
  } else {
    c.set('user', result.user);
    c.set('session', result.session);
  }
}

/**
 * Base middleware — accepts either auth shape, no scope check.
 */
export const auth = createMiddleware<{ Variables: AuthVariables }>(
  async (c, next) => {
    const result = await authenticate(c);
    if (result.kind === 'fail') return result.response;
    applyAuth(c, result);
    await next();
  },
);

/**
 * Factory: authenticate (PAT or session) AND require the given scope.
 *
 * Session JWTs satisfy any scope — sessions are full-power, the user is
 * logged in and inspecting their own data. Only PATs are scope-restricted.
 */
export function requireScope(scope: string) {
  return createMiddleware<{ Variables: AuthVariables }>(async (c, next) => {
    const result = await authenticate(c);
    if (result.kind === 'fail') return result.response;
    if (result.kind === 'pat' && !result.token.scopes.includes(scope)) {
      return c.json({ error: `Missing required scope: ${scope}` }, 403);
    }
    applyAuth(c, result);
    await next();
  });
}

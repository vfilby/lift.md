/**
 * Test-only endpoints, mounted at /v1/__test__/*.
 *
 * Active ONLY when, AT REQUEST TIME:
 *   - process.env.E2E_TEST_SECRET is a non-empty string, AND
 *   - process.env.LMWF_ENV is anything other than 'prod', AND
 *   - the request carries the matching X-Test-Secret header.
 *
 * When ANY of those is false, every endpoint here 404s. 404 (not 401)
 * keeps the route's existence indistinguishable from "unmounted" — a
 * misconfigured prod deploy that accidentally carried the env var would
 * still be safe because of the LMWF_ENV check.
 *
 * See spec/services/validator-e2e.md → "Test-only token endpoint".
 */
import { Hono } from 'hono';
import { timingSafeEqual } from 'node:crypto';
import type { MiddlewareHandler } from 'hono';
import { signJwt } from '../../infra/jwt.js';
import { hashPassword } from '../../infra/password.js';
import {
  createIdentity,
  getIdentityByProviderSub,
  markEmailVerified,
} from '../../repositories/identities.js';
import {
  createUser,
  updateUserTier,
  type UserTier,
} from '../../repositories/users.js';
import { createOutboxItem } from '../../repositories/workout_outbox.js';

type TokenType = 'email_verify' | 'password_reset';

interface MintBody {
  email?: unknown;
  type?: unknown;
}

function secretMatches(provided: string | undefined, expected: string): boolean {
  if (!provided) return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

const gateMiddleware: MiddlewareHandler = async (c, next) => {
  const expectedSecret = process.env.E2E_TEST_SECRET;
  const env = process.env.LMWF_ENV;
  if (!expectedSecret || expectedSecret.length === 0) return c.notFound();
  if (env === 'prod') return c.notFound();
  if (!secretMatches(c.req.header('x-test-secret'), expectedSecret)) {
    return c.notFound();
  }
  await next();
};

export const testRouter = new Hono();

testRouter.use('*', gateMiddleware);

interface SeedUserBody {
  email?: unknown;
  password?: unknown;
  display_name?: unknown;
  tier?: unknown;
  email_verified?: unknown;
}

const VALID_TIERS: ReadonlySet<UserTier> = new Set(['pro', 'trial', 'free']);

/**
 * Create a user + password identity in one call and return a short-lived
 * session JWT. Skips the signup → verify-email → login dance so E2E
 * tests can focus on the screens they're actually exercising.
 *
 * Defaults: tier='trial', email_verified=true.
 */
testRouter.post('/seed-user', async (c) => {
  let body: SeedUserBody;
  try {
    body = await c.req.json<SeedUserBody>();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const emailRaw = body.email;
  if (typeof emailRaw !== 'string' || emailRaw.length === 0) {
    return c.json({ error: 'email must be a string' }, 400);
  }
  const email = emailRaw.toLowerCase();
  const password = typeof body.password === 'string' ? body.password : 'correct horse battery staple';
  const displayName =
    typeof body.display_name === 'string' && body.display_name.trim().length > 0
      ? body.display_name.trim()
      : 'E2E Seed';
  const tier: UserTier =
    typeof body.tier === 'string' && VALID_TIERS.has(body.tier as UserTier)
      ? (body.tier as UserTier)
      : 'trial';
  const emailVerified = body.email_verified === false ? false : true;

  if (await getIdentityByProviderSub('password', email)) {
    return c.json({ error: 'email already in use' }, 409);
  }

  const user = await createUser({
    display_name: displayName,
    primary_email: email,
  });
  if (tier !== 'trial') {
    await updateUserTier(user.user_id, tier);
  }
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
  if (emailVerified) {
    await markEmailVerified(identity.identity_id);
  }

  const sessionJwt = signJwt(
    {
      sub: user.user_id,
      identity_id: identity.identity_id,
      type: 'access',
      authn_age: 'fresh',
    },
    '1h',
  );

  return c.json(
    {
      user_id: user.user_id,
      identity_id: identity.identity_id,
      email,
      tier,
      session_jwt: sessionJwt,
    },
    201,
  );
});

interface SeedOutboxBody {
  user_id?: unknown;
  session_name?: unknown;
}

/**
 * Write a minimal outbox item directly. Bypasses the real /v1/workouts/outbox
 * push envelope so outbox-UI tests don't have to maintain a fixture that
 * tracks the iOS export schema. The full envelope shape is covered by
 * workout_outbox.test.ts.
 */
testRouter.post('/seed-outbox-item', async (c) => {
  let body: SeedOutboxBody;
  try {
    body = await c.req.json<SeedOutboxBody>();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }
  if (typeof body.user_id !== 'string' || body.user_id.length === 0) {
    return c.json({ error: 'user_id must be a string' }, 400);
  }
  const sessionName =
    typeof body.session_name === 'string' && body.session_name.trim().length > 0
      ? body.session_name.trim()
      : 'E2E Seeded Workout';
  const now = new Date();
  const result = await createOutboxItem({
    user_id: body.user_id,
    client_session_id: `e2e-${now.getTime()}-${Math.floor(Math.random() * 1e9)}`,
    session_completed_at: now.toISOString(),
    session_name: sessionName,
    payload_json: {
      session: {
        name: sessionName,
        date: now.toISOString().slice(0, 10),
        startTime: new Date(now.getTime() - 60 * 60_000).toISOString(),
        endTime: now.toISOString(),
        duration: 3600,
        status: 'completed',
        exercises: [
          {
            exerciseName: 'Bench Press',
            orderIndex: 0,
            status: 'completed',
            sets: [
              {
                orderIndex: 0,
                status: 'completed',
                actualWeight: 185,
                actualWeightUnit: 'lbs',
                actualReps: 5,
              },
            ],
          },
        ],
      },
    },
  });
  return c.json({ outbox_id: result.item.outbox_id }, 201);
});

testRouter.post('/mint-token', async (c) => {
  let body: MintBody;
  try {
    body = await c.req.json<MintBody>();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const emailRaw = body.email;
  const typeRaw = body.type;
  if (typeof emailRaw !== 'string' || emailRaw.length === 0) {
    return c.json({ error: 'email must be a string' }, 400);
  }
  if (typeRaw !== 'email_verify' && typeRaw !== 'password_reset') {
    return c.json(
      { error: "type must be 'email_verify' or 'password_reset'" },
      400,
    );
  }
  const type = typeRaw as TokenType;

  const identity = await getIdentityByProviderSub(
    'password',
    emailRaw.toLowerCase(),
  );
  if (!identity) {
    return c.notFound();
  }

  const token = signJwt(
    { sub: identity.identity_id, type },
    type === 'email_verify' ? '24h' : '1h',
  );
  return c.json({ token }, 200);
});

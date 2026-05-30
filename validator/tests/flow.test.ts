import { describe, it, expect, beforeAll, afterAll } from 'vitest';

// ─────────────────────────────────────────────────────────────────────────
// Layer 1 of issue #137: full HTTP happy-path integration suite.
//
// Where the per-route tests (tests/routes/**) each prove one endpoint's
// contract in isolation — frequently short-circuiting the auth flow by
// minting a session JWT or a PAT directly against the repository — this
// suite exercises the ENTIRE chain end-to-end against the real Hono app +
// DynamoDB Local + Mailpit, in the order a real client would walk it:
//
//   signup → verify email (via Mailpit) → login → list tokens → mint PAT →
//   push workout (PAT) → list inbox → fetch inbox detail → ack inbox →
//   push completed session (PAT) → list outbox → fetch outbox detail →
//   delete outbox → password reset (via Mailpit) → re-login.
//
// The value is protocol-level: if any handler's request/response contract
// drifts such that the steps no longer compose (a renamed field, a changed
// status code, a token shape the next step can't consume), THIS test breaks
// even when every isolated route test stays green. That's the breakage class
// Layer 1 is meant to catch before the deploy queue.
//
// Gating mirrors the other live-integration suites: it runs only when
// DDB_ENDPOINT + SMTP_HOST are exported (i.e. `make dev-up` is up). Under
// plain `npm test` in CI those vars are unset, so the suite self-skips —
// no new CI job, no new dependency. See spec/services/validator-e2e.md.
// ─────────────────────────────────────────────────────────────────────────

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';
const MAILPIT_API = process.env.MAILPIT_API ?? 'http://localhost:8025';

const live =
  process.env.DDB_ENDPOINT && process.env.SMTP_HOST ? describe : describe.skip;

// ── Mailpit REST helpers (same shape the auth/password test uses) ──

interface MailpitListResponse {
  messages: { ID: string; To: { Address: string }[]; Subject: string }[];
  total: number;
}

interface MailpitMessageDetail {
  ID: string;
  To: { Address: string }[];
  Subject: string;
  Text: string;
  HTML: string;
}

async function deleteAllMail(): Promise<void> {
  await fetch(`${MAILPIT_API}/api/v1/messages`, { method: 'DELETE' });
}

async function fetchMailTo(addr: string): Promise<MailpitMessageDetail> {
  const list = (await (
    await fetch(`${MAILPIT_API}/api/v1/messages`)
  ).json()) as MailpitListResponse;
  const summary = list.messages.find((m) =>
    m.To.some((t) => t.Address === addr),
  );
  if (!summary) {
    throw new Error(
      `No mail captured for ${addr} (have ${list.total} message(s))`,
    );
  }
  return (await (
    await fetch(`${MAILPIT_API}/api/v1/message/${summary.ID}`)
  ).json()) as MailpitMessageDetail;
}

function extractToken(body: string): string {
  const m = body.match(/[?&]token=([^\s"'<>&]+)/);
  if (!m) throw new Error(`No token found in body: ${body}`);
  return decodeURIComponent(m[1]);
}

// A valid LMWF plan pushed to the inbox.
const VALID_LMWF = `# Push Day
@tags: strength, upper
@units: lbs

## Bench Press
- 135 x 5
- 185 x 5
- 225 x 5
`;

// A completed-session export envelope pushed to the outbox.
function makeEnvelope(name = 'Push Day') {
  return {
    exportedAt: new Date().toISOString(),
    appVersion: '1.6.3-test',
    session: {
      name,
      date: '2026-05-29',
      startTime: '2026-05-29T17:35:00Z',
      endTime: '2026-05-29T18:28:00Z',
      duration: 3180,
      status: 'completed' as const,
      exercises: [
        {
          exerciseName: 'Bench Press',
          orderIndex: 0,
          status: 'completed',
          sets: [
            {
              orderIndex: 0,
              status: 'completed',
              isDropset: false,
              isPerSide: false,
              targetWeight: 185,
              targetWeightUnit: 'lbs',
              targetReps: 5,
              actualWeight: 185,
              actualWeightUnit: 'lbs',
              actualReps: 5,
            },
          ],
        },
      ],
    },
  };
}

live('issue #137 Layer 1 — full HTTP happy-path flow', () => {
  let originalSecret: string | undefined;
  let app: typeof import('../src/app.js').app;

  beforeAll(async () => {
    originalSecret = process.env.JWT_SECRET;
    process.env.JWT_SECRET = TEST_SECRET;
    process.env.SMTP_PORT ??= '1025';
    process.env.SMTP_FROM ??= 'test@local.dev';

    // Pick up the Mailpit transport for this JWT secret / SMTP config.
    const { _resetEmailTransportForTests } = await import(
      '../src/infra/email.js'
    );
    _resetEmailTransportForTests();

    ({ app } = await import('../src/app.js'));

    // Start from a clean inbox so fetchMailTo never trips over backlog.
    await deleteAllMail();
  });

  afterAll(() => {
    if (originalSecret === undefined) delete process.env.JWT_SECRET;
    else process.env.JWT_SECRET = originalSecret;
  });

  // Unique identity per run — the suite shares DDB + Mailpit with every
  // other live test and with prior runs (DDB Local has a persistent volume),
  // so a fresh email each run keeps the flow deterministic.
  const email = `flow-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
  const password = 'correct-horse-battery-staple';
  const newPassword = 'a-brand-new-passphrase-here-137';

  // Carried across steps. The whole point is that each step consumes the
  // exact token/id the previous step produced — proving the contract holds
  // across handler boundaries, not just within one route.
  const ctx: {
    user_id?: string;
    access_jwt?: string;
    refresh_token?: string;
    session_jwt?: string;
    pat?: string;
    pat_token_id?: string;
    inbox_id?: string;
    outbox_id?: string;
    client_session_id?: string;
  } = {};

  async function postJson(
    path: string,
    body: unknown,
    headers: Record<string, string> = {},
  ): Promise<Response> {
    return app.request(path, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body: JSON.stringify(body),
    });
  }

  // ── 1. Signup ──────────────────────────────────────────────────────────
  it('1. signup → 201, returns the new user_id and echoes the email', async () => {
    const res = await postJson('/v1/auth/password/signup', {
      email,
      password,
      display_name: 'Flow User',
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      user_id: string;
      email: string;
      message: string;
    };
    expect(body.email).toBe(email);
    expect(body.user_id).toMatch(/^[0-9a-f-]{36}$/);
    ctx.user_id = body.user_id;
  });

  // ── 2. Fetch verification email from Mailpit + verify ────────────────────
  it('2. verification email lands in Mailpit and POST /verify confirms it', async () => {
    const mail = await fetchMailTo(email);
    expect(mail.Subject).toMatch(/verify/i);
    const token = extractToken(mail.Text || mail.HTML);

    // Before verify, login is a uniform 401 (no "unverified" oracle).
    const preVerify = await postJson('/v1/auth/password/login', {
      email,
      password,
    });
    expect(preVerify.status).toBe(401);

    const res = await postJson('/v1/auth/password/verify', { token });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { verified: boolean; user_id: string };
    expect(body.verified).toBe(true);
    expect(body.user_id).toBe(ctx.user_id);
  });

  // ── 3. Login ─────────────────────────────────────────────────────────────
  it('3. login → 200, returns an access_jwt (the session JWT) + refresh_token', async () => {
    const res = await postJson('/v1/auth/password/login', {
      email,
      password,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      access_jwt: string;
      refresh_token: string;
      user: { user_id: string; email: string; display_name: string };
    };
    expect(body.access_jwt.split('.')).toHaveLength(3);
    expect(body.refresh_token).toMatch(/^lm_refresh_[A-Za-z0-9_-]{32}$/);
    expect(body.user.user_id).toBe(ctx.user_id);
    expect(body.user.email).toBe(email);
    expect(body.user.display_name).toBe('Flow User');
    ctx.access_jwt = body.access_jwt;
    ctx.session_jwt = body.access_jwt;
    ctx.refresh_token = body.refresh_token;
  });

  // ── 4. List tokens (empty) ───────────────────────────────────────────────
  it('4. GET /v1/tokens with the session JWT → 200 and an empty token list', async () => {
    const res = await app.request('/v1/tokens', {
      headers: { authorization: `Bearer ${ctx.session_jwt}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      tier: string;
      tokens: Array<{ token_id: string }>;
    };
    // A freshly-signed-up account is on the trial tier with no PATs yet.
    expect(body.tier).toBe('trial');
    expect(body.tokens).toHaveLength(0);
  });

  // ── 5. Mint a PAT ────────────────────────────────────────────────────────
  it('5. POST /v1/tokens mints a PAT; plaintext shown once', async () => {
    const res = await postJson(
      '/v1/tokens',
      { name: 'Flow CLI' },
      { authorization: `Bearer ${ctx.session_jwt}` },
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      token_id: string;
      plaintext: string;
      name: string;
      scopes: string[];
    };
    expect(body.plaintext).toMatch(/^lm_pat_(live|test)_[A-Za-z0-9_-]{32}$/);
    expect(body.name).toBe('Flow CLI');
    expect(body.scopes).toEqual(['workouts:write', 'workouts:read']);
    ctx.pat = body.plaintext;
    ctx.pat_token_id = body.token_id;
  });

  it('5b. GET /v1/tokens now lists the minted PAT (no plaintext leaked)', async () => {
    const res = await app.request('/v1/tokens', {
      headers: { authorization: `Bearer ${ctx.session_jwt}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      tokens: Array<{ token_id: string; plaintext?: unknown; token_hash?: unknown }>;
    };
    const found = body.tokens.find((t) => t.token_id === ctx.pat_token_id);
    expect(found).toBeDefined();
    expect(found?.plaintext).toBeUndefined();
    expect(found?.token_hash).toBeUndefined();
  });

  // ── 6. Push a workout to the inbox via the PAT ───────────────────────────
  it('6. POST /v1/workouts with the PAT creates a pending inbox item', async () => {
    const res = await postJson(
      '/v1/workouts',
      { lmwf: VALID_LMWF },
      { authorization: `Bearer ${ctx.pat}` },
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      inbox_id: string;
      status: string;
      summary: { workoutName: string; exerciseCount: number; totalSetCount: number };
    };
    expect(body.inbox_id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(body.status).toBe('pending');
    expect(body.summary.workoutName).toBe('Push Day');
    expect(body.summary.exerciseCount).toBe(1);
    expect(body.summary.totalSetCount).toBe(3);
    ctx.inbox_id = body.inbox_id;
  });

  // ── 7. List inbox — assert the pushed item is present ────────────────────
  it('7. GET /v1/workouts lists the pushed item, tagged with the source PAT', async () => {
    const res = await app.request('/v1/workouts', {
      headers: { authorization: `Bearer ${ctx.pat}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      items: Array<{ inbox_id: string; status: string; source_token_id: string }>;
    };
    const found = body.items.find((i) => i.inbox_id === ctx.inbox_id);
    expect(found).toBeDefined();
    expect(found?.status).toBe('pending');
    expect(found?.source_token_id).toBe(ctx.pat_token_id);
  });

  it('7b. GET /v1/workouts/:id returns the fully-parsed workout payload', async () => {
    const res = await app.request(`/v1/workouts/${ctx.inbox_id}`, {
      headers: { authorization: `Bearer ${ctx.pat}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      workout: {
        name: string;
        exercises: Array<{ exerciseName: string; sets: unknown[] }>;
      };
    };
    expect(body.workout.name).toBe('Push Day');
    expect(body.workout.exercises).toHaveLength(1);
    expect(body.workout.exercises[0].exerciseName).toBe('Bench Press');
    expect(body.workout.exercises[0].sets).toHaveLength(3);
  });

  // ── 8. Ack the inbox item ────────────────────────────────────────────────
  it('8. POST /v1/workouts/:id/ack → 204 and the item flips to ingested', async () => {
    const ack = await app.request(`/v1/workouts/${ctx.inbox_id}/ack`, {
      method: 'POST',
      headers: { authorization: `Bearer ${ctx.pat}` },
    });
    expect(ack.status).toBe(204);

    const after = (await (
      await app.request(`/v1/workouts/${ctx.inbox_id}`, {
        headers: { authorization: `Bearer ${ctx.pat}` },
      })
    ).json()) as { status: string; ingested_at?: string };
    expect(after.status).toBe('ingested');
    expect(after.ingested_at).toBeDefined();
  });

  // ── 9. Push a completed session to the outbox via the PAT ────────────────
  it('9. POST /v1/workouts/outbox stores a completed-session envelope', async () => {
    ctx.client_session_id = `flow-sess-${Date.now()}-${Math.random()}`;
    const res = await postJson(
      '/v1/workouts/outbox',
      {
        client_session_id: ctx.client_session_id,
        source_device_id: 'iphone-flow-test',
        export: makeEnvelope('Push Day'),
      },
      { authorization: `Bearer ${ctx.pat}` },
    );
    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      outbox_id: string;
      client_session_id: string;
      session_name: string;
      dedup_hit: boolean;
    };
    expect(body.outbox_id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(body.client_session_id).toBe(ctx.client_session_id);
    expect(body.session_name).toBe('Push Day');
    expect(body.dedup_hit).toBe(false);
    ctx.outbox_id = body.outbox_id;
  });

  // ── 10. List outbox — assert the row is present with correct payload ─────
  it('10. GET /v1/workouts/outbox lists the pushed session', async () => {
    const res = await app.request('/v1/workouts/outbox', {
      headers: { authorization: `Bearer ${ctx.pat}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      items: Array<{ outbox_id: string; session_name: string; client_session_id: string }>;
    };
    const found = body.items.find((i) => i.outbox_id === ctx.outbox_id);
    expect(found).toBeDefined();
    expect(found?.session_name).toBe('Push Day');
    expect(found?.client_session_id).toBe(ctx.client_session_id);
  });

  // ── 11. Fetch outbox detail — full payload round-trips ───────────────────
  it('11. GET /v1/workouts/outbox/:id returns the full session payload', async () => {
    const res = await app.request(`/v1/workouts/outbox/${ctx.outbox_id}`, {
      headers: { authorization: `Bearer ${ctx.pat}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      payload: {
        session: {
          name: string;
          status: string;
          exercises: Array<{ exerciseName: string; sets: Array<{ actualReps: number }> }>;
        };
      };
    };
    expect(body.payload.session.name).toBe('Push Day');
    expect(body.payload.session.status).toBe('completed');
    expect(body.payload.session.exercises[0].exerciseName).toBe('Bench Press');
    expect(body.payload.session.exercises[0].sets[0].actualReps).toBe(5);
  });

  // ── 12. Cleanup: delete the outbox row ───────────────────────────────────
  it('12. DELETE /v1/workouts/outbox/:id removes the row (subsequent GET 404s)', async () => {
    const del = await app.request(`/v1/workouts/outbox/${ctx.outbox_id}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${ctx.pat}` },
    });
    expect(del.status).toBe(204);

    const after = await app.request(`/v1/workouts/outbox/${ctx.outbox_id}`, {
      headers: { authorization: `Bearer ${ctx.pat}` },
    });
    expect(after.status).toBe(404);
  });

  // ── 13. Cleanup: revoke the PAT ──────────────────────────────────────────
  it('13. DELETE /v1/tokens/:id revokes the PAT (session JWT, owner-scoped)', async () => {
    const del = await app.request(`/v1/tokens/${ctx.pat_token_id}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${ctx.session_jwt}` },
    });
    expect(del.status).toBe(204);

    const list = (await (
      await app.request('/v1/tokens', {
        headers: { authorization: `Bearer ${ctx.session_jwt}` },
      })
    ).json()) as { tokens: Array<{ token_id: string; revoked_at?: string }> };
    const found = list.tokens.find((t) => t.token_id === ctx.pat_token_id);
    expect(found?.revoked_at).toBeDefined();
  });

  // ── 14. Password-reset sub-flow + re-login ───────────────────────────────
  // The reset routes exist (POST /reset-request, POST /reset), so we walk
  // the full forgot-password journey and prove the new password works.
  it('14. password reset: request → email → reset → old pw fails, new pw logs in', async () => {
    await deleteAllMail();

    const reqRes = await postJson('/v1/auth/password/reset-request', {
      email,
    });
    // Always 204 (anti-enumeration), regardless of whether the email exists.
    expect(reqRes.status).toBe(204);

    const resetMail = await fetchMailTo(email);
    expect(resetMail.Subject).toMatch(/reset/i);
    const resetToken = extractToken(resetMail.Text || resetMail.HTML);

    const resetRes = await postJson('/v1/auth/password/reset', {
      token: resetToken,
      new_password: newPassword,
    });
    expect(resetRes.status).toBe(200);

    // Old password no longer works; new password does.
    const oldLogin = await postJson('/v1/auth/password/login', {
      email,
      password,
    });
    expect(oldLogin.status).toBe(401);

    const newLogin = await postJson('/v1/auth/password/login', {
      email,
      password: newPassword,
    });
    expect(newLogin.status).toBe(200);
    const body = (await newLogin.json()) as { user: { user_id: string } };
    expect(body.user.user_id).toBe(ctx.user_id);
  });
});

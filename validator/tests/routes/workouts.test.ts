import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { signJwt as SignJwt } from '../../src/infra/jwt.js';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';

const live = process.env.DDB_ENDPOINT ? describe : describe.skip;

const VALID_LMWF = `# Push Day
@tags: strength, upper
@units: lbs

## Bench Press
- 135 x 5
- 185 x 5
- 225 x 5
`;

const INVALID_LMWF = `Just some text with no header at all.`;

// A superset block (## Superset header + two ### exercise children). On read
// the server re-parses this from `lmwf_text` and must reproduce the grouping:
// both children carry `parentExerciseId` pointing at the superset parent.
const SUPERSET_LMWF = `# Arm Day
@units: lbs

## Superset: Arms

### Bicep Curl
- 30 x 12
- 30 x 12

### Tricep Pushdown
- 40 x 12
- 40 x 12
`;

live('Workout inbox routes (/v1/workouts)', () => {
  let originalSecret: string | undefined;
  let app: typeof import('../../src/app.js').app;
  let createUser: typeof import('../../src/repositories/users.js').createUser;
  let createToken: typeof import('../../src/repositories/pat_tokens.js').createToken;

  beforeAll(async () => {
    originalSecret = process.env.JWT_SECRET;
    process.env.JWT_SECRET = TEST_SECRET;
    ({ app } = await import('../../src/app.js'));
    ({ createUser } = await import('../../src/repositories/users.js'));
    ({ createToken } = await import('../../src/repositories/pat_tokens.js'));
  });

  afterAll(() => {
    if (originalSecret === undefined) {
      delete process.env.JWT_SECRET;
    } else {
      process.env.JWT_SECRET = originalSecret;
    }
  });

  function uniqueEmail(label: string): string {
    return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
  }

  async function mintUserAndPat(
    label: string,
    scopes: string[] = ['workouts:write', 'workouts:read'],
  ): Promise<{ user_id: string; plaintext: string; token_id: string }> {
    const user = await createUser({
      display_name: 'Workouts Tester',
      primary_email: uniqueEmail(label),
    });
    const { token, plaintext } = await createToken({
      user_id: user.user_id,
      name: label,
      scopes,
      mode: 'test',
    });
    return { user_id: user.user_id, plaintext, token_id: token.token_id };
  }

  it('POST /v1/workouts (JSON) creates a pending inbox item with a ULID id', async () => {
    const { plaintext, token_id } = await mintUserAndPat('push-json');

    const res = await app.request('/v1/workouts', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${plaintext}`,
      },
      body: JSON.stringify({ lmwf: VALID_LMWF }),
    });

    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      inbox_id: string;
      status: string;
      created_at: string;
      summary: { workoutName: string; exerciseCount: number; totalSetCount: number };
      warnings: string[];
    };
    expect(body.inbox_id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(body.status).toBe('pending');
    expect(body.summary.workoutName).toBe('Push Day');
    expect(body.summary.exerciseCount).toBe(1);
    expect(body.summary.totalSetCount).toBe(3);

    // Verify via GET list
    const listRes = await app.request('/v1/workouts', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(listRes.status).toBe(200);
    const list = (await listRes.json()) as {
      items: Array<{ inbox_id: string; source_token_id: string }>;
    };
    const found = list.items.find((i) => i.inbox_id === body.inbox_id);
    expect(found).toBeDefined();
    expect(found?.source_token_id).toBe(token_id);

    // The single-item GET should expose the FULL parsed payload via the
    // `workout` field — iOS rehydrates a WorkoutPlan from this without
    // needing a Swift-side LMWF parser.
    const singleRes = await app.request(`/v1/workouts/${body.inbox_id}`, {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(singleRes.status).toBe(200);
    const single = (await singleRes.json()) as {
      workout: {
        name: string;
        exercises: Array<{
          exerciseName: string;
          sets: Array<{ targetWeight: number | null; targetReps: number | null }>;
        }>;
      };
    };
    expect(single.workout).toBeDefined();
    expect(single.workout.name).toBe('Push Day');
    expect(single.workout.exercises).toHaveLength(1);
    expect(single.workout.exercises[0].exerciseName).toBe('Bench Press');
    expect(single.workout.exercises[0].sets).toHaveLength(3);
    // Spot-check that the full set data round-trips (not just the summary
    // projection: every set carries weight + reps from the source LMWF).
    expect(single.workout.exercises[0].sets[0].targetWeight).toBe(135);
    expect(single.workout.exercises[0].sets[0].targetReps).toBe(5);
    expect(single.workout.exercises[0].sets[2].targetWeight).toBe(225);
    expect(single.workout.exercises[0].sets[2].targetReps).toBe(5);
  });

  it('POST /v1/workouts (text/markdown) creates a pending inbox item', async () => {
    const { plaintext } = await mintUserAndPat('push-md');

    const res = await app.request('/v1/workouts', {
      method: 'POST',
      headers: {
        'content-type': 'text/markdown',
        authorization: `Bearer ${plaintext}`,
      },
      body: VALID_LMWF,
    });

    expect(res.status).toBe(201);
    const body = (await res.json()) as { inbox_id: string; status: string };
    expect(body.inbox_id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(body.status).toBe('pending');
  });

  it('POST with invalid LMWF returns 422 and does not enqueue', async () => {
    const { plaintext } = await mintUserAndPat('push-bad');

    const res = await app.request('/v1/workouts', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${plaintext}`,
      },
      body: JSON.stringify({ lmwf: INVALID_LMWF }),
    });

    expect(res.status).toBe(422);
    const body = (await res.json()) as {
      success: boolean;
      errors: string[];
      message: string;
    };
    expect(body.success).toBe(false);
    expect(body.errors.length).toBeGreaterThan(0);
    expect(body.message).toMatch(/did not parse/i);

    // Verify nothing was queued
    const listRes = await app.request('/v1/workouts', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    const list = (await listRes.json()) as { items: unknown[] };
    expect(list.items).toHaveLength(0);
  });

  it('POST exceeding 1MB returns 413', async () => {
    const { plaintext } = await mintUserAndPat('push-huge');

    // 1MB+1 of valid-ish content
    const huge = '# H\n## Bench\n- 135 x 5\n' + 'x'.repeat(1_048_577);
    const res = await app.request('/v1/workouts', {
      method: 'POST',
      headers: {
        'content-type': 'text/markdown',
        authorization: `Bearer ${plaintext}`,
      },
      body: huge,
    });
    expect(res.status).toBe(413);

    const listRes = await app.request('/v1/workouts', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    const list = (await listRes.json()) as { items: unknown[] };
    expect(list.items).toHaveLength(0);
  });

  it('GET /v1/workouts with no items returns empty list', async () => {
    const { plaintext } = await mintUserAndPat('empty');
    const res = await app.request('/v1/workouts', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      items: unknown[];
      next_cursor: string | null;
    };
    expect(body.items).toEqual([]);
    expect(body.next_cursor).toBeNull();
  });

  it('GET ?status=pending returns the item; ?status=ingested initially empty', async () => {
    const { plaintext } = await mintUserAndPat('status-filter');
    await app.request('/v1/workouts', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${plaintext}`,
      },
      body: JSON.stringify({ lmwf: VALID_LMWF }),
    });

    const pendingRes = await app.request('/v1/workouts?status=pending', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(pendingRes.status).toBe(200);
    const pending = (await pendingRes.json()) as { items: unknown[] };
    expect(pending.items).toHaveLength(1);

    const ingestedRes = await app.request('/v1/workouts?status=ingested', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(ingestedRes.status).toBe(200);
    const ingested = (await ingestedRes.json()) as { items: unknown[] };
    expect(ingested.items).toHaveLength(0);
  });

  it('GET /v1/workouts/:id returns full item with lmwf_text', async () => {
    const { plaintext } = await mintUserAndPat('get-single');
    const created = (await (
      await app.request('/v1/workouts', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${plaintext}`,
        },
        body: JSON.stringify({ lmwf: VALID_LMWF }),
      })
    ).json()) as { inbox_id: string };

    const res = await app.request(`/v1/workouts/${created.inbox_id}`, {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      inbox_id: string;
      lmwf_text: string;
      summary: { workoutName: string };
      workout: {
        name: string;
        defaultWeightUnit: string | null;
        tags: string[];
        exercises: Array<{
          exerciseName: string;
          sets: unknown[];
        }>;
      };
    };
    expect(body.inbox_id).toBe(created.inbox_id);
    expect(body.lmwf_text).toBe(VALID_LMWF);
    expect(body.summary.workoutName).toBe('Push Day');
    // `workout` exposes the full WorkoutPlan structure for iOS rehydration.
    expect(body.workout).toBeDefined();
    expect(body.workout.name).toBe('Push Day');
    expect(body.workout.defaultWeightUnit).toBe('lbs');
    expect(body.workout.tags).toEqual(['strength', 'upper']);
    expect(body.workout.exercises).toHaveLength(1);
    expect(body.workout.exercises[0].sets).toHaveLength(3);
  });

  it('GET /v1/workouts/:id derives `workout` from lmwf_text alone (no persisted parsed_json), grouping intact', async () => {
    // The server no longer stores a parsed payload — it persists only
    // `lmwf_text` and derives `workout`/`summary` by re-parsing on read.
    // This guards the #161 root cause: a superset's children must carry
    // `parentExerciseId` pointing at the superset parent. If derivation
    // ever regressed to dropping grouping, this would catch it.
    const { plaintext } = await mintUserAndPat('derive-superset');
    const created = (await (
      await app.request('/v1/workouts', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${plaintext}`,
        },
        body: JSON.stringify({ lmwf: SUPERSET_LMWF }),
      })
    ).json()) as { inbox_id: string };

    const res = await app.request(`/v1/workouts/${created.inbox_id}`, {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      lmwf_text: string;
      summary: {
        exercises: Array<{
          name: string;
          groupType: string | null;
          groupName: string | null;
          parentExerciseId: string | null;
        }>;
      };
      workout: {
        exercises: Array<{
          id: string;
          exerciseName: string;
          groupType: string | null;
          groupName: string | null;
          parentExerciseId: string | null;
        }>;
      };
    };

    // Raw markdown still round-trips.
    expect(body.lmwf_text).toBe(SUPERSET_LMWF);

    // Derived plan exposes the superset parent + its two children.
    const exs = body.workout.exercises;
    expect(exs).toHaveLength(3);

    // The superset parent has no parent of its own and carries the grouping.
    const parent = exs.find((e) => e.groupType === 'superset' && !e.parentExerciseId);
    expect(parent).toBeDefined();
    expect(parent?.groupName).toBe('Superset: Arms');

    const children = exs.filter((e) => e.parentExerciseId);
    expect(children).toHaveLength(2);
    // Both children point at the superset parent — the grouping link the
    // old hand-written bridge dropped (#161 / #145).
    for (const child of children) {
      expect(child.parentExerciseId).toBe(parent?.id);
    }
    expect(children.map((c) => c.exerciseName).sort()).toEqual([
      'Bicep Curl',
      'Tricep Pushdown',
    ]);

    // The lightweight summary projection carries the same grouping fields.
    const sumChildren = body.summary.exercises.filter((e) => e.parentExerciseId);
    expect(sumChildren).toHaveLength(2);
  });

  it('GET /v1/workouts/:id non-existent returns 404', async () => {
    const { plaintext } = await mintUserAndPat('get-missing');
    const res = await app.request('/v1/workouts/01ABCDEF0000000000000NOPE0', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(404);
  });

  it('POST /:id/ack marks ingested and is 204; subsequent GET shows status', async () => {
    const { plaintext } = await mintUserAndPat('ack');
    const created = (await (
      await app.request('/v1/workouts', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${plaintext}`,
        },
        body: JSON.stringify({ lmwf: VALID_LMWF }),
      })
    ).json()) as { inbox_id: string };

    const ack = await app.request(`/v1/workouts/${created.inbox_id}/ack`, {
      method: 'POST',
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(ack.status).toBe(204);

    const after = (await (
      await app.request(`/v1/workouts/${created.inbox_id}`, {
        headers: { authorization: `Bearer ${plaintext}` },
      })
    ).json()) as { status: string; ingested_at?: string };
    expect(after.status).toBe('ingested');
    expect(after.ingested_at).toBeDefined();
  });

  it('POST /:id/ack on non-existent returns 404', async () => {
    const { plaintext } = await mintUserAndPat('ack-missing');
    const res = await app.request(
      '/v1/workouts/01ABCDEF0000000000000NOPE0/ack',
      {
        method: 'POST',
        headers: { authorization: `Bearer ${plaintext}` },
      },
    );
    expect(res.status).toBe(404);
  });

  it('DELETE /:id removes the row; subsequent GET returns 404', async () => {
    const { plaintext } = await mintUserAndPat('del');
    const created = (await (
      await app.request('/v1/workouts', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${plaintext}`,
        },
        body: JSON.stringify({ lmwf: VALID_LMWF }),
      })
    ).json()) as { inbox_id: string };

    const del = await app.request(`/v1/workouts/${created.inbox_id}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(del.status).toBe(204);

    const after = await app.request(`/v1/workouts/${created.inbox_id}`, {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(after.status).toBe(404);
  });

  it('DELETE /:id on non-existent returns 404', async () => {
    const { plaintext } = await mintUserAndPat('del-missing');
    const res = await app.request(
      '/v1/workouts/01ABCDEF0000000000000NOPE0',
      {
        method: 'DELETE',
        headers: { authorization: `Bearer ${plaintext}` },
      },
    );
    expect(res.status).toBe(404);
  });

  it('DELETE /:id belonging to another user returns 404, leaves row intact', async () => {
    // User A creates a workout
    const { plaintext: aPat } = await mintUserAndPat('del-cross-a');
    const created = (await (
      await app.request('/v1/workouts', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${aPat}`,
        },
        body: JSON.stringify({ lmwf: VALID_LMWF }),
      })
    ).json()) as { inbox_id: string };

    // User B tries to delete it
    const { plaintext: bPat } = await mintUserAndPat('del-cross-b');
    const del = await app.request(`/v1/workouts/${created.inbox_id}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${bPat}` },
    });
    expect(del.status).toBe(404);

    // User A can still see it
    const after = await app.request(`/v1/workouts/${created.inbox_id}`, {
      headers: { authorization: `Bearer ${aPat}` },
    });
    expect(after.status).toBe(200);
  });

  it('without PAT returns 401', async () => {
    const post = await app.request('/v1/workouts', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ lmwf: VALID_LMWF }),
    });
    expect(post.status).toBe(401);

    const get = await app.request('/v1/workouts');
    expect(get.status).toBe(401);
  });

  it('PAT missing workouts:write returns 403 on POST', async () => {
    const { plaintext } = await mintUserAndPat('read-only', ['workouts:read']);
    const res = await app.request('/v1/workouts', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${plaintext}`,
      },
      body: JSON.stringify({ lmwf: VALID_LMWF }),
    });
    expect(res.status).toBe(403);

    // Read still works.
    const get = await app.request('/v1/workouts', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(get.status).toBe(200);
  });

  it('pagination: limit=2 over 3 items yields next_cursor and second page returns the rest', async () => {
    const { plaintext } = await mintUserAndPat('pagination');
    for (let i = 0; i < 3; i++) {
      const res = await app.request('/v1/workouts', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${plaintext}`,
        },
        body: JSON.stringify({ lmwf: VALID_LMWF }),
      });
      expect(res.status).toBe(201);
      // Spread created_at slightly so the ULID sort is unambiguous.
      await new Promise((r) => setTimeout(r, 5));
    }

    const page1Res = await app.request('/v1/workouts?limit=2', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(page1Res.status).toBe(200);
    const page1 = (await page1Res.json()) as {
      items: Array<{ inbox_id: string }>;
      next_cursor: string | null;
    };
    expect(page1.items).toHaveLength(2);
    expect(page1.next_cursor).not.toBeNull();

    const page2Res = await app.request(
      `/v1/workouts?limit=2&since=${encodeURIComponent(page1.next_cursor!)}`,
      { headers: { authorization: `Bearer ${plaintext}` } },
    );
    expect(page2Res.status).toBe(200);
    const page2 = (await page2Res.json()) as {
      items: Array<{ inbox_id: string }>;
      next_cursor: string | null;
    };
    expect(page2.items).toHaveLength(1);
    expect(page2.next_cursor).toBeNull();

    const seen = new Set(
      [...page1.items, ...page2.items].map((i) => i.inbox_id),
    );
    expect(seen.size).toBe(3);
  });
});

// ──────────────────────────────────────────────────────────────────────
// Same surface, exercised with session JWT auth instead of PATs. This is
// what the web dashboard uses; sessions implicitly satisfy any scope.
// ──────────────────────────────────────────────────────────────────────
live('Workout inbox routes (/v1/workouts) — session JWT auth', () => {
  let originalSecret: string | undefined;
  let app: typeof import('../../src/app.js').app;
  let createUser: typeof import('../../src/repositories/users.js').createUser;
  let signJwt: typeof SignJwt;

  beforeAll(async () => {
    originalSecret = process.env.JWT_SECRET;
    process.env.JWT_SECRET = TEST_SECRET;
    ({ app } = await import('../../src/app.js'));
    ({ createUser } = await import('../../src/repositories/users.js'));
    ({ signJwt } = await import('../../src/infra/jwt.js'));
  });

  afterAll(() => {
    if (originalSecret === undefined) {
      delete process.env.JWT_SECRET;
    } else {
      process.env.JWT_SECRET = originalSecret;
    }
  });

  function uniqueEmail(label: string): string {
    return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
  }

  async function mintUserAndSession(
    label: string,
  ): Promise<{ user_id: string; jwt: string }> {
    const user = await createUser({
      display_name: 'Session Tester',
      primary_email: uniqueEmail(label),
    });
    const jwt = signJwt(
      {
        sub: user.user_id,
        identity_id: `identity-${user.user_id}`,
        type: 'access',
        authn_age: 'fresh',
      },
      '1h',
    );
    return { user_id: user.user_id, jwt };
  }

  it('POST /v1/workouts (JSON) with session JWT enqueues with source_token_id="session"', async () => {
    const { jwt } = await mintUserAndSession('sess-push-json');

    const res = await app.request('/v1/workouts', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${jwt}`,
      },
      body: JSON.stringify({ lmwf: VALID_LMWF }),
    });

    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      inbox_id: string;
      status: string;
      summary: { workoutName: string };
    };
    expect(body.inbox_id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(body.status).toBe('pending');
    expect(body.summary.workoutName).toBe('Push Day');

    // Verify the sentinel source_token_id via GET list.
    const listRes = await app.request('/v1/workouts', {
      headers: { authorization: `Bearer ${jwt}` },
    });
    expect(listRes.status).toBe(200);
    const list = (await listRes.json()) as {
      items: Array<{ inbox_id: string; source_token_id: string }>;
    };
    const found = list.items.find((i) => i.inbox_id === body.inbox_id);
    expect(found).toBeDefined();
    expect(found?.source_token_id).toBe('session');
  });

  it('POST /v1/workouts (text/markdown) with session JWT enqueues', async () => {
    const { jwt } = await mintUserAndSession('sess-push-md');
    const res = await app.request('/v1/workouts', {
      method: 'POST',
      headers: {
        'content-type': 'text/markdown',
        authorization: `Bearer ${jwt}`,
      },
      body: VALID_LMWF,
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { inbox_id: string };
    expect(body.inbox_id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
  });

  it('POST with invalid LMWF returns 422 under session auth', async () => {
    const { jwt } = await mintUserAndSession('sess-push-bad');
    const res = await app.request('/v1/workouts', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${jwt}`,
      },
      body: JSON.stringify({ lmwf: INVALID_LMWF }),
    });
    expect(res.status).toBe(422);
  });

  it('GET /v1/workouts with session JWT lists the user’s items', async () => {
    const { jwt } = await mintUserAndSession('sess-list');
    await app.request('/v1/workouts', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${jwt}`,
      },
      body: JSON.stringify({ lmwf: VALID_LMWF }),
    });
    const res = await app.request('/v1/workouts', {
      headers: { authorization: `Bearer ${jwt}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: unknown[] };
    expect(body.items).toHaveLength(1);
  });

  it('GET /v1/workouts/:id with session JWT returns full item', async () => {
    const { jwt } = await mintUserAndSession('sess-single');
    const created = (await (
      await app.request('/v1/workouts', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${jwt}`,
        },
        body: JSON.stringify({ lmwf: VALID_LMWF }),
      })
    ).json()) as { inbox_id: string };

    const res = await app.request(`/v1/workouts/${created.inbox_id}`, {
      headers: { authorization: `Bearer ${jwt}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      inbox_id: string;
      lmwf_text: string;
    };
    expect(body.inbox_id).toBe(created.inbox_id);
    expect(body.lmwf_text).toBe(VALID_LMWF);
  });

  it('POST /:id/ack with session JWT marks ingested', async () => {
    const { jwt } = await mintUserAndSession('sess-ack');
    const created = (await (
      await app.request('/v1/workouts', {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${jwt}`,
        },
        body: JSON.stringify({ lmwf: VALID_LMWF }),
      })
    ).json()) as { inbox_id: string };

    const ack = await app.request(`/v1/workouts/${created.inbox_id}/ack`, {
      method: 'POST',
      headers: { authorization: `Bearer ${jwt}` },
    });
    expect(ack.status).toBe(204);

    const after = (await (
      await app.request(`/v1/workouts/${created.inbox_id}`, {
        headers: { authorization: `Bearer ${jwt}` },
      })
    ).json()) as { status: string };
    expect(after.status).toBe('ingested');
  });

  it('garbage Bearer token returns 401 (not a PAT, not a JWT)', async () => {
    const res = await app.request('/v1/workouts', {
      headers: { authorization: 'Bearer not-a-real-token' },
    });
    expect(res.status).toBe(401);
  });
});

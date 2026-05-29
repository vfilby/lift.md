import { describe, it, expect, beforeAll, afterAll } from 'vitest';

const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';
const live = process.env.DDB_ENDPOINT ? describe : describe.skip;

interface ExportEnvelope {
  exportedAt: string;
  appVersion: string;
  session: {
    name: string;
    date: string;
    startTime: string;
    endTime: string;
    duration: number;
    status: 'completed';
    exercises: Array<{
      exerciseName: string;
      orderIndex: number;
      status: string;
      sets: Array<Record<string, unknown>>;
    }>;
  };
}

function makeEnvelope(name = 'Push Day'): ExportEnvelope {
  return {
    exportedAt: new Date().toISOString(),
    appVersion: '1.6.3-test',
    session: {
      name,
      date: '2026-05-25',
      startTime: '2026-05-25T17:35:00Z',
      endTime: '2026-05-25T18:28:00Z',
      duration: 3180,
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

live('Workout outbox routes (/v1/workouts/outbox)', () => {
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
      display_name: 'Outbox Tester',
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

  it('POST creates an outbox item from an export envelope', async () => {
    const { plaintext } = await mintUserAndPat('push');

    const res = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${plaintext}`,
      },
      body: JSON.stringify({
        client_session_id: `sess-${Date.now()}`,
        source_device_id: 'iphone-test',
        export: makeEnvelope(),
      }),
    });

    expect(res.status).toBe(201);
    const body = (await res.json()) as {
      outbox_id: string;
      client_session_id: string;
      session_name: string;
      dedup_hit: boolean;
    };
    expect(body.outbox_id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(body.session_name).toBe('Push Day');
    expect(body.dedup_hit).toBe(false);
  });

  it('POST with same client_session_id is dedup-hit', async () => {
    const { plaintext } = await mintUserAndPat('dedup');
    const csid = `sess-${Date.now()}-${Math.random()}`;
    const env = makeEnvelope('First');

    const r1 = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${plaintext}` },
      body: JSON.stringify({ client_session_id: csid, export: env }),
    });
    expect(r1.status).toBe(201);
    const b1 = (await r1.json()) as { outbox_id: string };

    const r2 = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${plaintext}` },
      body: JSON.stringify({ client_session_id: csid, export: makeEnvelope('Second') }),
    });
    expect(r2.status).toBe(200);
    const b2 = (await r2.json()) as { outbox_id: string; dedup_hit: boolean; session_name: string };
    expect(b2.dedup_hit).toBe(true);
    expect(b2.outbox_id).toBe(b1.outbox_id);
    // First push wins.
    expect(b2.session_name).toBe('First');
  });

  it('POST rejects non-completed sessions', async () => {
    const { plaintext } = await mintUserAndPat('rej');
    const env = makeEnvelope();
    // @ts-expect-error — intentionally invalid for the test
    env.session.status = 'in_progress';

    const res = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${plaintext}` },
      body: JSON.stringify({ client_session_id: `s-${Date.now()}`, export: env }),
    });
    expect(res.status).toBe(422);
  });

  it('POST requires client_session_id', async () => {
    const { plaintext } = await mintUserAndPat('noid');

    const res = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${plaintext}` },
      body: JSON.stringify({ export: makeEnvelope() }),
    });
    expect(res.status).toBe(400);
  });

  it('GET lists the user\'s items newest-first', async () => {
    const { plaintext } = await mintUserAndPat('list');

    const csid1 = `s1-${Date.now()}-${Math.random()}`;
    const csid2 = `s2-${Date.now()}-${Math.random()}`;
    await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${plaintext}` },
      body: JSON.stringify({ client_session_id: csid1, export: makeEnvelope('First') }),
    });
    await new Promise((r) => setTimeout(r, 5));
    await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${plaintext}` },
      body: JSON.stringify({ client_session_id: csid2, export: makeEnvelope('Second') }),
    });

    const listRes = await app.request('/v1/workouts/outbox', {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(listRes.status).toBe(200);
    const list = (await listRes.json()) as {
      items: Array<{ outbox_id: string; session_name: string; client_session_id: string }>;
    };
    expect(list.items.length).toBeGreaterThanOrEqual(2);
    expect(list.items[0].session_name).toBe('Second');
    expect(list.items[1].session_name).toBe('First');
  });

  it('GET /:id returns the full payload', async () => {
    const { plaintext } = await mintUserAndPat('detail');

    const postRes = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${plaintext}` },
      body: JSON.stringify({ client_session_id: `s-${Date.now()}`, export: makeEnvelope() }),
    });
    const { outbox_id } = (await postRes.json()) as { outbox_id: string };

    const res = await app.request(`/v1/workouts/outbox/${outbox_id}`, {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { payload: { session: { name: string } } };
    expect(body.payload.session.name).toBe('Push Day');
  });

  it('GET /:id 404s for a foreign user\'s item (no existence leak)', async () => {
    const owner = await mintUserAndPat('owner');
    const stranger = await mintUserAndPat('stranger');

    const postRes = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${owner.plaintext}` },
      body: JSON.stringify({ client_session_id: `s-${Date.now()}`, export: makeEnvelope() }),
    });
    const { outbox_id } = (await postRes.json()) as { outbox_id: string };

    const res = await app.request(`/v1/workouts/outbox/${outbox_id}`, {
      headers: { authorization: `Bearer ${stranger.plaintext}` },
    });
    expect(res.status).toBe(404);
  });

  it('DELETE removes the row', async () => {
    const { plaintext } = await mintUserAndPat('del');

    const postRes = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${plaintext}` },
      body: JSON.stringify({ client_session_id: `s-${Date.now()}`, export: makeEnvelope() }),
    });
    const { outbox_id } = (await postRes.json()) as { outbox_id: string };

    const delRes = await app.request(`/v1/workouts/outbox/${outbox_id}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(delRes.status).toBe(204);

    const getRes = await app.request(`/v1/workouts/outbox/${outbox_id}`, {
      headers: { authorization: `Bearer ${plaintext}` },
    });
    expect(getRes.status).toBe(404);
  });

  it('read-only PAT cannot delete (403) — destructive action requires workouts:write', async () => {
    // Owner (full scopes) creates an item.
    const owner = await mintUserAndPat('ro-del-owner');
    const postRes = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${owner.plaintext}` },
      body: JSON.stringify({ client_session_id: `s-${Date.now()}-${Math.random()}`, export: makeEnvelope() }),
    });
    const { outbox_id } = (await postRes.json()) as { outbox_id: string };

    // A read-only PAT for the SAME user must not be able to delete it.
    const readOnly = await createToken({
      user_id: owner.user_id,
      name: 'ro-del',
      scopes: ['workouts:read'],
      mode: 'test',
    });
    const del = await app.request(`/v1/workouts/outbox/${outbox_id}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${readOnly.plaintext}` },
    });
    expect(del.status).toBe(403);

    // Row survives.
    const get = await app.request(`/v1/workouts/outbox/${outbox_id}`, {
      headers: { authorization: `Bearer ${owner.plaintext}` },
    });
    expect(get.status).toBe(200);
  });

  it("user A cannot delete user B's outbox item (404), B's item survives", async () => {
    const userA = await mintUserAndPat('idor-del-a');
    const userB = await mintUserAndPat('idor-del-b');
    const postRes = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${userB.plaintext}` },
      body: JSON.stringify({ client_session_id: `s-${Date.now()}-${Math.random()}`, export: makeEnvelope() }),
    });
    const { outbox_id } = (await postRes.json()) as { outbox_id: string };

    const del = await app.request(`/v1/workouts/outbox/${outbox_id}`, {
      method: 'DELETE',
      headers: { authorization: `Bearer ${userA.plaintext}` },
    });
    expect(del.status).toBe(404);

    // B can still read it.
    const get = await app.request(`/v1/workouts/outbox/${outbox_id}`, {
      headers: { authorization: `Bearer ${userB.plaintext}` },
    });
    expect(get.status).toBe(200);
  });

  it('write-scope is enforced separately from read-scope on POST', async () => {
    const { plaintext } = await mintUserAndPat('read-only', ['workouts:read']);

    const res = await app.request('/v1/workouts/outbox', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${plaintext}` },
      body: JSON.stringify({ client_session_id: `s-${Date.now()}`, export: makeEnvelope() }),
    });
    expect(res.status).toBe(403);
  });

  it('rejects requests with no auth', async () => {
    const res = await app.request('/v1/workouts/outbox', {
      headers: {},
    });
    expect(res.status).toBe(401);
  });
});

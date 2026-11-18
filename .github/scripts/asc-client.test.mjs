// Unit tests for the transient-failure retry policy in asc-client.mjs.
// Run: node --test .github/scripts/*.test.mjs   (no dependencies; node:test is built in)

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchWithRetry } from './asc-client.mjs';

function response(status, { headers = {}, body = '' } = {}) {
  return new Response(body, { status, headers });
}

// Builds a fake fetch that replays `outcomes` in order. An outcome is either a
// Response or an Error (which is thrown, simulating a network failure).
function scripted(outcomes) {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    const next = outcomes.shift();
    if (next instanceof Error) throw next;
    return next;
  };
  return { fetchImpl, calls };
}

function harness(outcomes, overrides = {}) {
  const { fetchImpl, calls } = scripted(outcomes);
  const sleeps = [];
  const logs = [];
  const opts = {
    fetchImpl,
    sleep: async (ms) => { sleeps.push(ms); },
    log: (m) => logs.push(m),
    ...overrides,
  };
  return { opts, calls, sleeps, logs };
}

test('returns immediately on a 2xx without sleeping', async () => {
  const h = harness([response(200, { body: '{"ok":true}' })]);
  const res = await fetchWithRetry('https://example.test/x', {}, h.opts);
  assert.equal(res.status, 200);
  assert.equal(h.calls.length, 1);
  assert.deepEqual(h.sleeps, []);
  assert.deepEqual(h.logs, []);
});

test('retries a 500 with exponential backoff and returns the eventual success', async () => {
  const h = harness([response(500), response(502), response(200)]);
  const res = await fetchWithRetry('https://example.test/x', {}, h.opts);
  assert.equal(res.status, 200);
  assert.equal(h.calls.length, 3);
  assert.deepEqual(h.sleeps, [1000, 2000]);
  assert.equal(h.logs.length, 2);
  assert.match(h.logs[0], /500; retrying in 1000ms \(attempt 1\/4\)/);
});

test('gives up after `attempts` and resolves with the last non-ok response', async () => {
  const h = harness([response(503), response(503), response(503), response(503)]);
  const res = await fetchWithRetry('https://example.test/x', {}, h.opts);
  assert.equal(res.status, 503);
  assert.equal(h.calls.length, 4);
  assert.deepEqual(h.sleeps, [1000, 2000, 4000]);
});

test('does not retry non-transient 4xx such as 404 and 409', async () => {
  for (const status of [400, 401, 403, 404, 409, 422]) {
    const h = harness([response(status), response(200)]);
    const res = await fetchWithRetry('https://example.test/x', {}, h.opts);
    assert.equal(res.status, status, `status ${status} should be returned as-is`);
    assert.equal(h.calls.length, 1, `status ${status} should not be retried`);
    assert.deepEqual(h.sleeps, []);
  }
});

test('honours a numeric Retry-After header on 429', async () => {
  const h = harness([response(429, { headers: { 'retry-after': '7' } }), response(200)]);
  const res = await fetchWithRetry('https://example.test/x', {}, h.opts);
  assert.equal(res.status, 200);
  assert.deepEqual(h.sleeps, [7000]);
});

test('caps Retry-After and backoff at maxDelayMs', async () => {
  const h = harness([response(429, { headers: { 'retry-after': '600' } }), response(500), response(200)], {
    maxDelayMs: 5000,
    baseDelayMs: 4000,
  });
  await fetchWithRetry('https://example.test/x', {}, h.opts);
  // 600s Retry-After capped to 5s; second backoff 4000*2 = 8000 capped to 5s.
  assert.deepEqual(h.sleeps, [5000, 5000]);
});

test('falls back to backoff when Retry-After is unparseable', async () => {
  const h = harness([response(429, { headers: { 'retry-after': 'soon' } }), response(200)]);
  await fetchWithRetry('https://example.test/x', {}, h.opts);
  assert.deepEqual(h.sleeps, [1000]);
});

test('retries network errors and rethrows only after the final attempt', async () => {
  const boom = () => Object.assign(new Error('fetch failed'), { code: 'ECONNRESET' });
  const ok = harness([boom(), response(200)]);
  const res = await fetchWithRetry('https://example.test/x', {}, ok.opts);
  assert.equal(res.status, 200);
  assert.deepEqual(ok.sleeps, [1000]);
  assert.match(ok.logs[0], /fetch failed; retrying/);

  const bad = harness([boom(), boom(), boom()], { attempts: 3 });
  await assert.rejects(() => fetchWithRetry('https://example.test/x', {}, bad.opts), /fetch failed/);
  assert.equal(bad.calls.length, 3);
  assert.deepEqual(bad.sleeps, [1000, 2000]);
});

test('passes the same url and init to every attempt', async () => {
  const init = { method: 'POST', body: '{"a":1}', headers: { Authorization: 'Bearer t' } };
  const h = harness([response(500), response(201)]);
  await fetchWithRetry('https://example.test/create', init, h.opts);
  assert.equal(h.calls.length, 2);
  for (const call of h.calls) {
    assert.equal(call.url, 'https://example.test/create');
    assert.deepEqual(call.init, init);
  }
});

test('uses the custom label in log lines', async () => {
  const h = harness([response(500), response(200)], { label: 'ASC GET /apps' });
  await fetchWithRetry('https://example.test/apps', {}, h.opts);
  assert.match(h.logs[0], /^ASC GET \/apps → 500/);
});

test('rejects attempts < 1', async () => {
  await assert.rejects(() => fetchWithRetry('https://example.test/x', {}, { attempts: 0 }), /attempts must be >= 1/);
});

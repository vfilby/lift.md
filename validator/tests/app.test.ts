import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { app } from '../src/app.js';

// These tests hit the Hono app directly (no Lambda adapter), proving the
// same code runs unchanged in local dev mode via @hono/node-server.

describe('Hono app — /version', () => {
  const savedEnv: Record<string, string | undefined> = {};
  beforeEach(() => {
    savedEnv.BUILD_COMMIT = process.env.BUILD_COMMIT;
    savedEnv.BUILD_TIMESTAMP = process.env.BUILD_TIMESTAMP;
    savedEnv.LMWF_ENV = process.env.LMWF_ENV;
    process.env.BUILD_COMMIT = 'test-commit-abc123';
    process.env.BUILD_TIMESTAMP = '2026-05-24T13:37:00Z';
    process.env.LMWF_ENV = 'test';
  });
  afterEach(() => {
    process.env.BUILD_COMMIT = savedEnv.BUILD_COMMIT;
    process.env.BUILD_TIMESTAMP = savedEnv.BUILD_TIMESTAMP;
    process.env.LMWF_ENV = savedEnv.LMWF_ENV;
  });

  it('returns commit, builtAt, env from process.env', async () => {
    const res = await app.request('/version', { method: 'GET' });
    expect(res.status).toBe(200);
    expect(res.headers.get('cache-control')).toBe('no-store');
    const body = (await res.json()) as {
      commit: string;
      builtAt: string;
      env: string;
    };
    expect(body).toEqual({
      commit: 'test-commit-abc123',
      builtAt: '2026-05-24T13:37:00Z',
      env: 'test',
    });
  });

  it('defaults to "unknown" when env vars are unset', async () => {
    delete process.env.BUILD_COMMIT;
    delete process.env.BUILD_TIMESTAMP;
    delete process.env.LMWF_ENV;
    const res = await app.request('/version', { method: 'GET' });
    const body = (await res.json()) as {
      commit: string;
      builtAt: string;
      env: string;
    };
    expect(body).toEqual({
      commit: 'unknown',
      builtAt: 'unknown',
      env: 'unknown',
    });
  });
});

describe('Hono app — /validate', () => {
  it('attaches X-Validator-Version header from BUILD_COMMIT', async () => {
    const saved = process.env.BUILD_COMMIT;
    process.env.BUILD_COMMIT = 'header-commit-xyz';
    try {
      const res = await app.request('/validate', {
        method: 'POST',
        headers: { 'content-type': 'text/markdown' },
        body: '# Workout\n## Squat\n- 135 x 5',
      });
      expect(res.headers.get('x-validator-version')).toBe('header-commit-xyz');
    } finally {
      process.env.BUILD_COMMIT = saved;
    }
  });

  it('returns 200 for a valid workout (JSON body)', async () => {
    const markdown = `# Test Workout
@units: lbs
## Bench Press
- 225 x 5`;
    const res = await app.request('/validate', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ markdown }),
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      success: boolean;
      summary: { workoutName: string; defaultWeightUnit: string | null } | null;
    };
    expect(body.success).toBe(true);
    expect(body.summary?.workoutName).toBe('Test Workout');
    expect(body.summary?.defaultWeightUnit).toBe('lbs');
  });

  it('returns 200 for raw text/markdown body', async () => {
    const markdown = `# Workout
## Squat
- 135 x 5`;
    const res = await app.request('/validate', {
      method: 'POST',
      headers: { 'content-type': 'text/markdown' },
      body: markdown,
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      success: boolean;
      summary: { workoutName: string } | null;
    };
    expect(body.success).toBe(true);
    expect(body.summary?.workoutName).toBe('Workout');
  });

  it('returns 400 for invalid JSON in ValidateResponse shape', async () => {
    const res = await app.request('/validate', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: 'not json',
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      success: boolean;
      summary: unknown;
      errors: string[];
      warnings: string[];
    };
    expect(body.success).toBe(false);
    expect(body.summary).toBeNull();
    expect(body.errors).toEqual(['Invalid JSON body']);
    expect(body.warnings).toEqual([]);
  });

  it('returns 400 for non-string markdown field in ValidateResponse shape', async () => {
    const res = await app.request('/validate', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ markdown: 42 }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      success: boolean;
      errors: string[];
    };
    expect(body.success).toBe(false);
    expect(body.errors).toEqual(['markdown field must be a string']);
  });

  it('returns 400 for empty markdown field in ValidateResponse shape', async () => {
    const res = await app.request('/validate', {
      method: 'POST',
      headers: { 'content-type': 'text/markdown' },
      body: '',
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      success: boolean;
      summary: unknown;
      errors: string[];
    };
    expect(body.success).toBe(false);
    expect(body.summary).toBeNull();
    expect(body.errors).toEqual(['Missing or empty markdown field']);
  });

  it('returns 400 for whitespace-only markdown in ValidateResponse shape', async () => {
    const res = await app.request('/validate', {
      method: 'POST',
      headers: { 'content-type': 'text/markdown' },
      body: '   \n\t  \n',
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      success: boolean;
      errors: string[];
    };
    expect(body.success).toBe(false);
    expect(body.errors).toEqual(['Missing or empty markdown field']);
  });

  it('returns 400 for missing body (JSON content-type) in ValidateResponse shape', async () => {
    const res = await app.request('/validate', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '',
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as {
      success: boolean;
      errors: string[];
    };
    expect(body.success).toBe(false);
    expect(body.errors).toEqual(['Missing request body']);
  });

  it('returns 413 for oversized input', async () => {
    const markdown =
      '# Workout\n## Exercise\n- 100 x 5\n' + 'x'.repeat(1_048_577);
    const res = await app.request('/validate', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ markdown }),
    });
    expect(res.status).toBe(413);
    const body = (await res.json()) as {
      success: boolean;
      errors: string[];
    };
    expect(body.success).toBe(false);
    expect(body.errors).toEqual(['Input exceeds maximum size of 1MB']);
  });
});

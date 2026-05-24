import { describe, it, expect } from 'vitest';
import { app } from '../src/app.js';

// These tests hit the Hono app directly (no Lambda adapter), proving the
// same code runs unchanged in local dev mode via @hono/node-server.

describe('Hono app — /validate', () => {
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

import { describe, it, expect } from 'vitest';
import { handler } from '../src/handler.js';
import type { ApiGatewayRequestContextV2 } from 'hono/aws-lambda';

// Mirror of Hono's internal APIGatewayProxyEventV2 (not exported by the
// adapter). Synthesizes the event shape its Lambda handler expects.
interface ApiGwV2Event {
  version: string;
  routeKey: string;
  headers: Record<string, string | undefined>;
  cookies?: string[];
  rawPath: string;
  rawQueryString: string;
  body: string | null;
  isBase64Encoded: boolean;
  requestContext: ApiGatewayRequestContextV2;
  queryStringParameters?: Record<string, string | undefined>;
  pathParameters?: Record<string, string | undefined>;
  stageVariables?: Record<string, string | undefined>;
}

function makeEvent(overrides: Partial<ApiGwV2Event> = {}): ApiGwV2Event {
  return {
    version: '2.0',
    routeKey: 'POST /validate',
    rawPath: '/validate',
    rawQueryString: '',
    headers: { 'content-type': 'application/json' },
    requestContext: {
      accountId: '123456789012',
      apiId: 'test',
      domainName: 'test.execute-api.us-east-1.amazonaws.com',
      domainPrefix: 'test',
      http: {
        method: 'POST',
        path: '/validate',
        protocol: 'HTTP/1.1',
        sourceIp: '127.0.0.1',
        userAgent: 'test',
      },
      requestId: 'test-id',
      routeKey: 'POST /validate',
      stage: '$default',
      time: '01/Jan/2026:00:00:00 +0000',
      timeEpoch: 0,
    },
    isBase64Encoded: false,
    body: null,
    ...overrides,
  } as ApiGwV2Event;
}

function parseBody(result: { body?: string }): any {
  return JSON.parse(result.body ?? '{}');
}

describe('Lambda Handler', () => {
  it('returns 400 for missing body', async () => {
    const event = makeEvent({ body: null });
    const result = await handler(event);
    expect(result).toHaveProperty('statusCode', 400);
  });

  it('returns 400 for empty markdown', async () => {
    const event = makeEvent({ body: JSON.stringify({ markdown: '' }) });
    const result = await handler(event);
    expect(result).toHaveProperty('statusCode', 400);
  });

  it('returns 400 for missing markdown field', async () => {
    const event = makeEvent({ body: JSON.stringify({}) });
    const result = await handler(event);
    expect(result).toHaveProperty('statusCode', 400);
  });

  it('returns 400 for invalid JSON', async () => {
    const event = makeEvent({ body: 'not json' });
    const result = await handler(event);
    expect(result).toHaveProperty('statusCode', 400);
  });

  it('returns 200 with successful parse', async () => {
    const markdown = `# Test Workout
@units: lbs
@tags: strength

## Bench Press
- 225 x 5
- 245 x 3`;
    const event = makeEvent({ body: JSON.stringify({ markdown }) });
    const result = await handler(event);

    expect(result).toHaveProperty('statusCode', 200);
    const body = parseBody(result as { body: string });
    expect(body.success).toBe(true);
    expect(body.summary).not.toBeNull();
    expect(body.summary.workoutName).toBe('Test Workout');
    expect(body.summary.defaultWeightUnit).toBe('lbs');
    expect(body.summary.tags).toContain('strength');
    expect(body.summary.exerciseCount).toBe(1);
    expect(body.summary.totalSetCount).toBe(2);
    expect(body.summary.exercises).toHaveLength(1);
    expect(body.summary.exercises[0].name).toBe('Bench Press');
    expect(body.summary.exercises[0].setCount).toBe(2);
    expect(body.errors).toEqual([]);
    expect(body.warnings).toEqual([]);
  });

  it('returns 200 with parse errors for bad input', async () => {
    const markdown = `Just some text without headers`;
    const event = makeEvent({ body: JSON.stringify({ markdown }) });
    const result = await handler(event);

    expect(result).toHaveProperty('statusCode', 200);
    const body = parseBody(result as { body: string });
    expect(body.success).toBe(false);
    expect(body.errors.length).toBeGreaterThan(0);
    expect(body.summary).toBeNull();
  });

  it('accepts raw text/markdown content type', async () => {
    const markdown = `# Workout
## Exercise
- 100 x 5`;
    const event = makeEvent({
      headers: { 'content-type': 'text/markdown' },
      body: markdown,
    });
    const result = await handler(event);

    expect(result).toHaveProperty('statusCode', 200);
    const body = parseBody(result as { body: string });
    expect(body.success).toBe(true);
    expect(body.summary.workoutName).toBe('Workout');
  });

  it('handles base64 encoded body', async () => {
    const markdown = `# Workout
## Exercise
- 100 x 5`;
    const event = makeEvent({
      body: Buffer.from(JSON.stringify({ markdown })).toString('base64'),
      isBase64Encoded: true,
    });
    const result = await handler(event);

    expect(result).toHaveProperty('statusCode', 200);
    const body = parseBody(result as { body: string });
    expect(body.success).toBe(true);
  });

  it('returns warnings in response', async () => {
    const markdown = `# Workout
## Jumping Jacks
- 150`;
    const event = makeEvent({ body: JSON.stringify({ markdown }) });
    const result = await handler(event);

    expect(result).toHaveProperty('statusCode', 200);
    const body = parseBody(result as { body: string });
    expect(body.success).toBe(true);
    expect(body.warnings.length).toBeGreaterThan(0);
  });

  it('includes group info in exercise summary', async () => {
    const markdown = `# Workout
## Superset: Arms
### Bicep Curls
- 20 x 10
### Tricep Extensions
- 20 x 10`;
    const event = makeEvent({ body: JSON.stringify({ markdown }) });
    const result = await handler(event);

    expect(result).toHaveProperty('statusCode', 200);
    const body = parseBody(result as { body: string });
    expect(body.success).toBe(true);
    expect(body.summary.exercises.length).toBe(3);
    // Parent superset
    expect(body.summary.exercises[0].groupType).toBe('superset');
    expect(body.summary.exercises[0].setCount).toBe(0);
  });

  it('returns 400 in ValidateResponse shape when markdown field is not a string', async () => {
    const event = makeEvent({ body: JSON.stringify({ markdown: 42 }) });
    const result = await handler(event);
    expect(result).toHaveProperty('statusCode', 400);
    const body = parseBody(result as { body: string });
    expect(body.success).toBe(false);
    expect(body.summary).toBeNull();
    expect(body.errors).toEqual(['markdown field must be a string']);
    expect(body.warnings).toEqual([]);
  });

  it('returns 413 with consistent response format for oversized input', async () => {
    // Create a string larger than 1MB
    const markdown = '# Workout\n## Exercise\n- 100 x 5\n' + 'x'.repeat(1_048_577);
    const event = makeEvent({ body: JSON.stringify({ markdown }) });
    const result = await handler(event);

    expect(result).toHaveProperty('statusCode', 413);
    const body = parseBody(result as { body: string });
    // Verify it uses the same ValidateResponse shape as normal responses
    expect(body).toHaveProperty('success', false);
    expect(body).toHaveProperty('summary', null);
    expect(body).toHaveProperty('errors');
    expect(body).toHaveProperty('warnings');
    expect(body.errors).toEqual(['Input exceeds maximum size of 1MB']);
    expect(body.warnings).toEqual([]);
    // Ensure old format fields are NOT present
    expect(body).not.toHaveProperty('valid');
  });

  it('returns 413 when exercise count exceeds limit', async () => {
    // Generate a workout with 501 exercises
    const lines = ['# Workout'];
    for (let i = 0; i < 501; i++) {
      lines.push(`## Exercise ${i}`);
      lines.push('- 100 x 5');
    }
    const markdown = lines.join('\n');
    const event = makeEvent({ body: JSON.stringify({ markdown }) });
    const result = await handler(event);

    expect(result).toHaveProperty('statusCode', 413);
    const body = parseBody(result as { body: string });
    expect(body.success).toBe(false);
    expect(body.summary).toBeNull();
    expect(body.errors[0]).toMatch(/exceeds maximum of 500 exercises/);
    expect(body.warnings).toEqual([]);
  });
});

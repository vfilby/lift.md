import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach, vi, type MockInstance } from 'vitest';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PutCommand } from '@aws-sdk/lib-dynamodb';

// ─────────────────────────────────────────────────────────────────────────
// AI plan editing — POST /v1/ai/plan/edit.
//
// Contract: spec/services/ai-plan-editing.md → Cloud API / Quota / Server
// implementation / Testing → Validator. The model is always the
// FakeBedrockPlanEditor (scripted responses, recorded calls); nothing here
// talks to Bedrock. The HTTP-level cases need DDB Local (`make dev-up`) and
// self-skip otherwise, exactly like the other route suites.
// ─────────────────────────────────────────────────────────────────────────

const here = dirname(fileURLToPath(import.meta.url));
const TEST_SECRET = 'test-secret-do-not-use-in-prod-1234567890abcdef';

const live = process.env.DDB_ENDPOINT ? describe : describe.skip;

const VALID_PLAN = `# Push Day
@tags: strength, upper
@units: lbs

## Bench Press
- 135 x 5
- 185 x 5
- 225 x 5
`;

const EDITED_PLAN = `# Push Day
@tags: strength, upper
@units: lbs

## Dumbbell Bench Press
- 50 x 8
- 65 x 8
- 75 x 8
`;

const INVALID_PLAN = `Just prose with no workout header at all.`;

// ── Prompt drift ──

describe('AI plan-edit system prompt', () => {
  it('validator copy is byte-identical to spec/data/ (drift test)', () => {
    const validatorCopy = readFileSync(
      join(here, '..', 'src', 'data', 'ai-plan-edit-system-prompt.md'),
      'utf-8',
    );
    const canonical = readFileSync(
      join(here, '..', '..', 'spec', 'data', 'ai-plan-edit-system-prompt.md'),
      'utf-8',
    );
    expect(validatorCopy).toBe(canonical);
    expect(validatorCopy.length).toBeGreaterThan(1000);
  });

  it('bedrock.ts loads the same prompt file', async () => {
    const { planEditSystemPrompt, systemPromptPath } = await import(
      '../src/infra/bedrock.js'
    );
    expect(systemPromptPath()).toMatch(/src[\\/]data[\\/]ai-plan-edit-system-prompt\.md$/);
    expect(planEditSystemPrompt()).toBe(
      readFileSync(join(here, '..', 'src', 'data', 'ai-plan-edit-system-prompt.md'), 'utf-8'),
    );
  });
});

// ── Pure helpers (no DDB) ──

describe('ai route helpers', () => {
  it('buildPlanEditUserMessage lays blocks out in spec order and omits empties', async () => {
    const { buildPlanEditUserMessage } = await import('../src/routes/ai.js');
    const full = buildPlanEditUserMessage({
      plan_markdown: VALID_PLAN,
      instruction: 'swap bench for dumbbell press',
      history: [
        { role: 'user', content: 'make it shorter' },
        { role: 'assistant', content: 'Dropped a set.' },
      ],
      context: {
        units: 'lbs',
        equipment: ['barbell', 'dumbbells', 'cable'],
        recent_sessions: '2026-10-10 Push Day: Bench 185x5x3',
      },
    });
    expect(full).toBe(
      [
        '# USER CONTEXT',
        'Units: lbs',
        'Equipment: barbell, dumbbells, cable',
        'Recent sessions:',
        '2026-10-10 Push Day: Bench 185x5x3',
        '',
        '# CURRENT PLAN',
        VALID_PLAN,
        '',
        '# CONVERSATION',
        'user: make it shorter',
        'assistant: Dropped a set.',
        '',
        '# INSTRUCTION',
        'swap bench for dumbbell press',
      ].join('\n'),
    );

    const minimal = buildPlanEditUserMessage({
      plan_markdown: VALID_PLAN,
      instruction: 'add a warm-up set',
      history: [],
      context: {},
    });
    expect(minimal).toBe(
      `# CURRENT PLAN\n${VALID_PLAN}\n\n# INSTRUCTION\nadd a warm-up set`,
    );
    expect(minimal).not.toContain('# USER CONTEXT');
    expect(minimal).not.toContain('# CONVERSATION');
  });

  it('stripOuterFence removes exactly one outer code fence', async () => {
    const { stripOuterFence } = await import('../src/routes/ai.js');
    expect(stripOuterFence('```markdown\n# A\n## B\n- x 5\n```')).toBe('# A\n## B\n- x 5');
    expect(stripOuterFence('```\n# A\n```\n')).toBe('# A');
    expect(stripOuterFence('# A\n## B\n- x 5\n')).toBe('# A\n## B\n- x 5\n');
    // Inner fences survive.
    expect(stripOuterFence('```\n# A\n```\ninner\n```\n```')).toBe('# A\n```\ninner\n```');
  });

  it('validatePlanEditBody enforces 400 vs 413 with the exact limits', async () => {
    const {
      validatePlanEditBody,
      MAX_PLAN_BYTES,
      MAX_INSTRUCTION_BYTES,
      MAX_HISTORY_TURNS,
      MAX_HISTORY_BYTES,
      MAX_EQUIPMENT_ITEMS,
      MAX_EQUIPMENT_ITEM_BYTES,
      MAX_RECENT_SESSIONS_BYTES,
    } = await import('../src/routes/ai.js');
    expect(MAX_PLAN_BYTES).toBe(32_768);
    expect(MAX_INSTRUCTION_BYTES).toBe(2_048);
    expect(MAX_HISTORY_TURNS).toBe(6);
    expect(MAX_HISTORY_BYTES).toBe(8_192);
    expect(MAX_EQUIPMENT_ITEMS).toBe(50);
    expect(MAX_EQUIPMENT_ITEM_BYTES).toBe(64);
    expect(MAX_RECENT_SESSIONS_BYTES).toBe(8_192);

    const ok = validatePlanEditBody({ plan_markdown: VALID_PLAN, instruction: 'x' });
    expect(ok.ok).toBe(true);

    const bad = (body: unknown) => {
      const v = validatePlanEditBody(body);
      if (v.ok) throw new Error('expected rejection');
      return v;
    };
    expect(bad(null).status).toBe(400);
    expect(bad({ instruction: 'x' }).status).toBe(400);
    expect(bad({ plan_markdown: '  ', instruction: 'x' }).status).toBe(400);
    expect(bad({ plan_markdown: VALID_PLAN }).status).toBe(400);
    expect(bad({ plan_markdown: VALID_PLAN, instruction: 'x', history: 'nope' }).status).toBe(400);
    expect(
      bad({ plan_markdown: VALID_PLAN, instruction: 'x', history: [{ role: 'system', content: 'x' }] })
        .status,
    ).toBe(400);
    expect(
      bad({ plan_markdown: VALID_PLAN, instruction: 'x', context: { units: 'stone' } }).status,
    ).toBe(400);
    expect(
      bad({ plan_markdown: VALID_PLAN, instruction: 'x', context: { equipment: 'barbell' } }).status,
    ).toBe(400);

    const over = (n: number) => 'a'.repeat(n + 1);
    expect(bad({ plan_markdown: over(MAX_PLAN_BYTES), instruction: 'x' })).toMatchObject({
      status: 413,
      error: `plan_markdown exceeds maximum size of ${MAX_PLAN_BYTES} bytes`,
    });
    expect(bad({ plan_markdown: VALID_PLAN, instruction: over(MAX_INSTRUCTION_BYTES) })).toMatchObject(
      { status: 413, error: `instruction exceeds maximum size of ${MAX_INSTRUCTION_BYTES} bytes` },
    );
    expect(
      bad({
        plan_markdown: VALID_PLAN,
        instruction: 'x',
        history: Array.from({ length: MAX_HISTORY_TURNS + 1 }, () => ({ role: 'user', content: 'hi' })),
      }),
    ).toMatchObject({ status: 413, error: `history exceeds maximum of ${MAX_HISTORY_TURNS} turns` });
    expect(
      bad({
        plan_markdown: VALID_PLAN,
        instruction: 'x',
        history: [{ role: 'user', content: over(MAX_HISTORY_BYTES) }],
      }),
    ).toMatchObject({ status: 413 });
    expect(
      bad({
        plan_markdown: VALID_PLAN,
        instruction: 'x',
        context: { equipment: Array.from({ length: MAX_EQUIPMENT_ITEMS + 1 }, () => 'barbell') },
      }),
    ).toMatchObject({ status: 413 });
    expect(
      bad({
        plan_markdown: VALID_PLAN,
        instruction: 'x',
        context: { equipment: [over(MAX_EQUIPMENT_ITEM_BYTES)] },
      }),
    ).toMatchObject({ status: 413 });
    expect(
      bad({
        plan_markdown: VALID_PLAN,
        instruction: 'x',
        context: { recent_sessions: over(MAX_RECENT_SESSIONS_BYTES) },
      }),
    ).toMatchObject({ status: 413 });
  });

  it('quota helpers: UTC day, reset at next midnight, ttl = day + 7d, ceiling = ceil(1.1 × limit)', async () => {
    const { utcDay, nextUtcMidnight, ttlForDay } = await import('../src/repositories/ai_usage.js');
    const { ceilingFor, quotaFor, dailyLimitFromEnv } = await import('../src/routes/ai.js');
    const now = new Date('2026-10-16T23:59:30Z');
    expect(utcDay(now)).toBe('2026-10-16');
    expect(nextUtcMidnight(now).toISOString()).toBe('2026-10-17T00:00:00.000Z');
    expect(ttlForDay('2026-10-16')).toBe(Date.UTC(2026, 9, 23) / 1000);
    expect(ceilingFor(20)).toBe(22);
    expect(ceilingFor(2)).toBe(3);
    expect(quotaFor(20, 21, now)).toEqual({
      limit: 20,
      remaining: -1,
      reset_at: '2026-10-17T00:00:00Z',
      in_grace: true,
    });
    expect(quotaFor(20, 1, now).in_grace).toBe(false);

    const saved = process.env.AI_DAILY_LIMIT;
    try {
      delete process.env.AI_DAILY_LIMIT;
      expect(dailyLimitFromEnv()).toBe(20);
      process.env.AI_DAILY_LIMIT = '5';
      expect(dailyLimitFromEnv()).toBe(5);
      process.env.AI_DAILY_LIMIT = 'garbage';
      expect(dailyLimitFromEnv()).toBe(20);
    } finally {
      if (saved === undefined) delete process.env.AI_DAILY_LIMIT;
      else process.env.AI_DAILY_LIMIT = saved;
    }
  });

  it('RealBedrockPlanEditor.buildInput: system prompt + cachePoint, forced submit_plan_edit tool, inference config', async () => {
    const { RealBedrockPlanEditor, planEditSystemPrompt, DEFAULT_AI_MODEL_ID } = await import(
      '../src/infra/bedrock.js'
    );
    const saved = {
      model: process.env.AI_MODEL_ID,
      max: process.env.AI_MAX_OUTPUT_TOKENS,
    };
    try {
      delete process.env.AI_MODEL_ID;
      delete process.env.AI_MAX_OUTPUT_TOKENS;
      const editor = new RealBedrockPlanEditor();
      expect(editor.modelId).toBe(DEFAULT_AI_MODEL_ID);
      expect(DEFAULT_AI_MODEL_ID).toBe('us.amazon.nova-2-lite-v1:0');
      const input = editor.buildInput([{ role: 'user', content: [{ text: 'hi' }] }]);
      expect(input.modelId).toBe('us.amazon.nova-2-lite-v1:0');
      expect(input.system).toEqual([
        { text: planEditSystemPrompt() },
        { cachePoint: { type: 'default' } },
      ]);
      expect(input.toolConfig?.toolChoice).toEqual({ tool: { name: 'submit_plan_edit' } });
      expect(input.toolConfig?.tools).toHaveLength(1);
      const spec = input.toolConfig?.tools?.[0].toolSpec;
      expect(spec?.name).toBe('submit_plan_edit');
      expect(spec?.inputSchema?.json).toMatchObject({
        type: 'object',
        required: ['plan_markdown', 'summary'],
      });
      expect(input.inferenceConfig).toEqual({ maxTokens: 4000, temperature: 0.2 });

      process.env.AI_MODEL_ID = 'amazon.nova-lite-v1:0';
      process.env.AI_MAX_OUTPUT_TOKENS = '1500';
      const custom = new RealBedrockPlanEditor();
      expect(custom.modelId).toBe('amazon.nova-lite-v1:0');
      expect(custom.buildInput([]).inferenceConfig?.maxTokens).toBe(1500);
    } finally {
      if (saved.model === undefined) delete process.env.AI_MODEL_ID;
      else process.env.AI_MODEL_ID = saved.model;
      if (saved.max === undefined) delete process.env.AI_MAX_OUTPUT_TOKENS;
      else process.env.AI_MAX_OUTPUT_TOKENS = saved.max;
    }
  });

  it('extractPlanEditToolInput rejects responses without a usable tool call', async () => {
    const { extractPlanEditToolInput, BedrockModelError } = await import('../src/infra/bedrock.js');
    expect(() => extractPlanEditToolInput(undefined)).toThrow(BedrockModelError);
    expect(() => extractPlanEditToolInput([{ text: 'Sure! Here is the plan…' }])).toThrow(
      /no submit_plan_edit/,
    );
    expect(() =>
      extractPlanEditToolInput([
        { toolUse: { toolUseId: 't1', name: 'other_tool', input: {} } },
      ]),
    ).toThrow(/unexpected tool/);
    expect(() =>
      extractPlanEditToolInput([
        { toolUse: { toolUseId: 't1', name: 'submit_plan_edit', input: { plan_markdown: 1 } } },
      ]),
    ).toThrow(/missing plan_markdown or summary/);
    expect(
      extractPlanEditToolInput([
        { text: 'thinking…' },
        {
          toolUse: {
            toolUseId: 't9',
            name: 'submit_plan_edit',
            input: { plan_markdown: '# A', summary: 'did it', extra: true },
          },
        },
      ]),
    ).toEqual({ toolUseId: 't9', input: { plan_markdown: '# A', summary: 'did it' } });
  });

  it('RealBedrockPlanEditor maps SDK failures to BedrockModelError kinds', async () => {
    const { RealBedrockPlanEditor, BedrockModelError } = await import('../src/infra/bedrock.js');
    const named = (name: string) => {
      const e = new Error(name);
      e.name = name;
      return e;
    };
    const stub = (err: unknown) =>
      new RealBedrockPlanEditor({
        modelId: 'stub',
        client: { send: async () => { throw err; } } as never,
      });
    const kind = async (err: unknown) => {
      try {
        await stub(err).converse([]);
      } catch (e) {
        return e instanceof BedrockModelError ? e.kind : 'not-a-model-error';
      }
      return 'no-throw';
    };
    expect(await kind(named('ThrottlingException'))).toBe('throttled');
    expect(await kind(named('ServiceUnavailableException'))).toBe('throttled');
    expect(await kind(named('ModelNotReadyException'))).toBe('throttled');
    expect(await kind(named('ModelTimeoutException'))).toBe('timeout');
    expect(await kind(named('AbortError'))).toBe('timeout');
    expect(await kind(named('ValidationException'))).toBe('model');

    // A pre-aborted caller signal wins regardless of the error name.
    const controller = new AbortController();
    controller.abort();
    try {
      await stub(named('ValidationException')).converse([], { signal: controller.signal });
      throw new Error('expected throw');
    } catch (e) {
      expect(e).toBeInstanceOf(BedrockModelError);
      expect((e as InstanceType<typeof BedrockModelError>).kind).toBe('timeout');
    }

    // A successful response is unwrapped.
    const okEditor = new RealBedrockPlanEditor({
      modelId: 'stub',
      client: {
        send: async () => ({
          output: {
            message: {
              role: 'assistant',
              content: [
                { toolUse: { toolUseId: 'tu', name: 'submit_plan_edit', input: { plan_markdown: '# A', summary: 's' } } },
              ],
            },
          },
          usage: { inputTokens: 12, outputTokens: 3, totalTokens: 15 },
          stopReason: 'tool_use',
        }),
      } as never,
    });
    expect(await okEditor.converse([])).toEqual({
      input: { plan_markdown: '# A', summary: 's' },
      toolUseId: 'tu',
      usage: { input_tokens: 12, output_tokens: 3 },
      stopReason: 'tool_use',
    });
  });

  it('handler-ai exports a Lambda handler for the ai app', async () => {
    const { handler } = await import('../src/handler-ai.js');
    expect(typeof handler).toBe('function');
  });
});

// ── HTTP contract (DDB Local + fake Bedrock) ──

live('POST /v1/ai/plan/edit', () => {
  let originalSecret: string | undefined;
  let originalLimit: string | undefined;
  let app: typeof import('../src/app.js').app;
  let aiApp: typeof import('../src/ai-app.js').aiApp;
  let createUser: typeof import('../src/repositories/users.js').createUser;
  let updateUserTier: typeof import('../src/repositories/users.js').updateUserTier;
  let createToken: typeof import('../src/repositories/pat_tokens.js').createToken;
  let signJwt: typeof import('../src/infra/jwt.js').signJwt;
  let getAIUsage: typeof import('../src/repositories/ai_usage.js').getAIUsage;
  let utcDay: typeof import('../src/repositories/ai_usage.js').utcDay;
  let bedrock: typeof import('../src/infra/bedrock.js');
  let ddb: typeof import('../src/infra/ddb.js').ddb;
  let tableName: typeof import('../src/infra/ddb.js').tableName;

  type Scripted = import('../src/infra/bedrock.js').FakeScriptedResponse;
  type ScriptedOk = Extract<Scripted, { kind: 'ok' }>;
  const ok = (plan = EDITED_PLAN, summary = 'Swapped bench for dumbbell bench.'): ScriptedOk => ({
    kind: 'ok',
    plan_markdown: plan,
    summary,
  });

  let fake: InstanceType<typeof bedrock.FakeBedrockPlanEditor>;
  let logSpy: MockInstance<typeof console.log>;

  beforeAll(async () => {
    originalSecret = process.env.JWT_SECRET;
    originalLimit = process.env.AI_DAILY_LIMIT;
    process.env.JWT_SECRET = TEST_SECRET;
    delete process.env.AI_DAILY_LIMIT; // default 20 → ceiling 22
    ({ app } = await import('../src/app.js'));
    ({ aiApp } = await import('../src/ai-app.js'));
    ({ createUser, updateUserTier } = await import('../src/repositories/users.js'));
    ({ createToken } = await import('../src/repositories/pat_tokens.js'));
    ({ signJwt } = await import('../src/infra/jwt.js'));
    ({ getAIUsage, utcDay } = await import('../src/repositories/ai_usage.js'));
    ({ ddb, tableName } = await import('../src/infra/ddb.js'));
    bedrock = await import('../src/infra/bedrock.js');
  });

  afterAll(() => {
    bedrock._setPlanEditorForTests(undefined);
    if (originalSecret === undefined) delete process.env.JWT_SECRET;
    else process.env.JWT_SECRET = originalSecret;
    if (originalLimit === undefined) delete process.env.AI_DAILY_LIMIT;
    else process.env.AI_DAILY_LIMIT = originalLimit;
  });

  beforeEach(() => {
    fake = new bedrock.FakeBedrockPlanEditor([]);
    bedrock._setPlanEditorForTests(fake);
    logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
  });

  afterEach(() => {
    logSpy.mockRestore();
  });

  function auditEntries(): Record<string, unknown>[] {
    return logSpy.mock.calls
      .map((call) => {
        try {
          return JSON.parse(String(call[0])) as Record<string, unknown>;
        } catch {
          return null;
        }
      })
      .filter((e): e is Record<string, unknown> => e !== null && e.event === 'ai_plan_edit');
  }

  function uniqueEmail(label: string): string {
    return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}@example.com`;
  }

  async function seedUser(label: string, tier: 'pro' | 'trial' | 'free' = 'pro') {
    const user = await createUser({ display_name: 'AI Tester', primary_email: uniqueEmail(label) });
    if (tier !== 'trial') await updateUserTier(user.user_id, tier);
    const session_jwt = signJwt(
      { sub: user.user_id, identity_id: `test-identity-${user.user_id}`, type: 'access', authn_age: 'fresh' },
      '1h',
    );
    return { user_id: user.user_id, session_jwt };
  }

  async function seedPat(user_id: string, scopes: string[]) {
    const { plaintext } = await createToken({ user_id, name: 'ai-test', scopes, mode: 'test' });
    return plaintext;
  }

  async function edit(
    bearer: string | undefined,
    body: unknown = { plan_markdown: VALID_PLAN, instruction: 'swap bench for dumbbell press' },
    target: { request: typeof app.request } = app,
  ): Promise<Response> {
    const headers: Record<string, string> = { 'content-type': 'application/json' };
    if (bearer) headers.authorization = `Bearer ${bearer}`;
    return await target.request('/v1/ai/plan/edit', {
      method: 'POST',
      headers,
      body: typeof body === 'string' ? body : JSON.stringify(body),
    });
  }

  // ── Auth / tier / scope ──

  it('401 without auth', async () => {
    const res = await edit(undefined);
    expect(res.status).toBe(401);
    expect(fake.calls).toHaveLength(0);
  });

  it('402 for a free-tier session JWT with the /v1/tokens body shape', async () => {
    const { session_jwt } = await seedUser('free', 'free');
    fake.enqueue(ok());
    const res = await edit(session_jwt);
    expect(res.status).toBe(402);
    expect(await res.json()).toEqual({
      error: 'Subscription required',
      upgrade_url: 'https://getlift.md/account',
    });
    expect(fake.calls).toHaveLength(0);
  });

  it('402 for a free-tier PAT (even with ai:edit)', async () => {
    const { user_id } = await seedUser('free-pat', 'free');
    const pat = await seedPat(user_id, ['ai:edit']);
    const res = await edit(pat);
    expect(res.status).toBe(402);
    expect(((await res.json()) as { error: string }).error).toBe('Subscription required');
  });

  it('403 for a PAT without ai:edit; 200 with it', async () => {
    const { user_id } = await seedUser('scope');
    const noScope = await seedPat(user_id, ['workouts:read', 'workouts:write']);
    const res = await edit(noScope);
    expect(res.status).toBe(403);
    expect(((await res.json()) as { error: string }).error).toBe('Missing required scope: ai:edit');
    expect(fake.calls).toHaveLength(0);

    const withScope = await seedPat(user_id, ['ai:edit']);
    fake.enqueue(ok());
    const res2 = await edit(withScope);
    expect(res2.status).toBe(200);
  });

  it('trial users are gated like pro (same limit, not 402)', async () => {
    const { session_jwt } = await seedUser('trial', 'trial');
    fake.enqueue(ok());
    const res = await edit(session_jwt);
    expect(res.status).toBe(200);
    expect(((await res.json()) as { quota: { limit: number } }).quota.limit).toBe(20);
  });

  // ── Body validation ──

  it('400 on bad JSON / missing fields, 413 on size limits; no quota consumed', async () => {
    const { user_id, session_jwt } = await seedUser('validation');
    const r400 = await edit(session_jwt, '{not json');
    expect(r400.status).toBe(400);
    expect(await r400.json()).toEqual({ error: 'Invalid JSON body' });

    const r400b = await edit(session_jwt, { instruction: 'x' });
    expect(r400b.status).toBe(400);
    expect(((await r400b.json()) as { error: string }).error).toMatch(/plan_markdown/);

    const r413 = await edit(session_jwt, { plan_markdown: 'a'.repeat(32_769), instruction: 'x' });
    expect(r413.status).toBe(413);
    expect(await r413.json()).toEqual({ error: 'plan_markdown exceeds maximum size of 32768 bytes' });

    const r413b = await edit(session_jwt, {
      plan_markdown: VALID_PLAN,
      instruction: 'x',
      history: Array.from({ length: 7 }, () => ({ role: 'user', content: 'hi' })),
    });
    expect(r413b.status).toBe(413);

    expect(fake.calls).toHaveLength(0);
    expect(await getAIUsage(user_id, utcDay())).toBeNull();
  });

  // ── Happy path ──

  it('200: validated markdown, summary, warnings, quota, model, usage; audit has counts only', async () => {
    const { user_id, session_jwt } = await seedUser('happy');
    fake.enqueue({ ...ok(), usage: { input_tokens: 7412, output_tokens: 1388 } });

    const res = await edit(session_jwt, {
      plan_markdown: VALID_PLAN,
      instruction: 'swap bench for dumbbell press',
      history: [{ role: 'user', content: 'earlier' }, { role: 'assistant', content: 'ok' }],
      context: { units: 'lbs', equipment: ['barbell', 'dumbbells'] },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body).toEqual({
      plan_markdown: EDITED_PLAN,
      summary: 'Swapped bench for dumbbell bench.',
      warnings: [],
      attempts: 1,
      quota: {
        limit: 20,
        remaining: 19,
        reset_at: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T00:00:00Z$/),
        in_grace: false,
      },
      model: 'fake.plan-editor-v0',
      usage: { input_tokens: 7412, output_tokens: 1388 },
    });
    // reset_at is the next UTC midnight.
    const resetAt = new Date((body.quota as { reset_at: string }).reset_at);
    expect(resetAt.getTime()).toBeGreaterThan(Date.now());
    expect(resetAt.getTime() - Date.now()).toBeLessThanOrEqual(24 * 60 * 60 * 1000);

    // Exactly one model call with the spec'd user-message layout.
    expect(fake.calls).toHaveLength(1);
    const [first] = fake.calls[0].messages;
    expect(first.role).toBe('user');
    const text = first.content?.[0].text ?? '';
    expect(text).toContain('# USER CONTEXT\nUnits: lbs\nEquipment: barbell, dumbbells');
    expect(text).toContain(`# CURRENT PLAN\n${VALID_PLAN}`);
    expect(text).toContain('# CONVERSATION\nuser: earlier\nassistant: ok');
    expect(text).toMatch(/# INSTRUCTION\nswap bench for dumbbell press$/);

    // Quota row incremented.
    const usage = await getAIUsage(user_id, utcDay());
    expect(usage?.count).toBe(1);
    expect(usage?.ttl).toBeGreaterThan(Date.now() / 1000 + 6 * 24 * 3600);

    // Audit: counts, never content.
    const entries = auditEntries();
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      event: 'ai_plan_edit',
      user_id,
      model: 'fake.plan-editor-v0',
      input_tokens: 7412,
      output_tokens: 1388,
      attempts: 1,
      status: 200,
    });
    const serialized = JSON.stringify(entries[0]);
    expect(serialized).not.toContain('Bench Press');
    expect(serialized).not.toContain('dumbbell');
    // No log line anywhere carries the plan or the instruction.
    for (const call of logSpy.mock.calls) {
      const line = String(call[0]);
      expect(line).not.toContain('## Bench Press');
      expect(line).not.toContain('swap bench for dumbbell press');
    }
  });

  it('strips one outer code fence from plan_markdown before parsing', async () => {
    const { session_jwt } = await seedUser('fence');
    fake.enqueue(ok('```markdown\n' + EDITED_PLAN + '```'));
    const res = await edit(session_jwt);
    expect(res.status).toBe(200);
    expect(((await res.json()) as { plan_markdown: string }).plan_markdown).toBe(EDITED_PLAN.trimEnd());
  });

  it('parser warnings are returned, not treated as failures', async () => {
    const { session_jwt } = await seedUser('warnings');
    fake.enqueue(ok(`# Legs\n@units: lbs\n\n## Leg Press\n- 200 x 150\n`));
    const res = await edit(session_jwt);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { warnings: string[]; attempts: number };
    expect(body.attempts).toBe(1);
    expect(body.warnings.length).toBeGreaterThan(0);
    expect(fake.calls).toHaveLength(1);
  });

  // ── Repair turn ──

  it('repair turn: first output invalid, second valid → 200 with attempts: 2', async () => {
    const { user_id, session_jwt } = await seedUser('repair');
    fake.enqueue(
      { ...ok(INVALID_PLAN, 'first try'), usage: { input_tokens: 100, output_tokens: 10 } },
      { ...ok(EDITED_PLAN, 'fixed'), usage: { input_tokens: 200, output_tokens: 20 } },
    );
    const res = await edit(session_jwt);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Record<string, unknown>;
    expect(body.attempts).toBe(2);
    expect(body.summary).toBe('fixed');
    expect(body.usage).toEqual({ input_tokens: 300, output_tokens: 30 });

    // Second call carries: original user msg → assistant toolUse → user toolResult(errors).
    expect(fake.calls).toHaveLength(2);
    const repair = fake.calls[1].messages;
    expect(repair).toHaveLength(3);
    expect(repair[0].role).toBe('user');
    expect(repair[1].role).toBe('assistant');
    expect(repair[1].content?.[0].toolUse).toMatchObject({
      toolUseId: 'fake-tooluse-1',
      name: 'submit_plan_edit',
      input: { plan_markdown: INVALID_PLAN, summary: 'first try' },
    });
    expect(repair[2].role).toBe('user');
    const toolResult = repair[2].content?.[0].toolResult;
    expect(toolResult?.toolUseId).toBe('fake-tooluse-1');
    expect(toolResult?.status).toBe('error');
    const resultText = toolResult?.content?.[0].text ?? '';
    expect(resultText).toMatch(/did not parse/);
    expect(resultText).toMatch(/header/i); // the parser's NO_WORKOUT_HEADER message
    expect(resultText).toMatch(/COMPLETE corrected document/);

    // Quota consumed once (success), audit says attempts 2.
    expect((await getAIUsage(user_id, utcDay()))?.count).toBe(1);
    expect(auditEntries()[0]).toMatchObject({ attempts: 2, status: 200, input_tokens: 300 });
  });

  it('both outputs invalid → 422 with parse_errors and the quota released', async () => {
    const { user_id, session_jwt } = await seedUser('unparseable');
    fake.enqueue(ok(INVALID_PLAN), ok(INVALID_PLAN));
    const res = await edit(session_jwt);
    expect(res.status).toBe(422);
    const body = (await res.json()) as { error: string; attempts: number; parse_errors: string[] };
    expect(body.error).toBe('Model output did not parse');
    expect(body.attempts).toBe(2);
    expect(body.parse_errors.length).toBeGreaterThan(0);
    expect(fake.calls).toHaveLength(2);
    expect((await getAIUsage(user_id, utcDay()))?.count).toBe(0);
    expect(auditEntries()[0]).toMatchObject({ attempts: 2, status: 422 });

    // The released slot is reusable.
    fake.enqueue(ok());
    const again = await edit(session_jwt);
    expect(again.status).toBe(200);
    expect(((await again.json()) as { quota: { remaining: number } }).quota.remaining).toBe(19);
  });

  // ── Model errors ──

  it('Bedrock throttling → 502 with Retry-After, quota released', async () => {
    const { user_id, session_jwt } = await seedUser('throttled');
    fake.enqueue({ kind: 'error', error: 'throttled', message: 'ThrottlingException' });
    const res = await edit(session_jwt);
    expect(res.status).toBe(502);
    expect(res.headers.get('retry-after')).toMatch(/^\d+$/);
    expect(await res.json()).toEqual({ error: 'Model temporarily unavailable' });
    expect((await getAIUsage(user_id, utcDay()))?.count).toBe(0);
    expect(auditEntries()[0]).toMatchObject({ status: 502, attempts: 1 });
  });

  it('malformed model response → 502, quota released', async () => {
    const { user_id, session_jwt } = await seedUser('malformed');
    fake.enqueue({ kind: 'error', error: 'malformed' });
    const res = await edit(session_jwt);
    expect(res.status).toBe(502);
    expect((await getAIUsage(user_id, utcDay()))?.count).toBe(0);
  });

  it('model call exceeding AI_MODEL_TIMEOUT_MS → 504, quota released', async () => {
    const saved = process.env.AI_MODEL_TIMEOUT_MS;
    process.env.AI_MODEL_TIMEOUT_MS = '50';
    try {
      const { user_id, session_jwt } = await seedUser('timeout');
      fake.enqueue({ kind: 'hang' });
      const res = await edit(session_jwt);
      expect(res.status).toBe(504);
      expect(await res.json()).toEqual({ error: 'Model call timed out' });
      expect(res.headers.get('retry-after')).toBeNull();
      expect((await getAIUsage(user_id, utcDay()))?.count).toBe(0);
      expect(auditEntries()[0]).toMatchObject({ status: 504 });
    } finally {
      if (saved === undefined) delete process.env.AI_MODEL_TIMEOUT_MS;
      else process.env.AI_MODEL_TIMEOUT_MS = saved;
    }
  });

  it('a timeout on the repair turn also releases and 504s', async () => {
    const saved = process.env.AI_MODEL_TIMEOUT_MS;
    process.env.AI_MODEL_TIMEOUT_MS = '50';
    try {
      const { user_id, session_jwt } = await seedUser('timeout-repair');
      fake.enqueue(ok(INVALID_PLAN), { kind: 'hang' });
      const res = await edit(session_jwt);
      expect(res.status).toBe(504);
      expect((await getAIUsage(user_id, utcDay()))?.count).toBe(0);
      expect(auditEntries()[0]).toMatchObject({ status: 504, attempts: 2 });
    } finally {
      if (saved === undefined) delete process.env.AI_MODEL_TIMEOUT_MS;
      else process.env.AI_MODEL_TIMEOUT_MS = saved;
    }
  });

  // ── Quota ──

  it('ceiling: requests 21 and 22 succeed in grace, the 23rd is 429 with Retry-After', async () => {
    const { user_id, session_jwt } = await seedUser('ceiling');
    for (let i = 0; i < 22; i++) fake.enqueue(ok());

    const quotas: { remaining: number; in_grace: boolean }[] = [];
    for (let i = 1; i <= 22; i++) {
      const res = await edit(session_jwt);
      expect(res.status, `request #${i}`).toBe(200);
      quotas.push(((await res.json()) as { quota: { remaining: number; in_grace: boolean } }).quota);
    }
    expect(quotas[19]).toMatchObject({ remaining: 0, in_grace: false });
    expect(quotas[20]).toMatchObject({ remaining: -1, in_grace: true });
    expect(quotas[21]).toMatchObject({ remaining: -2, in_grace: true });

    const res = await edit(session_jwt);
    expect(res.status).toBe(429);
    const retryAfter = Number(res.headers.get('retry-after'));
    expect(retryAfter).toBeGreaterThan(0);
    expect(retryAfter).toBeLessThanOrEqual(24 * 60 * 60);
    const body = (await res.json()) as { error: string; quota: Record<string, unknown> };
    expect(body.error).toBe('Daily AI limit reached');
    expect(body.quota).toEqual({
      limit: 20,
      remaining: 0,
      reset_at: expect.stringMatching(/T00:00:00Z$/),
      in_grace: true,
    });
    expect(fake.calls).toHaveLength(22); // no model call on 429
    expect((await getAIUsage(user_id, utcDay()))?.count).toBe(22);
  });

  it('per-user entitlements.ai_daily_limit overrides the env limit', async () => {
    const { user_id, session_jwt } = await seedUser('override');
    await ddb.send(
      new PutCommand({
        TableName: tableName('entitlements'),
        Item: { user_id, ai_daily_limit: 2 },
      }),
    );
    fake.enqueue(ok(), ok(), ok());
    const first = await edit(session_jwt);
    expect(first.status).toBe(200);
    expect(((await first.json()) as { quota: { limit: number; remaining: number } }).quota).toMatchObject({
      limit: 2,
      remaining: 1,
    });
    expect((await edit(session_jwt)).status).toBe(200);
    // ceil(2 × 1.1) = 3 → one grace request.
    const third = await edit(session_jwt);
    expect(third.status).toBe(200);
    expect(((await third.json()) as { quota: { in_grace: boolean } }).quota.in_grace).toBe(true);
    const fourth = await edit(session_jwt);
    expect(fourth.status).toBe(429);
    expect(((await fourth.json()) as { quota: { limit: number } }).quota.limit).toBe(2);
  });

  it('AI_DAILY_LIMIT env is honoured when no entitlement row exists', async () => {
    process.env.AI_DAILY_LIMIT = '1';
    try {
      const { session_jwt } = await seedUser('env-limit');
      fake.enqueue(ok(), ok());
      const first = await edit(session_jwt);
      expect(((await first.json()) as { quota: { limit: number; remaining: number } }).quota).toMatchObject({
        limit: 1,
        remaining: 0,
      });
      // ceil(1.1) = 2 → one grace request, then 429.
      expect((await edit(session_jwt)).status).toBe(200);
      expect((await edit(session_jwt)).status).toBe(429);
    } finally {
      delete process.env.AI_DAILY_LIMIT;
    }
  });

  // ── ai-fn app ──

  it('the ai-fn app (ai-app.ts) serves /v1/ai/plan/edit and /version, nothing else', async () => {
    const { session_jwt } = await seedUser('ai-app');
    fake.enqueue(ok());
    const res = await edit(session_jwt, undefined, aiApp);
    expect(res.status).toBe(200);

    const version = await aiApp.request('/version');
    expect(version.status).toBe(200);
    expect(version.headers.get('cache-control')).toBe('no-store');
    expect(Object.keys((await version.json()) as object).sort()).toEqual(['builtAt', 'commit', 'env']);

    expect((await aiApp.request('/validate', { method: 'POST', body: '{}' })).status).toBe(404);
    expect((await aiApp.request('/v1/me', { headers: { authorization: `Bearer ${session_jwt}` } })).status).toBe(404);
  });
});

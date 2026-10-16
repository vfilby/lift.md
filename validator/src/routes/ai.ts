/**
 * /v1/ai — LLM plan editing (session JWT or PAT with `ai:edit`).
 *
 *   - POST /v1/ai/plan/edit   revise an LMWF plan from a natural-language
 *                             instruction via Amazon Bedrock
 *
 * Contract: spec/services/ai-plan-editing.md → Cloud API / Quota / Server
 * implementation. Flow:
 *
 *   auth → tier check (402 for `free`) → body validation (400 / 413) →
 *   quota reserve (429) → build user message → model call → extract tool
 *   input → parseWorkout() → one repair turn on parse failure → 422 +
 *   release on second failure → 502 / 504 + release on model errors →
 *   audit `ai_plan_edit` (token counts, never content) → 200.
 *
 * In production only the dedicated `ai-fn` Lambda (src/ai-app.ts) serves
 * this router; the main validator app also mounts it so local dev
 * (`npm run dev`) and the Vitest suite exercise it through `app`.
 *
 * Stateless: nothing about the conversation is stored server-side, and the
 * logs carry byte/token counts only.
 */
import { Hono } from 'hono';
import type { Message } from '@aws-sdk/client-bedrock-runtime';
import { audit } from '../infra/audit.js';
import {
  BedrockModelError,
  PLAN_EDIT_TOOL_NAME,
  aiModelTimeoutMs,
  getPlanEditor,
  type PlanEditUsage,
} from '../infra/bedrock.js';
import { requireScope, type AuthVariables } from '../middleware/auth.js';
import { parseWorkout } from '../parser/index.js';
import {
  QuotaExceededError,
  nextUtcMidnight,
  releaseAIRequest,
  reserveAIRequest,
  utcDay,
} from '../repositories/ai_usage.js';
import { getEntitlement } from '../repositories/entitlements.js';
import { UPGRADE_URL } from './tokens.js';

// ── Limits (spec → Cloud API → Request) ──
export const MAX_PLAN_BYTES = 32_768;
export const MAX_INSTRUCTION_BYTES = 2_048;
export const MAX_HISTORY_TURNS = 6;
export const MAX_HISTORY_BYTES = 8_192;
export const MAX_EQUIPMENT_ITEMS = 50;
export const MAX_EQUIPMENT_ITEM_BYTES = 64;
export const MAX_RECENT_SESSIONS_BYTES = 8_192;

export const DEFAULT_AI_DAILY_LIMIT = 20;
/** Grace: the hard ceiling sits 10 % above the advertised limit. */
export const GRACE_MULTIPLIER = 1.1;
/** Retry-After on 502 (seconds) — Bedrock throttles clear quickly. */
const MODEL_ERROR_RETRY_AFTER_SECONDS = 30;

export const AI_EDIT_SCOPE = 'ai:edit';

export interface PlanEditTurn {
  role: 'user' | 'assistant';
  content: string;
}

export interface PlanEditContext {
  units?: 'lbs' | 'kg';
  equipment?: string[];
  recent_sessions?: string;
}

export interface PlanEditRequestBody {
  plan_markdown: string;
  instruction: string;
  history: PlanEditTurn[];
  context: PlanEditContext;
}

export interface PlanEditQuota {
  limit: number;
  remaining: number;
  reset_at: string;
  in_grace: boolean;
}

type Variables = AuthVariables & { requestId: string; startTime: number };

function log(entry: Record<string, unknown>): void {
  console.log(JSON.stringify(entry));
}

function bytes(s: string): number {
  return Buffer.byteLength(s, 'utf-8');
}

/** ISO-8601 without fractional seconds, e.g. 2026-10-17T00:00:00Z. */
function isoSeconds(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export function dailyLimitFromEnv(): number {
  const raw = process.env.AI_DAILY_LIMIT;
  if (raw === undefined || raw.trim() === '') return DEFAULT_AI_DAILY_LIMIT;
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 ? n : DEFAULT_AI_DAILY_LIMIT;
}

export function ceilingFor(limit: number): number {
  return Math.ceil(limit * GRACE_MULTIPLIER);
}

export function quotaFor(limit: number, count: number, now: Date): PlanEditQuota {
  return {
    limit,
    remaining: limit - count,
    reset_at: isoSeconds(nextUtcMidnight(now)),
    in_grace: count > limit,
  };
}

// ── Body validation ──

type Validation =
  | { ok: true; body: PlanEditRequestBody }
  | { ok: false; status: 400 | 413; error: string };

function invalid(error: string): Validation {
  return { ok: false, status: 400, error };
}

function tooLarge(error: string): Validation {
  return { ok: false, status: 413, error };
}

export function validatePlanEditBody(raw: unknown): Validation {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return invalid('Request body must be a JSON object');
  }
  const r = raw as Record<string, unknown>;

  if (typeof r.plan_markdown !== 'string' || r.plan_markdown.trim() === '') {
    return invalid('plan_markdown must be a non-empty string');
  }
  if (typeof r.instruction !== 'string' || r.instruction.trim() === '') {
    return invalid('instruction must be a non-empty string');
  }

  // History
  const history: PlanEditTurn[] = [];
  if (r.history !== undefined && r.history !== null) {
    if (!Array.isArray(r.history)) {
      return invalid('history must be an array of { role, content }');
    }
    for (const turn of r.history) {
      if (typeof turn !== 'object' || turn === null) {
        return invalid('history entries must be objects with role and content');
      }
      const t = turn as Record<string, unknown>;
      if (t.role !== 'user' && t.role !== 'assistant') {
        return invalid('history[].role must be "user" or "assistant"');
      }
      if (typeof t.content !== 'string') {
        return invalid('history[].content must be a string');
      }
      history.push({ role: t.role, content: t.content });
    }
  }

  // Context
  const context: PlanEditContext = {};
  if (r.context !== undefined && r.context !== null) {
    if (typeof r.context !== 'object' || Array.isArray(r.context)) {
      return invalid('context must be an object');
    }
    const c = r.context as Record<string, unknown>;
    if (c.units !== undefined && c.units !== null) {
      if (c.units !== 'lbs' && c.units !== 'kg') {
        return invalid('context.units must be "lbs" or "kg"');
      }
      context.units = c.units;
    }
    if (c.equipment !== undefined && c.equipment !== null) {
      if (
        !Array.isArray(c.equipment) ||
        !c.equipment.every((e) => typeof e === 'string')
      ) {
        return invalid('context.equipment must be an array of strings');
      }
      context.equipment = c.equipment as string[];
    }
    if (c.recent_sessions !== undefined && c.recent_sessions !== null) {
      if (typeof c.recent_sessions !== 'string') {
        return invalid('context.recent_sessions must be a string');
      }
      context.recent_sessions = c.recent_sessions;
    }
  }

  // Size limits — all 413, with the exact limit in the message.
  if (bytes(r.plan_markdown) > MAX_PLAN_BYTES) {
    return tooLarge(`plan_markdown exceeds maximum size of ${MAX_PLAN_BYTES} bytes`);
  }
  if (bytes(r.instruction) > MAX_INSTRUCTION_BYTES) {
    return tooLarge(`instruction exceeds maximum size of ${MAX_INSTRUCTION_BYTES} bytes`);
  }
  if (history.length > MAX_HISTORY_TURNS) {
    return tooLarge(`history exceeds maximum of ${MAX_HISTORY_TURNS} turns`);
  }
  const historyBytes = history.reduce((sum, t) => sum + bytes(t.content), 0);
  if (historyBytes > MAX_HISTORY_BYTES) {
    return tooLarge(`history exceeds maximum total size of ${MAX_HISTORY_BYTES} bytes`);
  }
  if (context.equipment) {
    if (context.equipment.length > MAX_EQUIPMENT_ITEMS) {
      return tooLarge(`context.equipment exceeds maximum of ${MAX_EQUIPMENT_ITEMS} entries`);
    }
    if (context.equipment.some((e) => bytes(e) > MAX_EQUIPMENT_ITEM_BYTES)) {
      return tooLarge(
        `context.equipment entries exceed maximum size of ${MAX_EQUIPMENT_ITEM_BYTES} bytes`,
      );
    }
  }
  if (
    context.recent_sessions !== undefined &&
    bytes(context.recent_sessions) > MAX_RECENT_SESSIONS_BYTES
  ) {
    return tooLarge(
      `context.recent_sessions exceeds maximum size of ${MAX_RECENT_SESSIONS_BYTES} bytes`,
    );
  }

  return {
    ok: true,
    body: {
      plan_markdown: r.plan_markdown,
      instruction: r.instruction,
      history,
      context,
    },
  };
}

// ── Prompt assembly (spec → Shared behaviour 2) ──

/**
 * The user message, block by block in the mandated order; every block (and
 * every line inside USER CONTEXT) is omitted when empty.
 */
export function buildPlanEditUserMessage(body: PlanEditRequestBody): string {
  const blocks: string[] = [];

  const ctx: string[] = [];
  if (body.context.units) ctx.push(`Units: ${body.context.units}`);
  const equipment = (body.context.equipment ?? [])
    .map((e) => e.trim())
    .filter((e) => e.length > 0);
  if (equipment.length > 0) ctx.push(`Equipment: ${equipment.join(', ')}`);
  const recent = body.context.recent_sessions?.trim();
  if (recent) ctx.push(`Recent sessions:\n${recent}`);
  if (ctx.length > 0) blocks.push(`# USER CONTEXT\n${ctx.join('\n')}`);

  blocks.push(`# CURRENT PLAN\n${body.plan_markdown}`);

  const turns = body.history.filter((t) => t.content.trim().length > 0);
  if (turns.length > 0) {
    blocks.push(
      `# CONVERSATION\n${turns.map((t) => `${t.role}: ${t.content}`).join('\n')}`,
    );
  }

  blocks.push(`# INSTRUCTION\n${body.instruction}`);

  return blocks.join('\n\n');
}

/**
 * Engines must not scrape fences, but if the model wrapped `plan_markdown`
 * in one anyway, strip exactly one outer fence before parsing.
 */
export function stripOuterFence(markdown: string): string {
  const trimmed = markdown.trim();
  const m = trimmed.match(/^```[^\n]*\n([\s\S]*?)\n?```$/);
  return m ? m[1] : markdown;
}

function repairToolResultText(errors: string[]): string {
  return [
    'The submitted plan_markdown did not parse as a valid lift.md document:',
    ...errors.map((e) => `- ${e}`),
    '',
    'Fix these errors and call submit_plan_edit again with the COMPLETE corrected document (every line, not only the changed part) and the same summary.',
  ].join('\n');
}

// ── Router ──

export const aiRouter = new Hono<{ Variables: Variables }>();

aiRouter.post('/plan/edit', requireScope(AI_EDIT_SCOPE), async (c) => {
  const requestId = c.var.requestId;
  const startTime = c.var.startTime;
  const user = c.var.user;

  // Tier gate. The PAT path already 402s free users inside the auth
  // middleware; this covers session JWTs with the same body as /v1/tokens.
  if (user.tier === 'free') {
    return c.json(
      { error: 'Subscription required', upgrade_url: UPGRADE_URL },
      402,
    );
  }

  // Body
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }
  const validated = validatePlanEditBody(raw);
  if (!validated.ok) {
    log({
      level: 'warn',
      requestId,
      event: 'ai_plan_edit_rejected',
      status: validated.status,
      error: validated.error,
      durationMs: Date.now() - startTime,
    });
    return c.json({ error: validated.error }, validated.status);
  }
  const body = validated.body;

  // Quota
  const now = new Date();
  const day = utcDay(now);
  const entitlement = await getEntitlement(user.user_id);
  const override = entitlement?.ai_daily_limit;
  const limit =
    typeof override === 'number' && Number.isInteger(override) && override > 0
      ? override
      : dailyLimitFromEnv();
  const ceiling = ceilingFor(limit);

  let count: number;
  try {
    count = await reserveAIRequest(user.user_id, day, ceiling);
  } catch (err) {
    if (err instanceof QuotaExceededError) {
      const resetAt = nextUtcMidnight(now);
      const retryAfter = Math.max(
        1,
        Math.ceil((resetAt.getTime() - now.getTime()) / 1000),
      );
      log({
        level: 'info',
        requestId,
        event: 'ai_plan_edit_quota_exceeded',
        status: 429,
        user_id: user.user_id,
        limit,
        ceiling,
        durationMs: Date.now() - startTime,
      });
      c.header('Retry-After', String(retryAfter));
      return c.json(
        {
          error: 'Daily AI limit reached',
          quota: { ...quotaFor(limit, ceiling, now), remaining: 0 },
        },
        429,
      );
    }
    throw err;
  }

  log({
    level: 'info',
    requestId,
    event: 'ai_plan_edit_request',
    user_id: user.user_id,
    auth: c.var.token ? 'pat' : 'session',
    planBytes: bytes(body.plan_markdown),
    instructionBytes: bytes(body.instruction),
    historyTurns: body.history.length,
    count,
    limit,
  });

  // Model
  const editor = getPlanEditor();
  const usage: PlanEditUsage = { input_tokens: 0, output_tokens: 0 };
  let attempts = 0;
  // One deadline for the whole request (both turns share it) so the route
  // always answers inside the Lambda's 29 s budget.
  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(), aiModelTimeoutMs());
  let reserved = true;
  const release = async () => {
    if (!reserved) return;
    reserved = false;
    await releaseAIRequest(user.user_id, day);
  };
  const auditResult = (status: number) =>
    audit({
      event: 'ai_plan_edit',
      user_id: user.user_id,
      model: editor.modelId,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      attempts,
      status,
    });

  try {
    const messages: Message[] = [
      { role: 'user', content: [{ text: buildPlanEditUserMessage(body) }] },
    ];

    let parseErrors: string[] = [];
    for (let attempt = 1; attempt <= 2; attempt++) {
      attempts = attempt;
      const response = await editor.converse(messages, {
        signal: controller.signal,
      });
      usage.input_tokens += response.usage.input_tokens;
      usage.output_tokens += response.usage.output_tokens;

      const planMarkdown = stripOuterFence(response.input.plan_markdown);
      const parsed = parseWorkout(planMarkdown);
      if (parsed.success) {
        auditResult(200);
        log({
          level: 'info',
          requestId,
          event: 'ai_plan_edit_complete',
          status: 200,
          attempts,
          input_tokens: usage.input_tokens,
          output_tokens: usage.output_tokens,
          warningCount: parsed.warnings.length,
          durationMs: Date.now() - startTime,
        });
        return c.json(
          {
            plan_markdown: planMarkdown,
            summary: response.input.summary,
            warnings: parsed.warnings,
            attempts,
            quota: quotaFor(limit, count, now),
            model: editor.modelId,
            usage,
          },
          200,
        );
      }

      parseErrors = parsed.errors;
      if (attempt === 1) {
        // Repair turn: echo the model's own tool call back, then the parser
        // errors as the tool result, asking for a corrected full document.
        messages.push(
          {
            role: 'assistant',
            content: [
              {
                toolUse: {
                  toolUseId: response.toolUseId,
                  name: PLAN_EDIT_TOOL_NAME,
                  input: { ...response.input },
                },
              },
            ],
          },
          {
            role: 'user',
            content: [
              {
                toolResult: {
                  toolUseId: response.toolUseId,
                  status: 'error',
                  content: [{ text: repairToolResultText(parseErrors) }],
                },
              },
            ],
          },
        );
      }
    }

    // Both attempts failed to parse.
    await release();
    auditResult(422);
    log({
      level: 'warn',
      requestId,
      event: 'ai_plan_edit_unparseable',
      status: 422,
      attempts,
      errorCount: parseErrors.length,
      durationMs: Date.now() - startTime,
    });
    return c.json(
      {
        error: 'Model output did not parse',
        attempts,
        parse_errors: parseErrors,
      },
      422,
    );
  } catch (err) {
    await release();
    if (err instanceof BedrockModelError) {
      const status = err.kind === 'timeout' ? 504 : 502;
      auditResult(status);
      log({
        level: 'warn',
        requestId,
        event: 'ai_plan_edit_model_error',
        status,
        kind: err.kind,
        error: err.message,
        attempts,
        durationMs: Date.now() - startTime,
      });
      if (status === 502) {
        c.header('Retry-After', String(MODEL_ERROR_RETRY_AFTER_SECONDS));
        return c.json(
          {
            error:
              err.kind === 'throttled'
                ? 'Model temporarily unavailable'
                : err.kind === 'malformed'
                  ? 'Model returned an unusable response'
                  : 'Model error',
          },
          502,
        );
      }
      return c.json({ error: 'Model call timed out' }, 504);
    }
    throw err;
  } finally {
    clearTimeout(deadline);
  }
});

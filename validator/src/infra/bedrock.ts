/**
 * Amazon Bedrock wrapper for the AI plan-edit route.
 *
 * Wraps `@aws-sdk/client-bedrock-runtime` `ConverseCommand` behind the
 * small `BedrockPlanEditor` interface so the route is model-agnostic and
 * tests inject `FakeBedrockPlanEditor`. Per spec/services/ai-plan-editing.md
 * → Server implementation:
 *
 *   - system = the canonical prompt file (src/data/ai-plan-edit-system-prompt.md,
 *     verbatim copy of spec/data/, drift-tested) followed by a `cachePoint`
 *     block so the ~5k-token prefix is cached across calls;
 *   - toolConfig with exactly one tool, `submit_plan_edit`
 *     `{ plan_markdown: string, summary: string }`, and a forced
 *     `toolChoice` so the model never answers in prose;
 *   - inferenceConfig.maxTokens from AI_MAX_OUTPUT_TOKENS (default 4000),
 *     temperature 0.2;
 *   - the model id from AI_MODEL_ID (default `us.amazon.nova-2-lite-v1:0`,
 *     the cross-region inference profile for Nova 2 Lite);
 *   - a per-call abort after AI_MODEL_TIMEOUT_MS (default 24000) unless the
 *     caller supplies its own deadline signal.
 *
 * Errors are normalised to `BedrockModelError` with a `kind` the route maps
 * to a status: `timeout` → 504, everything else → 502.
 */
import {
  BedrockRuntimeClient,
  ConverseCommand,
  type ContentBlock,
  type ConverseCommandInput,
  type Message,
  type SystemContentBlock,
  type ToolConfiguration,
} from '@aws-sdk/client-bedrock-runtime';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const DEFAULT_AI_MODEL_ID = 'us.amazon.nova-2-lite-v1:0';
export const DEFAULT_AI_MAX_OUTPUT_TOKENS = 4000;
export const DEFAULT_AI_MODEL_TIMEOUT_MS = 24_000;
export const PLAN_EDIT_TOOL_NAME = 'submit_plan_edit';

/** The structured output every engine requests (spec → Shared behaviour 3). */
export interface PlanEditToolInput {
  plan_markdown: string;
  summary: string;
}

export interface PlanEditUsage {
  input_tokens: number;
  output_tokens: number;
}

export interface PlanEditModelResponse {
  /** The `submit_plan_edit` tool input the model produced. */
  input: PlanEditToolInput;
  /** Tool-use id — echoed back in the repair turn's toolResult. */
  toolUseId: string;
  usage: PlanEditUsage;
  stopReason?: string;
}

export interface ConverseOptions {
  /** Caller-owned deadline; when absent a per-call timeout is applied. */
  signal?: AbortSignal;
}

export interface BedrockPlanEditor {
  readonly modelId: string;
  /**
   * One Converse round trip. `messages` is the full transcript so far
   * (user → assistant toolUse → user toolResult … ); the system prompt and
   * tool config are added by the implementation.
   */
  converse(
    messages: Message[],
    options?: ConverseOptions,
  ): Promise<PlanEditModelResponse>;
}

export type BedrockModelErrorKind =
  /** ThrottlingException / ServiceUnavailable / ModelNotReady — retryable. */
  | 'throttled'
  /** The call exceeded the Lambda budget (abort signal fired). */
  | 'timeout'
  /** The model answered without a usable `submit_plan_edit` tool call. */
  | 'malformed'
  /** Any other provider error. */
  | 'model';

export class BedrockModelError extends Error {
  constructor(
    public readonly kind: BedrockModelErrorKind,
    message: string,
    public readonly cause?: unknown,
  ) {
    super(message);
    this.name = 'BedrockModelError';
  }
}

// ── Env-driven configuration (read per call so tests can override) ──

export function aiModelId(): string {
  return process.env.AI_MODEL_ID?.trim() || DEFAULT_AI_MODEL_ID;
}

function positiveIntEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  const n = Number(raw);
  return Number.isInteger(n) && n > 0 ? n : fallback;
}

export function aiMaxOutputTokens(): number {
  return positiveIntEnv('AI_MAX_OUTPUT_TOKENS', DEFAULT_AI_MAX_OUTPUT_TOKENS);
}

export function aiModelTimeoutMs(): number {
  return positiveIntEnv('AI_MODEL_TIMEOUT_MS', DEFAULT_AI_MODEL_TIMEOUT_MS);
}

// ── Prompt ──

export const SYSTEM_PROMPT_FILENAME = 'ai-plan-edit-system-prompt.md';

/**
 * Directory of this module at runtime. Three runtimes load this file:
 *   - tsx / vitest (ESM, src/infra/)   → import.meta.url
 *   - the esbuild CJS Lambda bundle     → __dirname (dist/), import.meta is
 *     empty there (esbuild `empty-import-meta`, silenced in the Makefile)
 */
function moduleDir(): string {
  if (typeof __dirname === 'string') return __dirname;
  return dirname(fileURLToPath(import.meta.url));
}

/**
 * Locate the prompt file: `dist/data/` in the bundle (Makefile `bundle`
 * copies it there) or `src/data/` next to this module in dev/tests.
 */
export function systemPromptPath(): string {
  const dir = moduleDir();
  const candidates = [
    join(dir, 'data', SYSTEM_PROMPT_FILENAME),
    join(dir, '..', 'data', SYSTEM_PROMPT_FILENAME),
  ];
  const found = candidates.find((p) => existsSync(p));
  if (!found) {
    throw new Error(
      `AI system prompt not found; looked in ${candidates.join(', ')}`,
    );
  }
  return found;
}

/** The canonical system prompt, loaded once per process. */
let cachedSystemPrompt: string | undefined;
export function planEditSystemPrompt(): string {
  if (cachedSystemPrompt === undefined) {
    cachedSystemPrompt = readFileSync(systemPromptPath(), 'utf-8');
  }
  return cachedSystemPrompt;
}

export function planEditSystemBlocks(): SystemContentBlock[] {
  return [
    { text: planEditSystemPrompt() },
    // Cache checkpoint after the (identical for every call) system prefix.
    { cachePoint: { type: 'default' } },
  ];
}

export const planEditToolConfig: ToolConfiguration = {
  tools: [
    {
      toolSpec: {
        name: PLAN_EDIT_TOOL_NAME,
        description:
          'Submit the complete revised workout plan in lift.md format plus a one-paragraph summary of the change.',
        inputSchema: {
          json: {
            type: 'object',
            properties: {
              plan_markdown: {
                type: 'string',
                description:
                  'The full revised plan as lift.md markdown. No code fences.',
              },
              summary: {
                type: 'string',
                description: 'One short paragraph explaining what changed.',
              },
            },
            required: ['plan_markdown', 'summary'],
          },
        },
      },
    },
  ],
  toolChoice: { tool: { name: PLAN_EDIT_TOOL_NAME } },
};

// ── Real implementation ──

function errorName(err: unknown): string {
  return err instanceof Error ? err.name : '';
}

function classifyError(err: unknown): BedrockModelError {
  const name = errorName(err);
  const message = err instanceof Error ? err.message : String(err);
  if (name === 'AbortError' || name === 'TimeoutError') {
    return new BedrockModelError('timeout', 'Model call timed out', err);
  }
  if (
    name === 'ThrottlingException' ||
    name === 'ServiceUnavailableException' ||
    name === 'ModelNotReadyException' ||
    name === 'ServiceQuotaExceededException'
  ) {
    return new BedrockModelError('throttled', `Model throttled: ${message}`, err);
  }
  if (name === 'ModelTimeoutException') {
    return new BedrockModelError('timeout', `Model timed out: ${message}`, err);
  }
  return new BedrockModelError('model', `Model error: ${message}`, err);
}

/**
 * Pull the `submit_plan_edit` input out of a Converse response. Any shape
 * other than exactly one toolUse with string fields is `malformed`.
 */
export function extractPlanEditToolInput(
  content: ContentBlock[] | undefined,
): { toolUseId: string; input: PlanEditToolInput } {
  const toolUse = content?.find((b) => b.toolUse)?.toolUse;
  if (!toolUse) {
    throw new BedrockModelError(
      'malformed',
      'Model response contained no submit_plan_edit tool call',
    );
  }
  if (toolUse.name !== PLAN_EDIT_TOOL_NAME) {
    throw new BedrockModelError(
      'malformed',
      `Model called unexpected tool "${toolUse.name ?? ''}"`,
    );
  }
  const input = toolUse.input as Partial<PlanEditToolInput> | undefined;
  if (
    !input ||
    typeof input.plan_markdown !== 'string' ||
    typeof input.summary !== 'string'
  ) {
    throw new BedrockModelError(
      'malformed',
      'submit_plan_edit input is missing plan_markdown or summary',
    );
  }
  return {
    toolUseId: toolUse.toolUseId ?? '',
    input: { plan_markdown: input.plan_markdown, summary: input.summary },
  };
}

export class RealBedrockPlanEditor implements BedrockPlanEditor {
  readonly modelId: string;
  private readonly client: BedrockRuntimeClient;

  constructor(opts: { modelId?: string; client?: BedrockRuntimeClient } = {}) {
    this.modelId = opts.modelId ?? aiModelId();
    this.client =
      opts.client ??
      new BedrockRuntimeClient({
        region: process.env.AWS_REGION ?? 'us-west-2',
      });
  }

  /** The exact request shape sent to Converse (exposed for tests). */
  buildInput(messages: Message[]): ConverseCommandInput {
    return {
      modelId: this.modelId,
      system: planEditSystemBlocks(),
      messages,
      toolConfig: planEditToolConfig,
      inferenceConfig: {
        maxTokens: aiMaxOutputTokens(),
        temperature: 0.2,
      },
    };
  }

  async converse(
    messages: Message[],
    options: ConverseOptions = {},
  ): Promise<PlanEditModelResponse> {
    // Own a timeout only when the caller didn't hand us a deadline.
    let timer: NodeJS.Timeout | undefined;
    let signal = options.signal;
    if (!signal) {
      const controller = new AbortController();
      timer = setTimeout(() => controller.abort(), aiModelTimeoutMs());
      signal = controller.signal;
    }

    try {
      const response = await this.client.send(
        new ConverseCommand(this.buildInput(messages)),
        { abortSignal: signal },
      );
      const { toolUseId, input } = extractPlanEditToolInput(
        response.output?.message?.content,
      );
      return {
        input,
        toolUseId,
        usage: {
          input_tokens: response.usage?.inputTokens ?? 0,
          output_tokens: response.usage?.outputTokens ?? 0,
        },
        stopReason: response.stopReason,
      };
    } catch (err) {
      if (err instanceof BedrockModelError) throw err;
      // An aborted signal can surface under several names depending on the
      // handler layer; trust the signal over the error name.
      if (signal.aborted) {
        throw new BedrockModelError('timeout', 'Model call timed out', err);
      }
      throw classifyError(err);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}

// ── Test double ──

export type FakeScriptedResponse =
  | { kind: 'ok'; plan_markdown: string; summary: string; usage?: PlanEditUsage }
  | { kind: 'error'; error: BedrockModelErrorKind; message?: string }
  | { kind: 'hang' };

export interface FakeCall {
  messages: Message[];
}

/**
 * Deterministic stand-in for tests: pops scripted responses in order and
 * records every call's messages so tests can assert prompt layout and the
 * repair-turn transcript. Throws if called more times than scripted.
 */
export class FakeBedrockPlanEditor implements BedrockPlanEditor {
  readonly modelId: string;
  readonly calls: FakeCall[] = [];
  private readonly queue: FakeScriptedResponse[];
  private seq = 0;

  constructor(
    responses: FakeScriptedResponse[],
    modelId = 'fake.plan-editor-v0',
  ) {
    this.queue = [...responses];
    this.modelId = modelId;
  }

  enqueue(...responses: FakeScriptedResponse[]): void {
    this.queue.push(...responses);
  }

  async converse(
    messages: Message[],
    options: ConverseOptions = {},
  ): Promise<PlanEditModelResponse> {
    this.calls.push({ messages: structuredClone(messages) });
    const next = this.queue.shift();
    if (!next) {
      throw new Error(
        `FakeBedrockPlanEditor: no scripted response for call #${this.calls.length}`,
      );
    }
    if (next.kind === 'error') {
      throw new BedrockModelError(
        next.error,
        next.message ?? `fake ${next.error} error`,
      );
    }
    if (next.kind === 'hang') {
      // Resolve only when the caller's deadline fires.
      await new Promise<void>((_, reject) => {
        const onAbort = () =>
          reject(new BedrockModelError('timeout', 'Model call timed out'));
        if (options.signal?.aborted) return onAbort();
        options.signal?.addEventListener('abort', onAbort, { once: true });
      });
      throw new Error('unreachable');
    }
    this.seq += 1;
    return {
      input: { plan_markdown: next.plan_markdown, summary: next.summary },
      toolUseId: `fake-tooluse-${this.seq}`,
      usage: next.usage ?? { input_tokens: 1000, output_tokens: 200 },
      stopReason: 'tool_use',
    };
  }
}

// ── Injection point ──

let activeEditor: BedrockPlanEditor | undefined;

/** The editor the route uses; the real client is built lazily on first call. */
export function getPlanEditor(): BedrockPlanEditor {
  if (!activeEditor) {
    activeEditor = new RealBedrockPlanEditor();
  }
  return activeEditor;
}

/** Tests: swap in a fake (or `undefined` to restore the lazy real client). */
export function _setPlanEditorForTests(editor: BedrockPlanEditor | undefined): void {
  activeEditor = editor;
}

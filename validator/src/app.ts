import { buildCommit, createBaseApp } from './base-app.js';
import { parseWorkout } from './parser/index.js';
import { aiRouter } from './routes/ai.js';
import { authRouter } from './routes/auth/index.js';
import { meRouter } from './routes/me.js';
import { tokensRouter } from './routes/tokens.js';
import { workoutsRouter } from './routes/workouts.js';
import { testRouter } from './routes/__test__/index.js';

interface ValidateRequest {
  markdown: string;
}

interface ExerciseSummary {
  name: string;
  setCount: number;
  groupType: string | null;
  groupName: string | null;
  parentExerciseId: string | null;
}

interface ValidateResponse {
  success: boolean;
  summary: {
    workoutName: string;
    defaultWeightUnit: string | null;
    tags: string[];
    exerciseCount: number;
    totalSetCount: number;
    exercises: ExerciseSummary[];
  } | null;
  errors: string[];
  warnings: string[];
}

const MAX_INPUT_BYTES = 1_048_576; // 1MB
const MAX_INPUT_LINES = 50_000;
const MAX_EXERCISES = 500;
const MAX_TOTAL_SETS = 10_000;

function log(entry: Record<string, unknown>): void {
  console.log(JSON.stringify(entry));
}

// Shared scaffolding (requestId/startTime middleware + GET /version) lives
// in base-app.ts so the ai-fn entry point (ai-app.ts) gets the same setup.
export const app = createBaseApp();

app.route('/v1/auth', authRouter);
app.route('/v1/me', meRouter);
app.route('/v1/tokens', tokensRouter);
app.route('/v1/workouts', workoutsRouter);

// AI plan editing. In production API Gateway routes /v1/ai/* to the
// dedicated ai-fn Lambda (src/ai-app.ts, 29 s timeout) and this mount is
// never reached; it exists so local dev (`npm run dev`), the e2e-local
// server and the Vitest suite exercise the route through the main app.
app.route('/v1/ai', aiRouter);

// Test-only endpoints (e.g. /v1/__test__/mint-token). The router's gate
// middleware 404s every request unless E2E_TEST_SECRET is set,
// LMWF_ENV !== 'prod', and the X-Test-Secret header matches — so it is
// safe to always mount. See spec/services/validator-e2e.md and
// routes/__test__/index.ts.
app.route('/v1/__test__', testRouter);

app.post('/validate', async (c) => {
  c.header('X-Validator-Version', buildCommit());
  const requestId = c.var.requestId;
  const startTime = c.var.startTime;

  // All bad-request paths share the same ValidateResponse shape so callers
  // have a single parse path. See spec/services/lmwf-validator.md.
  const badRequest = (message: string) => {
    log({
      level: 'warn',
      requestId,
      event: 'request_error',
      status: 400,
      error: message,
      durationMs: Date.now() - startTime,
    });
    return c.json<ValidateResponse>(
      { success: false, summary: null, errors: [message], warnings: [] },
      400,
    );
  };

  const contentType =
    c.req.header('content-type') ?? c.req.header('Content-Type') ?? '';

  let markdown: string | undefined;

  if (contentType.includes('text/markdown')) {
    markdown = await c.req.text();
  } else {
    let bodyStr: string;
    try {
      bodyStr = await c.req.text();
    } catch {
      bodyStr = '';
    }

    if (!bodyStr) {
      return badRequest('Missing request body');
    }

    let parsed: ValidateRequest;
    try {
      parsed = JSON.parse(bodyStr) as ValidateRequest;
    } catch {
      return badRequest('Invalid JSON body');
    }

    if (typeof parsed.markdown !== 'string') {
      return badRequest('markdown field must be a string');
    }
    markdown = parsed.markdown;
  }

  if (!markdown || markdown.trim().length === 0) {
    return badRequest('Missing or empty markdown field');
  }

  const inputBytes = Buffer.byteLength(markdown, 'utf-8');
  const lineCount = markdown.split('\n').length;

  log({
    level: 'info',
    requestId,
    event: 'request_received',
    method: c.req.method,
    contentType,
    inputBytes,
    lineCount,
  });

  if (inputBytes > MAX_INPUT_BYTES) {
    log({
      level: 'warn',
      requestId,
      event: 'request_error',
      status: 413,
      error: 'Input exceeds maximum size of 1MB',
      inputBytes,
      durationMs: Date.now() - startTime,
    });
    return c.json<ValidateResponse>(
      {
        success: false,
        summary: null,
        errors: ['Input exceeds maximum size of 1MB'],
        warnings: [],
      },
      413,
    );
  }

  if (lineCount > MAX_INPUT_LINES) {
    log({
      level: 'warn',
      requestId,
      event: 'request_error',
      status: 413,
      error: 'Input exceeds maximum of 50,000 lines',
      lineCount,
      durationMs: Date.now() - startTime,
    });
    return c.json<ValidateResponse>(
      {
        success: false,
        summary: null,
        errors: ['Input exceeds maximum of 50,000 lines'],
        warnings: [],
      },
      413,
    );
  }

  const result = parseWorkout(markdown);

  if (result.data) {
    const exerciseCount = result.data.exercises.length;
    const setCount = result.data.exercises.reduce(
      (sum, ex) => sum + ex.sets.length,
      0,
    );

    if (exerciseCount > MAX_EXERCISES) {
      log({
        level: 'warn',
        requestId,
        event: 'request_error',
        status: 413,
        error: `Workout exceeds maximum of ${MAX_EXERCISES} exercises`,
        exerciseCount,
        durationMs: Date.now() - startTime,
      });
      return c.json<ValidateResponse>(
        {
          success: false,
          summary: null,
          errors: [
            `Workout exceeds maximum of ${MAX_EXERCISES} exercises (found ${exerciseCount})`,
          ],
          warnings: [],
        },
        413,
      );
    }

    if (setCount > MAX_TOTAL_SETS) {
      log({
        level: 'warn',
        requestId,
        event: 'request_error',
        status: 413,
        error: `Workout exceeds maximum of ${MAX_TOTAL_SETS} total sets`,
        setCount,
        durationMs: Date.now() - startTime,
      });
      return c.json<ValidateResponse>(
        {
          success: false,
          summary: null,
          errors: [
            `Workout exceeds maximum of ${MAX_TOTAL_SETS} total sets (found ${setCount})`,
          ],
          warnings: [],
        },
        413,
      );
    }
  }

  const exercises: ExerciseSummary[] =
    result.data?.exercises.map((ex) => ({
      name: ex.exerciseName,
      setCount: ex.sets.length,
      groupType: ex.groupType,
      groupName: ex.groupName,
      parentExerciseId: ex.parentExerciseId,
    })) ?? [];

  const totalSetCount = exercises.reduce((sum, ex) => sum + ex.setCount, 0);

  const response: ValidateResponse = {
    success: result.success,
    summary: result.data
      ? {
          workoutName: result.data.name,
          defaultWeightUnit: result.data.defaultWeightUnit,
          tags: result.data.tags,
          exerciseCount: result.data.exercises.length,
          totalSetCount,
          exercises,
        }
      : null,
    errors: result.errors,
    warnings: result.warnings,
  };

  log({
    level: 'info',
    requestId,
    event: 'request_complete',
    status: 200,
    success: result.success,
    exerciseCount: exercises.length,
    totalSetCount,
    errorCount: result.errors.length,
    warningCount: result.warnings.length,
    durationMs: Date.now() - startTime,
  });

  return c.json<ValidateResponse>(response, 200);
});

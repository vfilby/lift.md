/**
 * Shared Hono scaffolding for the two Lambda entry points.
 *
 *   - src/app.ts     → the validator function (everything but /v1/ai)
 *   - src/ai-app.ts  → the ai-fn function (/v1/ai/* only)
 *
 * Both get the same per-request context (requestId from the API Gateway
 * event, startTime) and the same `GET /version` deploy-metadata route so a
 * smoke test can confirm which build each function is running. CORS is
 * handled by API Gateway's corsPreflight (cdk/stack.ts), not here.
 */
import { Hono } from 'hono';
import type { LambdaEvent } from '@hono/aws-lambda';
import { randomUUID } from 'node:crypto';

export type Bindings = {
  event?: LambdaEvent;
};

export type Variables = {
  requestId: string;
  startTime: number;
};

export type BaseApp = Hono<{ Bindings: Bindings; Variables: Variables }>;

// Deploy metadata. Set at deploy time via CDK context → Lambda env. Read
// per-request rather than at module load so tests can set/clear env vars
// without import-order coupling. See spec/services/lmwf-validator.md → Version.
export const buildCommit = () => process.env.BUILD_COMMIT ?? 'unknown';
export const buildTimestamp = () => process.env.BUILD_TIMESTAMP ?? 'unknown';
export const buildEnv = () => process.env.LMWF_ENV ?? 'unknown';

export function createBaseApp(): BaseApp {
  const app: BaseApp = new Hono();

  app.use('*', async (c, next) => {
    const lambdaRequestId =
      (c.env?.event as { requestContext?: { requestId?: string } } | undefined)
        ?.requestContext?.requestId;
    c.set('requestId', lambdaRequestId ?? randomUUID());
    c.set('startTime', Date.now());
    await next();
  });

  app.get('/version', (c) => {
    c.header('Cache-Control', 'no-store');
    return c.json({
      commit: buildCommit(),
      builtAt: buildTimestamp(),
      env: buildEnv(),
    });
  });

  return app;
}

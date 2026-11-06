/**
 * Hono app for the dedicated `ai-fn` Lambda.
 *
 * Mounts ONLY /v1/ai/* (plus the shared /version). API Gateway routes
 * `/v1/ai/{proxy+}` here (29 s timeout, 512 MB) so the long-running model
 * call never sits on the validator function's 10 s budget — see
 * spec/services/ai-plan-editing.md → Server implementation and
 * spec/services/lmwf-validator.md → ai-fn.
 */
import { createBaseApp } from './base-app.js';
import { aiRouter } from './routes/ai.js';

export const aiApp = createBaseApp();

aiApp.route('/v1/ai', aiRouter);

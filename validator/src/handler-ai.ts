import { handle } from '@hono/aws-lambda';
import { aiApp } from './ai-app.js';

export const handler = handle(aiApp);

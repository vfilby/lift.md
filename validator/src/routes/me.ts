/**
 * GET /v1/me — the authenticated caller's own profile.
 *
 * Accepts EITHER a session JWT OR a PAT (resource-endpoint convention — the
 * same combined `auth` middleware the workout outbox / tokens resource routes
 * use). No scope is required beyond authentication: it is the caller's own
 * data, so any authenticated token may read it. See
 * `spec/services/authentication.md` → `GET /v1/me`.
 */
import { Hono } from 'hono';
import { auth, type AuthVariables } from '../middleware/auth.js';
import { getUserById } from '../repositories/users.js';

export const meRouter = new Hono<{ Variables: AuthVariables }>();

meRouter.get('/', auth, async (c) => {
  // `auth` attaches c.var.user for both PAT and session callers, but re-read
  // the row by id so the response always reflects current state (the PAT path
  // already loads it, but a fresh GetItem keeps the two auth shapes uniform
  // and is the source of truth for the 404 path).
  const userId = c.var.user.user_id;
  const user = await getUserById(userId);
  if (!user) {
    return c.json({ error: 'User not found' }, 404);
  }
  return c.json(
    {
      user_id: user.user_id,
      primary_email: user.primary_email,
      display_name: user.display_name,
      tier: user.tier,
      trial_ends_at: user.trial_ends_at,
    },
    200,
  );
});

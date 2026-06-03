/**
 * GET /v1/me — the authenticated caller's own profile.
 *
 * Accepts EITHER a session JWT OR a PAT (resource-endpoint convention — the
 * same combined `auth` middleware the workout outbox / tokens resource routes
 * use). No scope is required beyond authentication.
 *
 * PII is response-shaped by auth modality (least privilege):
 *   - **Session JWT** (the user inspecting their own account in the app /
 *     dashboard) → full profile incl. `primary_email` + `display_name`.
 *   - **PAT** (a least-privilege credential a user may hand to a third-party
 *     agent — Claude Code, ChatGPT, scripts) → non-PII subset only
 *     (`user_id`, `tier`, `trial_ends_at`). A workouts-scoped agent token must
 *     not be able to read the account email/name. See
 *     `spec/services/authentication.md` → `GET /v1/me`.
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

  // Non-PII base — safe for any authenticated caller, enough to gate features
  // (e.g. an agent checking the user is on a paid/trial plan).
  const base = {
    user_id: user.user_id,
    tier: user.tier,
    trial_ends_at: user.trial_ends_at,
  };

  // `c.var.token` is set ONLY on the PAT path (the session path leaves it
  // undefined). Withhold account PII (email/name) from PAT callers.
  const isPat = c.var.token != null;
  if (isPat) {
    return c.json(base, 200);
  }

  return c.json(
    {
      ...base,
      primary_email: user.primary_email,
      display_name: user.display_name,
    },
    200,
  );
});

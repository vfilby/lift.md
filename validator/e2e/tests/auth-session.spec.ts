import { expect, test } from '@playwright/test';
import { login, seedUser } from '../helpers/api.js';
import { uniqueEmail } from '../helpers/env.js';

/**
 * Topology-delta test: the `lmwf_refresh` cookie's Set-Cookie ATTRIBUTES.
 *
 * Why this earns an e2e slot (and isn't left to Vitest): the route handler's
 * `setCookie(...)` call is pinned in-process by
 * validator/tests/routes/auth/password.test.ts:692 ("login sets an httpOnly
 * lmwf_refresh cookie scoped to /v1/auth"). But the BYTES that reach a real
 * client are produced by whatever sits in front of the Lambda — API Gateway
 * (HTTP API payload v2 multiValueHeaders) and, for the browser flow,
 * CloudFront. Either can drop, fold, or rewrite Set-Cookie. A regression
 * there (e.g. a CF response-headers-policy stripping Set-Cookie, or APIGW
 * collapsing multi-value headers) is INVISIBLE to the in-process test and
 * only shows up over the wire — which is exactly what e2e-beta exercises.
 *
 * The assertion is mode-agnostic: the header is readable in both local and
 * remote mode, so this guards prod via BOTH e2e-local and e2e-beta.
 */
test('login Set-Cookie carries HttpOnly + Secure + SameSite + Path=/v1/auth', async () => {
  const email = uniqueEmail('cookie');
  // seedUser() and login() both default to the shared test password, so we
  // don't restate the literal here (keeps the secret scanner quiet and DRY).
  await seedUser({ email });

  const { setCookie } = await login({ email });

  expect(
    setCookie,
    'login response must carry a Set-Cookie header (APIGW/CloudFront can strip it)',
  ).toBeTruthy();
  const cookie = setCookie as string;

  // The refresh cookie must be present and named exactly lmwf_refresh.
  expect(cookie).toMatch(/lmwf_refresh=/);
  // httpOnly: not script-readable — the whole point of moving the refresh
  // token out of localStorage (M2).
  expect(cookie).toMatch(/;\s*HttpOnly/i);
  // Secure: only sent over HTTPS. (Hono emits this regardless of the
  // request scheme; over the wire on beta/prod it is load-bearing.)
  expect(cookie).toMatch(/;\s*Secure/i);
  // SameSite=Strict: CSRF mitigation on the state-changing /v1/auth routes.
  expect(cookie).toMatch(/;\s*SameSite=Strict/i);
  // Path scoping: the cookie must only ride /v1/auth requests, never the
  // whole API surface. A path widened to "/" would leak the refresh token
  // onto every API call.
  expect(cookie).toMatch(/;\s*Path=\/v1\/auth(?:;|$)/i);
});

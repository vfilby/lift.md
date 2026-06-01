import { expect, test } from '@playwright/test';
import { createPat, revokePat, seedUser } from '../helpers/api.js';
import { getBaseUrl, uniqueEmail } from '../helpers/env.js';

/**
 * Topology-delta test: a real PAT authenticates a live API request, then
 * stops working the instant it is revoked.
 *
 * Why this earns an e2e slot (and isn't left to Vitest): the per-route
 * tests (validator/tests/routes/workouts.test.ts:486 "without PAT → 401",
 * :498/:517/:553 scope 403s) prove the `requireScope`/PAT middleware logic
 * in-process. What they CANNOT see is whether the deployed APIGW authorizer
 * + middleware are actually wired in front of the Lambda route over the
 * wire — a routing/authorizer misconfiguration (PAT never reaches the
 * handler, or the Authorization header is stripped by APIGW) would pass
 * every in-process test and still 401/500 every real third-party client.
 * Driving a minted PAT through a real HTTPS GET, then revoking and
 * re-driving it, proves the full deployed auth path round-trips. Valuable
 * specifically on e2e-beta.
 *
 * Mode-agnostic: works against the local stack and against beta.
 */
test('a minted PAT authenticates GET /v1/workouts, then 401s after revoke', async ({
  request,
}) => {
  // seedUser gives us a session JWT (its legitimate backdoor field) to mint
  // and later revoke the PAT — neither of which is what we're testing.
  const user = await seedUser({ email: uniqueEmail('pat-live'), tier: 'trial' });

  // Default scopes include workouts:read (tokens.ts DEFAULT_SCOPES), which
  // is exactly what GET /v1/workouts requires.
  const pat = await createPat({
    sessionJwt: user.sessionJwt,
    name: `e2e-pat-live-${Date.now()}`,
  });

  const url = `${getBaseUrl()}/v1/workouts`;

  // 1) Live request with the PAT → NOT 401. (200 with an empty inbox for a
  //    freshly seeded user; we assert non-401 rather than pinning the body,
  //    since the point is "the authorizer + scope middleware honoured it".)
  const authed = await request.get(url, {
    headers: { authorization: `Bearer ${pat.plaintext}` },
  });
  expect(
    authed.status(),
    'a valid workouts:read PAT must be honoured by the deployed authorizer + scope middleware',
  ).not.toBe(401);
  expect(authed.status()).toBe(200);

  // 2) Revoke the PAT via the session-authed DELETE.
  await revokePat({ sessionJwt: user.sessionJwt, tokenId: pat.token_id });

  // 3) Same request, same token → now 401. Proves revocation is honoured at
  //    the deployed auth layer, not just in the repository.
  const afterRevoke = await request.get(url, {
    headers: { authorization: `Bearer ${pat.plaintext}` },
  });
  expect(
    afterRevoke.status(),
    'a revoked PAT must be rejected by the deployed authorizer',
  ).toBe(401);
});

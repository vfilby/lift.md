import { describe, it, expect, beforeAll } from 'vitest';
import { createHash } from 'node:crypto';
import {
  createRefreshToken,
  getRefreshTokenByHash,
  hashRefreshToken,
  hashesEqual,
  listActiveByUserId,
  revokeAllForIdentity,
  revokeAllForUser,
  revokeFamilyByRoot,
  revokeRefreshToken,
  rotateRefreshToken,
  RotationConflictError,
} from '../../src/repositories/refresh_tokens.js';

const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

liveDdb('refresh_tokens repository', () => {
  beforeAll(() => {
    if (!process.env.DDB_ENDPOINT) {
      throw new Error('DDB_ENDPOINT not set');
    }
  });

  function uniqueId(label: string): string {
    return `${label}-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;
  }

  it('createRefreshToken: opaque plaintext + sha256 hash on the row', async () => {
    const user_id = uniqueId('user');
    const identity_id = uniqueId('id');
    const { token, plaintext } = await createRefreshToken({
      user_id,
      identity_id,
      device_label: 'unit-test',
    });

    // Plaintext shape: lm_refresh_<32 url-safe chars>.
    expect(plaintext).toMatch(/^lm_refresh_[A-Za-z0-9_-]{32}$/);

    // Hash on the row = sha256 hex of plaintext.
    expect(token.token_hash).toBe(
      createHash('sha256').update(plaintext).digest('hex'),
    );
    expect(token.token_hash).toBe(hashRefreshToken(plaintext));

    expect(token.user_id).toBe(user_id);
    expect(token.identity_id).toBe(identity_id);
    expect(token.device_label).toBe('unit-test');
    expect(token.revoked_at).toBeUndefined();
    expect(token.replaced_by).toBeUndefined();

    // Fresh login → family root is the token itself.
    expect(token.family_root_hash).toBe(token.token_hash);

    // Default expiry ≈ 1 year from issued_at.
    const lifeMs =
      new Date(token.expires_at).getTime() -
      new Date(token.issued_at).getTime();
    const oneYear = 365 * 24 * 60 * 60 * 1000;
    expect(lifeMs).toBeGreaterThan(oneYear - 2000);
    expect(lifeMs).toBeLessThan(oneYear + 2000);
  });

  it('createRefreshToken + getRefreshTokenByHash round-trip', async () => {
    const { token, plaintext } = await createRefreshToken({
      user_id: uniqueId('user'),
      identity_id: uniqueId('id'),
    });
    const fetched = await getRefreshTokenByHash(hashRefreshToken(plaintext));
    expect(fetched?.token_hash).toBe(token.token_hash);
    expect(await getRefreshTokenByHash('0'.repeat(64))).toBeNull();
  });

  it('revokeRefreshToken sets revoked_at; with replaced_by sets both', async () => {
    const { token } = await createRefreshToken({
      user_id: uniqueId('user'),
      identity_id: uniqueId('id'),
    });
    await revokeRefreshToken(token.token_hash);
    const after = await getRefreshTokenByHash(token.token_hash);
    expect(after?.revoked_at).toBeDefined();
    expect(after?.replaced_by).toBeUndefined();

    const { token: succ } = await createRefreshToken({
      user_id: token.user_id,
      identity_id: token.identity_id,
      familyRootHash: token.family_root_hash,
      expires_at: token.expires_at,
    });
    await revokeRefreshToken(succ.token_hash, {
      replaced_by: 'fake-successor-hash',
    });
    const succAfter = await getRefreshTokenByHash(succ.token_hash);
    expect(succAfter?.revoked_at).toBeDefined();
    expect(succAfter?.replaced_by).toBe('fake-successor-hash');
  });

  it('rotation inherits family_root_hash + expires_at; family cascade revokes everyone', async () => {
    const user_id = uniqueId('user');
    const identity_id = uniqueId('id');

    // Root login.
    const { token: root } = await createRefreshToken({
      user_id,
      identity_id,
    });
    expect(root.family_root_hash).toBe(root.token_hash);

    // Rotate 3 times — each successor inherits the family root and
    // the same absolute expires_at.
    let parent = root;
    const chain = [root];
    for (let i = 0; i < 3; i++) {
      const { token: next } = await createRefreshToken({
        user_id,
        identity_id,
        familyRootHash: parent.family_root_hash,
        expires_at: parent.expires_at,
      });
      expect(next.family_root_hash).toBe(root.token_hash);
      expect(next.expires_at).toBe(root.expires_at);
      chain.push(next);
      parent = next;
    }

    const cascaded = await revokeFamilyByRoot(root.family_root_hash);
    expect(cascaded).toBe(chain.length);

    for (const t of chain) {
      const after = await getRefreshTokenByHash(t.token_hash);
      expect(after?.revoked_at).toBeDefined();
    }

    // Cascading again is a no-op (everyone already revoked).
    expect(await revokeFamilyByRoot(root.family_root_hash)).toBe(0);
  });

  it('listActiveByUserId excludes revoked and expired rows', async () => {
    const user_id = uniqueId('user');
    const identity_id = uniqueId('id');

    const { token: alive } = await createRefreshToken({ user_id, identity_id });

    const { token: revoked } = await createRefreshToken({
      user_id,
      identity_id,
    });
    await revokeRefreshToken(revoked.token_hash);

    // Force an expired-in-the-past row via the expires_at injection
    // path — same code path callers use during rotation.
    const yesterday = new Date(Date.now() - 86_400_000).toISOString();
    const { token: expired } = await createRefreshToken({
      user_id,
      identity_id,
      familyRootHash: alive.family_root_hash,
      expires_at: yesterday,
    });
    expect(expired.expires_at).toBe(yesterday);

    const active = await listActiveByUserId(user_id);
    const hashes = active.map((t) => t.token_hash);
    expect(hashes).toContain(alive.token_hash);
    expect(hashes).not.toContain(revoked.token_hash);
    expect(hashes).not.toContain(expired.token_hash);
  });

  it('revokeAllForUser revokes everything still active', async () => {
    const user_id = uniqueId('user');
    const identity_id = uniqueId('id');
    const t1 = (await createRefreshToken({ user_id, identity_id })).token;
    const t2 = (await createRefreshToken({ user_id, identity_id })).token;
    const t3 = (await createRefreshToken({ user_id, identity_id })).token;

    const count = await revokeAllForUser(user_id, 'logout_all');
    expect(count).toBe(3);

    for (const t of [t1, t2, t3]) {
      const after = await getRefreshTokenByHash(t.token_hash);
      expect(after?.revoked_at).toBeDefined();
    }
  });

  it('revokeAllForIdentity only revokes rows bound to that identity', async () => {
    const user_id = uniqueId('user');
    const idA = uniqueId('idA');
    const idB = uniqueId('idB');

    const a1 = (
      await createRefreshToken({ user_id, identity_id: idA })
    ).token;
    const a2 = (
      await createRefreshToken({ user_id, identity_id: idA })
    ).token;
    const b1 = (
      await createRefreshToken({ user_id, identity_id: idB })
    ).token;

    const count = await revokeAllForIdentity(user_id, idA, 'identity_deleted');
    expect(count).toBe(2);

    expect((await getRefreshTokenByHash(a1.token_hash))?.revoked_at).toBeDefined();
    expect((await getRefreshTokenByHash(a2.token_hash))?.revoked_at).toBeDefined();
    expect((await getRefreshTokenByHash(b1.token_hash))?.revoked_at).toBeUndefined();
  });

  it('rotateRefreshToken: success path mints child + revokes parent atomically', async () => {
    const user_id = uniqueId('user');
    const identity_id = uniqueId('id');
    const { token: root } = await createRefreshToken({ user_id, identity_id });

    const { token: child, plaintext } = await rotateRefreshToken(
      root.token_hash,
      {
        user_id,
        identity_id,
        familyRootHash: root.family_root_hash,
        expires_at: root.expires_at,
      },
    );

    expect(child.token_hash).toBe(hashRefreshToken(plaintext));
    expect(child.family_root_hash).toBe(root.family_root_hash);
    expect(child.expires_at).toBe(root.expires_at);
    expect(child.revoked_at).toBeUndefined();

    // Parent is now revoked AND points at the new child.
    const parentAfter = await getRefreshTokenByHash(root.token_hash);
    expect(parentAfter?.revoked_at).toBeDefined();
    expect(parentAfter?.replaced_by).toBe(child.token_hash);

    // Child landed.
    const childAfter = await getRefreshTokenByHash(child.token_hash);
    expect(childAfter?.token_hash).toBe(child.token_hash);
  });

  it('rotateRefreshToken: second call against same oldHash throws RotationConflictError; loser child never lands', async () => {
    const user_id = uniqueId('user');
    const identity_id = uniqueId('id');
    const { token: root } = await createRefreshToken({ user_id, identity_id });

    // First call wins.
    const { token: winnerChild } = await rotateRefreshToken(root.token_hash, {
      user_id,
      identity_id,
      familyRootHash: root.family_root_hash,
      expires_at: root.expires_at,
    });

    // Capture the would-be plaintext from a second call. We can't see
    // the loser's plaintext because the function throws — but we can
    // assert that whatever hash it WOULD have inserted is absent. The
    // simpler proof: after the throw, querying the family-index returns
    // exactly TWO rows (root + winnerChild), not three.
    let thrown: unknown;
    try {
      await rotateRefreshToken(root.token_hash, {
        user_id,
        identity_id,
        familyRootHash: root.family_root_hash,
        expires_at: root.expires_at,
      });
    } catch (e) {
      thrown = e;
    }
    expect(thrown).toBeInstanceOf(RotationConflictError);

    // No orphan child — only the winner is active for this user. Root
    // is revoked, no loser row was ever inserted (transactions are atomic).
    const active = await listActiveByUserId(user_id);
    expect(active.map((t) => t.token_hash)).toEqual([winnerChild.token_hash]);

    // Parent's replaced_by still points at the winner, not the loser.
    const parentAfter = await getRefreshTokenByHash(root.token_hash);
    expect(parentAfter?.replaced_by).toBe(winnerChild.token_hash);
  });

  it('revokeFamilyByRoot: re-query path catches members added between query and last revoke', async () => {
    // We can't deterministically interleave with the running loop, so
    // we exercise the re-query path directly: revoke a family, then
    // append a new member with the same root, then revoke again. The
    // 2nd call's re-query must find the late arrival.
    const user_id = uniqueId('user');
    const identity_id = uniqueId('id');

    const { token: root } = await createRefreshToken({ user_id, identity_id });
    const rotateOnce = async (parent: typeof root) =>
      (
        await createRefreshToken({
          user_id,
          identity_id,
          familyRootHash: parent.family_root_hash,
          expires_at: parent.expires_at,
        })
      ).token;
    const r1 = await rotateOnce(root);
    const r2 = await rotateOnce(r1);

    expect(await revokeFamilyByRoot(root.family_root_hash)).toBeGreaterThan(0);
    for (const t of [root, r1, r2]) {
      expect((await getRefreshTokenByHash(t.token_hash))?.revoked_at).toBeDefined();
    }

    // Late arrival — a legitimate rotation that landed AFTER the first
    // revoke pass returned. Simulate by directly creating a new child
    // in the same family.
    const lateArrival = await rotateOnce(r2);
    expect((await getRefreshTokenByHash(lateArrival.token_hash))?.revoked_at)
      .toBeUndefined();

    // Calling revokeFamilyByRoot AGAIN exercises the same code path
    // that the in-loop re-query uses: it must find and revoke the new
    // unrevoked member.
    const second = await revokeFamilyByRoot(root.family_root_hash);
    expect(second).toBe(1);
    expect((await getRefreshTokenByHash(lateArrival.token_hash))?.revoked_at)
      .toBeDefined();
  });

  it('hashesEqual is constant-time and length-aware (documented contract)', async () => {
    // Even if not currently used on the lookup path, the helper must
    // exist + work — future code that does Query+filter on the hash
    // should reach for this rather than ===.
    const a = createHash('sha256').update('a').digest('hex');
    const b = createHash('sha256').update('a').digest('hex');
    const c = createHash('sha256').update('different').digest('hex');
    expect(hashesEqual(a, b)).toBe(true);
    expect(hashesEqual(a, c)).toBe(false);
    expect(hashesEqual(a, 'short')).toBe(false);
  });
});

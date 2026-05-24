import { describe, it, expect, beforeAll } from 'vitest';
import { createHash } from 'node:crypto';
import {
  createToken,
  getTokenByHash,
  hashToken,
  listTokensByUserId,
  markUsed,
  revokeToken,
  revokeTokenByHash,
} from '../../src/repositories/pat_tokens.js';

const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

liveDdb('pat_tokens repository', () => {
  beforeAll(() => {
    if (!process.env.DDB_ENDPOINT) {
      throw new Error('DDB_ENDPOINT not set');
    }
  });

  it('creates a token, returns plaintext exactly once, and matches the hash', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const { token, plaintext } = await createToken({
      user_id,
      name: 'My CLI',
      scopes: ['workouts:write'],
    });

    // Plaintext format: lm_pat_live_<32 url-safe chars>.
    expect(plaintext).toMatch(/^lm_pat_live_[A-Za-z0-9_-]{32}$/);
    // Hash on the row must be sha256 hex of plaintext.
    expect(token.token_hash).toBe(
      createHash('sha256').update(plaintext).digest('hex'),
    );
    expect(token.token_hash).toBe(hashToken(plaintext));

    // Prefix is the first 8 chars of the random part (not of the whole token).
    const randomPart = plaintext.slice('lm_pat_live_'.length);
    expect(token.prefix).toBe(randomPart.slice(0, 8));
    expect(token.token_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(token.scopes).toEqual(['workouts:write']);
    expect(token.revoked_at).toBeUndefined();
  });

  it('supports a test-mode prefix', async () => {
    const { plaintext } = await createToken({
      user_id: `user-${Date.now()}`,
      name: 'test mode',
      scopes: [],
      mode: 'test',
    });
    expect(plaintext).toMatch(/^lm_pat_test_[A-Za-z0-9_-]{32}$/);
  });

  it('looks up by hash', async () => {
    const { token, plaintext } = await createToken({
      user_id: `user-${Date.now()}-${Math.random()}`,
      name: 'lookup',
      scopes: ['workouts:read'],
    });

    const fetched = await getTokenByHash(hashToken(plaintext));
    expect(fetched?.token_id).toBe(token.token_id);

    const missing = await getTokenByHash('0'.repeat(64));
    expect(missing).toBeNull();
  });

  it('lists tokens for a user, newest first', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;

    const first = await createToken({ user_id, name: 'first', scopes: [] });
    // Stagger created_at by at least 1ms so the sort key is well-ordered.
    await new Promise((r) => setTimeout(r, 5));
    const second = await createToken({ user_id, name: 'second', scopes: [] });

    const list = await listTokensByUserId(user_id);
    expect(list).toHaveLength(2);
    expect(list[0].token_id).toBe(second.token.token_id);
    expect(list[1].token_id).toBe(first.token.token_id);
  });

  it('revokes by (user_id, token_id) via the user_id GSI', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const { token, plaintext } = await createToken({
      user_id,
      name: 'revoke me',
      scopes: [],
    });

    await revokeToken(user_id, token.token_id);

    const fetched = await getTokenByHash(hashToken(plaintext));
    expect(fetched?.revoked_at).toBeDefined();
    expect(new Date(fetched!.revoked_at!).getTime()).toBeGreaterThan(
      new Date(token.created_at).getTime() - 1000,
    );
  });

  it('revokeToken is a silent no-op when the token does not belong to the user', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    await expect(
      revokeToken(user_id, 'no-such-token'),
    ).resolves.toBeUndefined();
  });

  it('revokeTokenByHash on a missing hash throws', async () => {
    await expect(revokeTokenByHash('0'.repeat(64))).rejects.toThrow();
  });

  it('markUsed stamps last_used_at and last_used_ip', async () => {
    const { token, plaintext } = await createToken({
      user_id: `user-${Date.now()}-${Math.random()}`,
      name: 'used',
      scopes: [],
    });

    await markUsed(hashToken(plaintext), '203.0.113.42');
    const fetched = await getTokenByHash(token.token_hash);
    expect(fetched?.last_used_at).toBeDefined();
    expect(fetched?.last_used_ip).toBe('203.0.113.42');
  });
});

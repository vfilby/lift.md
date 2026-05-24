import { describe, it, expect, beforeAll } from 'vitest';
import {
  createIdentity,
  getIdentityById,
  getIdentityByProviderSub,
  listIdentitiesByUserId,
  markEmailVerified,
  providerLookupKey,
  updatePasswordHash,
} from '../../src/repositories/identities.js';

const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

liveDdb('identities repository', () => {
  beforeAll(() => {
    if (!process.env.DDB_ENDPOINT) {
      throw new Error('DDB_ENDPOINT not set');
    }
  });

  it('creates an identity and round-trips by id', async () => {
    const stamp = `${Date.now()}-${Math.random()}`;
    const created = await createIdentity({
      user_id: `user-${stamp}`,
      provider: 'apple',
      provider_sub: `apple-sub-${stamp}`,
      email: `alice-${stamp}@example.com`,
      email_verified: true,
    });

    expect(created.identity_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(created.provider_lookup).toBe(
      providerLookupKey('apple', `apple-sub-${stamp}`),
    );

    const fetched = await getIdentityById(created.identity_id);
    expect(fetched?.identity_id).toBe(created.identity_id);
    expect(fetched?.provider).toBe('apple');
    expect(fetched?.email_verified).toBe(true);
  });

  it('looks up an identity via the provider-lookup GSI', async () => {
    const stamp = `${Date.now()}-${Math.random()}`;
    const sub = `gh-sub-${stamp}`;
    const created = await createIdentity({
      user_id: `user-${stamp}`,
      provider: 'github',
      provider_sub: sub,
      email: `gh-${stamp}@example.com`,
      email_verified: false,
    });

    const found = await getIdentityByProviderSub('github', sub);
    expect(found?.identity_id).toBe(created.identity_id);

    const notFound = await getIdentityByProviderSub('github', `nope-${stamp}`);
    expect(notFound).toBeNull();
  });

  it('lists all identities for a user via the user_id GSI', async () => {
    const stamp = `${Date.now()}-${Math.random()}`;
    const user_id = `user-${stamp}`;

    await createIdentity({
      user_id,
      provider: 'password',
      provider_sub: `pw-${stamp}@example.com`,
      email: `pw-${stamp}@example.com`,
      email_verified: false,
      password_hash: 'argon2id$placeholder',
    });
    await createIdentity({
      user_id,
      provider: 'apple',
      provider_sub: `apple-${stamp}`,
      email: `apple-${stamp}@privaterelay.appleid.com`,
      email_verified: true,
    });

    const list = await listIdentitiesByUserId(user_id);
    expect(list).toHaveLength(2);
    const providers = list.map((i) => i.provider).sort();
    expect(providers).toEqual(['apple', 'password']);
  });

  it('updates a password hash and stamps password_updated_at', async () => {
    const stamp = `${Date.now()}-${Math.random()}`;
    const created = await createIdentity({
      user_id: `user-${stamp}`,
      provider: 'password',
      provider_sub: `pw-${stamp}@example.com`,
      email: `pw-${stamp}@example.com`,
      email_verified: false,
      password_hash: 'old-hash',
    });

    await updatePasswordHash(created.identity_id, 'new-hash');

    const fetched = await getIdentityById(created.identity_id);
    expect(fetched?.password_hash).toBe('new-hash');
    expect(fetched?.password_updated_at).toBeDefined();
    expect(new Date(fetched!.password_updated_at!).getTime()).toBeGreaterThan(
      new Date(created.created_at).getTime() - 1000,
    );
  });

  it('marks email as verified', async () => {
    const stamp = `${Date.now()}-${Math.random()}`;
    const created = await createIdentity({
      user_id: `user-${stamp}`,
      provider: 'password',
      provider_sub: `verify-${stamp}@example.com`,
      email: `verify-${stamp}@example.com`,
      email_verified: false,
    });

    await markEmailVerified(created.identity_id);
    const fetched = await getIdentityById(created.identity_id);
    expect(fetched?.email_verified).toBe(true);
  });

  it('updatePasswordHash on a missing identity throws', async () => {
    await expect(
      updatePasswordHash(`ghost-${Date.now()}`, 'h'),
    ).rejects.toThrow();
  });
});

import { describe, it, expect, beforeAll } from 'vitest';
import {
  createUser,
  getUserById,
  updateUserTier,
} from '../../src/repositories/users.js';

// Live DDB Local tests — skipped unless DDB_ENDPOINT is set.
const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

liveDdb('users repository', () => {
  beforeAll(() => {
    if (!process.env.DDB_ENDPOINT) {
      throw new Error('DDB_ENDPOINT not set');
    }
  });

  it('creates a user with sensible defaults', async () => {
    const email = `user-${Date.now()}-${Math.random()}@Example.COM`;
    const user = await createUser({
      display_name: 'Alice',
      primary_email: email,
      signup_ip: '127.0.0.1',
      signup_user_agent: 'vitest',
    });

    expect(user.user_id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
    // Email should be lowercased on write.
    expect(user.primary_email).toBe(email.toLowerCase());
    expect(user.tier).toBe('trial');

    // trial_ends_at must be exactly 30 days after created_at.
    const created = new Date(user.created_at).getTime();
    const trialEnds = new Date(user.trial_ends_at).getTime();
    const diffDays = (trialEnds - created) / (24 * 60 * 60 * 1000);
    expect(diffDays).toBeCloseTo(30, 5);
  });

  it('round-trips via getUserById', async () => {
    const email = `roundtrip-${Date.now()}@example.com`;
    const created = await createUser({
      display_name: 'Bob',
      primary_email: email,
    });

    const fetched = await getUserById(created.user_id);
    expect(fetched).not.toBeNull();
    expect(fetched?.user_id).toBe(created.user_id);
    expect(fetched?.display_name).toBe('Bob');
    expect(fetched?.tier).toBe('trial');
    // Optional fields not provided should not be present on the row.
    expect(fetched?.signup_ip).toBeUndefined();
  });

  it('returns null for an unknown user_id', async () => {
    const missing = await getUserById(`missing-${Date.now()}`);
    expect(missing).toBeNull();
  });

  it('updates the tier', async () => {
    const user = await createUser({
      display_name: 'Carol',
      primary_email: `tier-${Date.now()}@example.com`,
    });
    await updateUserTier(user.user_id, 'pro');
    const fetched = await getUserById(user.user_id);
    expect(fetched?.tier).toBe('pro');
  });

  it('updateUserTier on a missing user throws (conditional check)', async () => {
    await expect(
      updateUserTier(`ghost-${Date.now()}`, 'pro'),
    ).rejects.toThrow();
  });
});

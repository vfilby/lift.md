import { describe, it, expect, beforeAll } from 'vitest';
import {
  createOutboxItem,
  deleteOutboxItem,
  getOutboxItem,
  getOutboxItemsByUser,
  MAX_OUTBOX_ITEMS_PER_USER,
} from '../../src/repositories/workout_outbox.js';

const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

function input(user_id: string, overrides: Partial<{
  client_session_id: string;
  session_name: string;
  session_completed_at: string;
  payload_json: unknown;
}> = {}) {
  return {
    user_id,
    source_device_id: 'device-1',
    client_session_id: overrides.client_session_id ?? `sess-${Math.random()}`,
    payload_json: overrides.payload_json ?? { session: { name: 'X' } },
    session_completed_at:
      overrides.session_completed_at ?? new Date().toISOString(),
    session_name: overrides.session_name ?? 'Push Day',
  };
}

liveDdb('workout_outbox repository', () => {
  beforeAll(() => {
    if (!process.env.DDB_ENDPOINT) {
      throw new Error('DDB_ENDPOINT not set');
    }
  });

  it('creates an item with a ULID outbox_id', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const { item, dedupHit, trimmedCount } = await createOutboxItem(
      input(user_id),
    );

    expect(item.user_id).toBe(user_id);
    expect(item.outbox_id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(dedupHit).toBe(false);
    expect(trimmedCount).toBe(0);
  });

  it('dedups by (user_id, client_session_id)', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const csid = `sess-${Math.random()}`;

    const first = await createOutboxItem(
      input(user_id, { client_session_id: csid, session_name: 'first' }),
    );
    expect(first.dedupHit).toBe(false);

    const second = await createOutboxItem(
      input(user_id, { client_session_id: csid, session_name: 'second' }),
    );
    expect(second.dedupHit).toBe(true);
    expect(second.item.outbox_id).toBe(first.item.outbox_id);
    // Payload from the *first* push wins — second is a no-op.
    expect(second.item.session_name).toBe('first');
  });

  it('lists items newest-first for a user', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const a = await createOutboxItem(input(user_id));
    await new Promise((r) => setTimeout(r, 5));
    const b = await createOutboxItem(input(user_id));

    const items = await getOutboxItemsByUser(user_id);
    expect(items).toHaveLength(2);
    expect(items[0].outbox_id).toBe(b.item.outbox_id);
    expect(items[1].outbox_id).toBe(a.item.outbox_id);
  });

  it(`trims to last ${MAX_OUTBOX_ITEMS_PER_USER} on write`, async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;

    // Push N+3 items; expect three trims by the end.
    let totalTrimmed = 0;
    for (let i = 0; i < MAX_OUTBOX_ITEMS_PER_USER + 3; i++) {
      const r = await createOutboxItem(input(user_id));
      totalTrimmed += r.trimmedCount;
      await new Promise((r) => setTimeout(r, 2));
    }
    expect(totalTrimmed).toBe(3);

    const items = await getOutboxItemsByUser(user_id);
    expect(items.length).toBe(MAX_OUTBOX_ITEMS_PER_USER);
  });

  it('fetches a single item by id', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const { item } = await createOutboxItem(input(user_id));
    const fetched = await getOutboxItem(user_id, item.outbox_id);
    expect(fetched?.outbox_id).toBe(item.outbox_id);
  });

  it('returns null for a missing item', async () => {
    const fetched = await getOutboxItem(`ghost-${Date.now()}`, 'nope');
    expect(fetched).toBeNull();
  });

  it('deletes an owned item', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const { item } = await createOutboxItem(input(user_id));
    await deleteOutboxItem(user_id, item.outbox_id);
    const fetched = await getOutboxItem(user_id, item.outbox_id);
    expect(fetched).toBeNull();
  });

  it('deleting a missing item throws', async () => {
    await expect(
      deleteOutboxItem(`ghost-${Date.now()}`, 'nope'),
    ).rejects.toThrow();
  });
});

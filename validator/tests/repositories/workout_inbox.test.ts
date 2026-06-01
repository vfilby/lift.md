import { describe, it, expect, beforeAll } from 'vitest';
import {
  createInboxItem,
  findPendingByContentHash,
  getInboxItemsByUser,
  inboxContentHash,
  markIngested,
} from '../../src/repositories/workout_inbox.js';

describe('inboxContentHash', () => {
  it('is stable and ignores surrounding whitespace', () => {
    const a = inboxContentHash('# Push\n## Bench\n- 135 x 5');
    const b = inboxContentHash('\n  # Push\n## Bench\n- 135 x 5  \n');
    expect(a).toBe(b);
    expect(a).toMatch(/^[0-9a-f]{64}$/);
  });

  it('differs for different content', () => {
    expect(inboxContentHash('a')).not.toBe(inboxContentHash('b'));
  });
});

const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

liveDdb('workout_inbox repository', () => {
  beforeAll(() => {
    if (!process.env.DDB_ENDPOINT) {
      throw new Error('DDB_ENDPOINT not set');
    }
  });

  it('creates an item with a ULID inbox_id', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const item = await createInboxItem({
      user_id,
      source_token_id: 'tok-1',
      lmwf_text: '# Push Day\n## Bench Press\n- 135 x 5',
      status: 'pending',
    });

    expect(item.user_id).toBe(user_id);
    expect(item.status).toBe('pending');
    // ULIDs are 26 chars of Crockford base32 — lexicographic = chronological.
    expect(item.inbox_id).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(item.ingested_at).toBeUndefined();
    // Content hash is stamped for push-time dedup (GH #193).
    expect(item.content_hash).toBe(inboxContentHash(item.lmwf_text));
  });

  it('findPendingByContentHash matches a pending item, scoped per-user and to pending', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const lmwf = '# Push Day\n## Bench Press\n- 135 x 5';
    const hash = inboxContentHash(lmwf);

    const item = await createInboxItem({
      user_id,
      source_token_id: 'tok',
      lmwf_text: lmwf,
      status: 'pending',
    });

    // Same content, same user → found.
    const found = await findPendingByContentHash(user_id, hash);
    expect(found?.inbox_id).toBe(item.inbox_id);

    // Different content → not found.
    expect(
      await findPendingByContentHash(user_id, inboxContentHash('other')),
    ).toBeNull();

    // Another user with the same content → not found (per-user scope).
    expect(
      await findPendingByContentHash(`other-${user_id}`, hash),
    ).toBeNull();

    // Once ingested, it no longer matches (pending-only scope).
    await markIngested(user_id, item.inbox_id);
    expect(await findPendingByContentHash(user_id, hash)).toBeNull();
  });

  it('lists items newest-first for a user', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const a = await createInboxItem({
      user_id,
      source_token_id: 'tok',
      lmwf_text: 'a',
      status: 'pending',
    });
    // Spread the timestamps so the SK ordering is unambiguous.
    await new Promise((r) => setTimeout(r, 5));
    const b = await createInboxItem({
      user_id,
      source_token_id: 'tok',
      lmwf_text: 'b',
      status: 'pending',
    });

    const { items, nextCursor } = await getInboxItemsByUser(user_id);
    expect(items).toHaveLength(2);
    expect(items[0].inbox_id).toBe(b.inbox_id);
    expect(items[1].inbox_id).toBe(a.inbox_id);
    expect(nextCursor).toBeUndefined();
  });

  it('filters by status', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const pending = await createInboxItem({
      user_id,
      source_token_id: 'tok',
      lmwf_text: 'p',
      status: 'pending',
    });
    await createInboxItem({
      user_id,
      source_token_id: 'tok',
      lmwf_text: 'r',
      status: 'rejected',
    });

    const { items } = await getInboxItemsByUser(user_id, {
      status: 'pending',
    });
    expect(items).toHaveLength(1);
    expect(items[0].inbox_id).toBe(pending.inbox_id);
  });

  it('paginates via opaque sinceCursor', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    for (let i = 0; i < 3; i++) {
      await createInboxItem({
        user_id,
        source_token_id: 'tok',
        lmwf_text: `item-${i}`,
        status: 'pending',
      });
      // Ensure distinct created_at values.
      await new Promise((r) => setTimeout(r, 5));
    }

    const page1 = await getInboxItemsByUser(user_id, { limit: 2 });
    expect(page1.items).toHaveLength(2);
    expect(page1.nextCursor).toBeDefined();

    const page2 = await getInboxItemsByUser(user_id, {
      limit: 2,
      sinceCursor: page1.nextCursor,
    });
    expect(page2.items).toHaveLength(1);
    expect(page2.nextCursor).toBeUndefined();

    // No overlap between pages.
    const seen = new Set(
      [...page1.items, ...page2.items].map((i) => i.inbox_id),
    );
    expect(seen.size).toBe(3);
  });

  it('marks an item as ingested', async () => {
    const user_id = `user-${Date.now()}-${Math.random()}`;
    const item = await createInboxItem({
      user_id,
      source_token_id: 'tok',
      lmwf_text: 'x',
      status: 'pending',
    });

    await markIngested(user_id, item.inbox_id);
    const { items } = await getInboxItemsByUser(user_id);
    expect(items).toHaveLength(1);
    expect(items[0].status).toBe('ingested');
    expect(items[0].ingested_at).toBeDefined();
  });

  it('markIngested on a missing item throws', async () => {
    await expect(
      markIngested(`ghost-${Date.now()}`, 'nope'),
    ).rejects.toThrow();
  });
});

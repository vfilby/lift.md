import { describe, it, expect, beforeAll } from 'vitest';
import { GetCommand, PutCommand } from '@aws-sdk/lib-dynamodb';
import { ddb, tableName } from '../src/infra/ddb.js';

// Live DDB Local smoke test — verifies the dev/prod-parity client
// wrapper can actually round-trip a record against a real DynamoDB
// instance. Skipped unless DDB_ENDPOINT is set (the make dev-up target
// starts the container + sets the env var; CI will mirror this once we
// wire it up).
const liveDdb = process.env.DDB_ENDPOINT ? describe : describe.skip;

liveDdb('DDB Local round-trip', () => {
  beforeAll(() => {
    if (!process.env.DDB_ENDPOINT) {
      // Should be unreachable thanks to describe.skip — kept for clarity.
      throw new Error('DDB_ENDPOINT not set');
    }
  });

  it('puts and gets a user record', async () => {
    const userId = `smoke-${Date.now()}`;
    const table = tableName('users');

    await ddb.send(
      new PutCommand({
        TableName: table,
        Item: {
          user_id: userId,
          display_name: 'Smoke Test',
          primary_email: 'smoke@example.com',
          created_at: new Date().toISOString(),
          tier: 'trial',
        },
      }),
    );

    const result = await ddb.send(
      new GetCommand({ TableName: table, Key: { user_id: userId } }),
    );

    expect(result.Item).toBeDefined();
    expect(result.Item?.user_id).toBe(userId);
    expect(result.Item?.tier).toBe('trial');
  });
});

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import {
  TABLES,
  defaultLocalTableName,
  type TableLogicalName,
} from './tables.js';

/**
 * Configured DynamoDBDocumentClient — use this everywhere instead of
 * constructing a client directly.
 *
 * In production, the Lambda runs with the default credential provider
 * chain and talks to real DynamoDB. In local dev, set DDB_ENDPOINT
 * (the make dev-up target points this at http://localhost:8000).
 */
const endpoint = process.env.DDB_ENDPOINT;

const rawClient = new DynamoDBClient({
  endpoint,
  region: process.env.AWS_REGION ?? 'us-west-2',
  ...(endpoint
    ? { credentials: { accessKeyId: 'local', secretAccessKey: 'local' } }
    : {}),
});

export const ddb = DynamoDBDocumentClient.from(rawClient, {
  marshallOptions: {
    // Treat empty strings as legitimate values (instead of dropping them).
    convertEmptyValues: false,
    // Drop undefined fields rather than throwing — easier app-code ergonomics.
    removeUndefinedValues: true,
  },
});

/**
 * Resolve the real DynamoDB table name for a given logical table.
 *
 * Reads from `DDB_TABLE_<NAME>` env vars (set by CDK in prod). In local
 * dev, falls back to the convention `lmwf-local-<name>` so the bootstrap
 * script and app stay in sync without requiring explicit env wiring.
 */
export function tableName(logical: TableLogicalName): string {
  const envKey = `DDB_TABLE_${logical.toUpperCase()}`;
  const value = process.env[envKey];
  if (value) return value;

  // Only fall back to the local default when we're actually pointed at a
  // local DDB endpoint — never silently default in prod.
  if (endpoint) return defaultLocalTableName(logical);

  throw new Error(
    `Environment variable ${envKey} is not set and DDB_ENDPOINT is not configured; cannot resolve table name for "${logical}"`,
  );
}

// Re-export for convenience so call sites can `import { ddb, t } from '../infra/ddb.js'`.
export { TABLES };

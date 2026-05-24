/**
 * Shared DynamoDB table schema definitions.
 *
 * Single source of truth, two consumers:
 *   - validator/cdk/stack.ts creates the real tables in AWS
 *   - validator/scripts/ddb-local-bootstrap.ts creates the same tables
 *     in a DDB Local container for development
 *
 * Adding a table: append to TABLES below, then run `make dev-up` (local)
 * and `make deploy` (prod) to roll out.
 *
 * The logical name (the key in TABLES) is used everywhere in application
 * code; the real DynamoDB table name is read from an env var named
 * `DDB_TABLE_<LOGICAL_NAME_UPPERCASE>` (e.g. DDB_TABLE_USERS). CDK sets
 * these env vars on the Lambda; the bootstrap script defaults them for
 * local dev.
 */

export type AttributeType = 'S' | 'N' | 'B';

export interface KeySchema {
  name: string;
  type: AttributeType;
}

export interface GlobalSecondaryIndex {
  indexName: string;
  partitionKey: KeySchema;
  sortKey?: KeySchema;
  /** Default 'ALL' — DDB Local only supports ALL or KEYS_ONLY reliably. */
  projection?: 'ALL' | 'KEYS_ONLY';
}

export interface TableSchema {
  /** Logical name — used as the env-var suffix and CDK construct ID. */
  logicalName: string;
  partitionKey: KeySchema;
  sortKey?: KeySchema;
  globalSecondaryIndexes?: GlobalSecondaryIndex[];
  /** Enable point-in-time recovery in production. Ignored locally. */
  pointInTimeRecovery?: boolean;
}

export const TABLES = {
  users: {
    logicalName: 'users',
    partitionKey: { name: 'user_id', type: 'S' },
    pointInTimeRecovery: true,
  },
  identities: {
    logicalName: 'identities',
    partitionKey: { name: 'identity_id', type: 'S' },
    globalSecondaryIndexes: [
      {
        // Look up all identities belonging to a user.
        indexName: 'user_id-index',
        partitionKey: { name: 'user_id', type: 'S' },
      },
      {
        // Look up an identity by provider + provider_sub during sign-in.
        // E.g. provider_lookup = "apple#001234.abcd..." (composed in app code).
        indexName: 'provider-lookup-index',
        partitionKey: { name: 'provider_lookup', type: 'S' },
      },
    ],
    pointInTimeRecovery: true,
  },
  pat_tokens: {
    logicalName: 'pat_tokens',
    // PK is the token hash so auth-middleware lookup is a single GetItem.
    partitionKey: { name: 'token_hash', type: 'S' },
    globalSecondaryIndexes: [
      {
        // List all tokens for a user (settings UI).
        indexName: 'user_id-index',
        partitionKey: { name: 'user_id', type: 'S' },
        sortKey: { name: 'created_at', type: 'S' },
      },
    ],
    pointInTimeRecovery: true,
  },
  entitlements: {
    logicalName: 'entitlements',
    partitionKey: { name: 'user_id', type: 'S' },
    globalSecondaryIndexes: [
      {
        // Webhook lookups by Stripe subscription id.
        indexName: 'stripe-subscription-index',
        partitionKey: { name: 'stripe_subscription_id', type: 'S' },
      },
    ],
    pointInTimeRecovery: true,
  },
  refresh_tokens: {
    logicalName: 'refresh_tokens',
    // PK is the token hash so refresh lookup is a single GetItem on the
    // hot path. Plaintext is opaque random; rows in this table are the
    // sole source of truth for refresh-token validity.
    partitionKey: { name: 'token_hash', type: 'S' },
    globalSecondaryIndexes: [
      {
        // List a user's refresh tokens (logout-all + identity cascade).
        // Sort key is issued_at so the freshest tokens come first.
        indexName: 'user_id-index',
        partitionKey: { name: 'user_id', type: 'S' },
        sortKey: { name: 'issued_at', type: 'S' },
      },
      {
        // Reuse-detection cascade: given a family root, find every
        // descendant so they can all be revoked in one sweep.
        indexName: 'family-index',
        partitionKey: { name: 'family_root_hash', type: 'S' },
      },
    ],
    pointInTimeRecovery: true,
  },
  workout_inbox: {
    logicalName: 'workout_inbox',
    // Composite key: items are scoped to a user and sorted by created_at desc.
    partitionKey: { name: 'user_id', type: 'S' },
    sortKey: { name: 'inbox_id', type: 'S' },
    globalSecondaryIndexes: [
      {
        // Polling by status (for the cleanup/reaping job).
        indexName: 'status-index',
        partitionKey: { name: 'status', type: 'S' },
        sortKey: { name: 'created_at', type: 'S' },
      },
    ],
    pointInTimeRecovery: true,
  },
} as const satisfies Record<string, TableSchema>;

export type TableLogicalName = keyof typeof TABLES;

/**
 * Default local table name for a logical table — used by the bootstrap
 * script and as the fallback when DDB_ENDPOINT is set but no explicit
 * DDB_TABLE_<NAME> env var is provided.
 */
export function defaultLocalTableName(logical: TableLogicalName): string {
  return `lmwf-local-${logical}`;
}

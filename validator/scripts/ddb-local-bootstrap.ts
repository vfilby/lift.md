/**
 * Create the validator's DynamoDB tables in DDB Local.
 *
 * Run via `make dev-up` (which also starts the docker-compose stack).
 * Idempotent — existing tables are left alone.
 *
 * Reads schemas from src/infra/tables.ts so this stays in lockstep with
 * the CDK stack. Default table names match what server.ts expects when
 * no DDB_TABLE_* env vars are explicitly set.
 */
import {
  DynamoDBClient,
  CreateTableCommand,
  DescribeTableCommand,
  ResourceNotFoundException,
  ResourceInUseException,
  type AttributeDefinition,
  type GlobalSecondaryIndex,
  type KeySchemaElement,
} from '@aws-sdk/client-dynamodb';
import {
  TABLES,
  defaultLocalTableName,
  type AttributeType,
  type TableSchema,
} from '../src/infra/tables.js';

const ENDPOINT = process.env.DDB_ENDPOINT ?? 'http://localhost:8000';

const client = new DynamoDBClient({
  endpoint: ENDPOINT,
  region: 'us-east-1', // DDB Local ignores region but the SDK requires one.
  credentials: { accessKeyId: 'local', secretAccessKey: 'local' },
});

function attrType(t: AttributeType): 'S' | 'N' | 'B' {
  return t;
}

function buildKeySchema(schema: TableSchema): KeySchemaElement[] {
  const keys: KeySchemaElement[] = [
    { AttributeName: schema.partitionKey.name, KeyType: 'HASH' },
  ];
  if (schema.sortKey) {
    keys.push({ AttributeName: schema.sortKey.name, KeyType: 'RANGE' });
  }
  return keys;
}

function buildAttributeDefinitions(schema: TableSchema): AttributeDefinition[] {
  // Dedupe by attribute name — same field may appear in PK and a GSI.
  const seen = new Map<string, AttributeDefinition>();
  const add = (name: string, type: AttributeType): void => {
    if (!seen.has(name)) {
      seen.set(name, { AttributeName: name, AttributeType: attrType(type) });
    }
  };

  add(schema.partitionKey.name, schema.partitionKey.type);
  if (schema.sortKey) add(schema.sortKey.name, schema.sortKey.type);

  for (const gsi of schema.globalSecondaryIndexes ?? []) {
    add(gsi.partitionKey.name, gsi.partitionKey.type);
    if (gsi.sortKey) add(gsi.sortKey.name, gsi.sortKey.type);
  }

  return Array.from(seen.values());
}

function buildGsis(schema: TableSchema): GlobalSecondaryIndex[] | undefined {
  if (!schema.globalSecondaryIndexes?.length) return undefined;
  return schema.globalSecondaryIndexes.map((gsi) => {
    const keys: KeySchemaElement[] = [
      { AttributeName: gsi.partitionKey.name, KeyType: 'HASH' },
    ];
    if (gsi.sortKey) {
      keys.push({ AttributeName: gsi.sortKey.name, KeyType: 'RANGE' });
    }
    return {
      IndexName: gsi.indexName,
      KeySchema: keys,
      Projection: {
        ProjectionType: gsi.projection === 'KEYS_ONLY' ? 'KEYS_ONLY' : 'ALL',
      },
    };
  });
}

async function tableExists(tableName: string): Promise<boolean> {
  try {
    await client.send(new DescribeTableCommand({ TableName: tableName }));
    return true;
  } catch (err) {
    if (err instanceof ResourceNotFoundException) return false;
    throw err;
  }
}

async function ensureTable(schema: TableSchema): Promise<void> {
  const tableName = defaultLocalTableName(schema.logicalName);

  if (await tableExists(tableName)) {
    console.log(`[skip] ${tableName} already exists`);
    return;
  }

  try {
    await client.send(
      new CreateTableCommand({
        TableName: tableName,
        BillingMode: 'PAY_PER_REQUEST',
        KeySchema: buildKeySchema(schema),
        AttributeDefinitions: buildAttributeDefinitions(schema),
        GlobalSecondaryIndexes: buildGsis(schema),
      }),
    );
    console.log(`[created] ${tableName}`);
  } catch (err) {
    if (err instanceof ResourceInUseException) {
      console.log(`[exists] ${tableName} (race)`);
      return;
    }
    throw err;
  }
}

async function main(): Promise<void> {
  console.log(`Bootstrapping DDB Local at ${ENDPOINT}`);
  for (const schema of Object.values(TABLES)) {
    await ensureTable(schema);
  }
  console.log('Done.');
}

main().catch((err) => {
  console.error('Bootstrap failed:', err);
  process.exit(1);
});

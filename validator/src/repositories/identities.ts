/**
 * Identities repository.
 *
 * Each row links an external auth provider (Apple, password, Google,
 * GitHub) to a LiftMark user. A user may have multiple identities — the
 * `link` flow attaches additional providers to an existing account.
 *
 * Lookups during sign-in go through the `provider-lookup-index` GSI,
 * keyed by a composite `provider#provider_sub` string that we populate
 * automatically on write. For password identities, callers should use
 * the lowercased email as the provider_sub.
 *
 * createIdentity intentionally does NOT enforce the (provider,
 * provider_sub) uniqueness constraint at the DDB level — DynamoDB
 * doesn't support unique secondary keys. Callers are expected to first
 * call getIdentityByProviderSub and branch accordingly.
 */
import { randomUUID } from 'node:crypto';
import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand,
} from '@aws-sdk/lib-dynamodb';
import { ddb, tableName } from '../infra/ddb.js';

export type Provider = 'apple' | 'password' | 'google' | 'github';

export interface Identity {
  identity_id: string;
  user_id: string;
  provider: Provider;
  provider_sub: string;
  /** Composite key for the provider-lookup GSI — populated automatically. */
  provider_lookup: string;
  email: string;
  email_verified: boolean;
  password_hash?: string;
  password_updated_at?: string;
  created_at: string;
}

export type CreateIdentityInput = Omit<
  Identity,
  'identity_id' | 'created_at' | 'provider_lookup'
>;

export function providerLookupKey(
  provider: Provider,
  provider_sub: string,
): string {
  return `${provider}#${provider_sub}`;
}

export async function createIdentity(
  input: CreateIdentityInput,
): Promise<Identity> {
  const identity: Identity = {
    ...input,
    identity_id: randomUUID(),
    provider_lookup: providerLookupKey(input.provider, input.provider_sub),
    created_at: new Date().toISOString(),
  };

  await ddb.send(
    new PutCommand({
      TableName: tableName('identities'),
      Item: identity,
      ConditionExpression: 'attribute_not_exists(identity_id)',
    }),
  );

  return identity;
}

export async function getIdentityById(
  identity_id: string,
): Promise<Identity | null> {
  const result = await ddb.send(
    new GetCommand({
      TableName: tableName('identities'),
      Key: { identity_id },
    }),
  );
  return (result.Item as Identity | undefined) ?? null;
}

export async function getIdentityByProviderSub(
  provider: Provider,
  provider_sub: string,
): Promise<Identity | null> {
  const result = await ddb.send(
    new QueryCommand({
      TableName: tableName('identities'),
      IndexName: 'provider-lookup-index',
      KeyConditionExpression: 'provider_lookup = :pl',
      ExpressionAttributeValues: {
        ':pl': providerLookupKey(provider, provider_sub),
      },
      Limit: 1,
    }),
  );
  const item = result.Items?.[0];
  return (item as Identity | undefined) ?? null;
}

export async function listIdentitiesByUserId(
  user_id: string,
): Promise<Identity[]> {
  const result = await ddb.send(
    new QueryCommand({
      TableName: tableName('identities'),
      IndexName: 'user_id-index',
      KeyConditionExpression: 'user_id = :uid',
      ExpressionAttributeValues: { ':uid': user_id },
    }),
  );
  return (result.Items as Identity[] | undefined) ?? [];
}

export async function updatePasswordHash(
  identity_id: string,
  password_hash: string,
): Promise<void> {
  await ddb.send(
    new UpdateCommand({
      TableName: tableName('identities'),
      Key: { identity_id },
      UpdateExpression:
        'SET password_hash = :h, password_updated_at = :now',
      ExpressionAttributeValues: {
        ':h': password_hash,
        ':now': new Date().toISOString(),
      },
      ConditionExpression: 'attribute_exists(identity_id)',
    }),
  );
}

export async function markEmailVerified(identity_id: string): Promise<void> {
  await ddb.send(
    new UpdateCommand({
      TableName: tableName('identities'),
      Key: { identity_id },
      UpdateExpression: 'SET email_verified = :t',
      ExpressionAttributeValues: { ':t': true },
      ConditionExpression: 'attribute_exists(identity_id)',
    }),
  );
}

export async function deleteIdentity(identity_id: string): Promise<void> {
  await ddb.send(
    new DeleteCommand({
      TableName: tableName('identities'),
      Key: { identity_id },
      ConditionExpression: 'attribute_exists(identity_id)',
    }),
  );
}

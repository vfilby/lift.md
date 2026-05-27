/**
 * Users repository.
 *
 * Owns CRUD for the `users` table. A user row is the canonical identity
 * record — auth providers (Apple, password, etc.) live in `identities`
 * and point back here via `user_id`.
 *
 * On create:
 *   - user_id is a fresh UUID
 *   - created_at is now (ISO 8601)
 *   - trial_ends_at is created_at + 30 days
 *   - tier defaults to 'trial'
 *   - primary_email is lowercased
 *
 * Errors from DynamoDB propagate; the route layer is expected to map
 * ConditionalCheckFailedException to a 409/conflict response if needed.
 */
import { randomUUID } from 'node:crypto';
import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  UpdateCommand,
} from '@aws-sdk/lib-dynamodb';
import { ddb, tableName } from '../infra/ddb.js';

export type UserTier = 'pro' | 'trial' | 'free';

export interface User {
  user_id: string;
  display_name: string;
  primary_email: string;
  created_at: string;
  trial_ends_at: string;
  tier: UserTier;
  signup_ip?: string;
  signup_user_agent?: string;
}

export interface CreateUserInput {
  display_name: string;
  primary_email: string;
  signup_ip?: string;
  signup_user_agent?: string;
}

const TRIAL_DAYS = 30;
const MS_PER_DAY = 24 * 60 * 60 * 1000;

export async function createUser(input: CreateUserInput): Promise<User> {
  const now = new Date();
  const trialEnds = new Date(now.getTime() + TRIAL_DAYS * MS_PER_DAY);

  const user: User = {
    user_id: randomUUID(),
    display_name: input.display_name,
    primary_email: input.primary_email.toLowerCase(),
    created_at: now.toISOString(),
    trial_ends_at: trialEnds.toISOString(),
    tier: 'trial',
    signup_ip: input.signup_ip,
    signup_user_agent: input.signup_user_agent,
  };

  await ddb.send(
    new PutCommand({
      TableName: tableName('users'),
      Item: user,
      ConditionExpression: 'attribute_not_exists(user_id)',
    }),
  );

  return user;
}

export async function getUserById(user_id: string): Promise<User | null> {
  const result = await ddb.send(
    new GetCommand({
      TableName: tableName('users'),
      Key: { user_id },
    }),
  );
  return (result.Item as User | undefined) ?? null;
}

export async function updateUserTier(
  user_id: string,
  tier: UserTier,
): Promise<void> {
  await ddb.send(
    new UpdateCommand({
      TableName: tableName('users'),
      Key: { user_id },
      UpdateExpression: 'SET #tier = :tier',
      ExpressionAttributeNames: { '#tier': 'tier' },
      ExpressionAttributeValues: { ':tier': tier },
      ConditionExpression: 'attribute_exists(user_id)',
    }),
  );
}

/// Hard-delete a user row. Used for rolling back a partial signup when a
/// downstream step (e.g. sending the verification email) fails after the
/// user + identity rows already exist. The signup route is the only
/// expected caller — general-purpose user deletion is not a supported
/// operation in v1.
export async function deleteUser(user_id: string): Promise<void> {
  await ddb.send(
    new DeleteCommand({
      TableName: tableName('users'),
      Key: { user_id },
    }),
  );
}

/**
 * Entitlements repository — READ ONLY for now.
 *
 * The `entitlements` table (PK user_id) is provisioned for the billing
 * phase of docs/LLM_PLAN_EDITING_AND_TIERS.md; nothing writes it yet except
 * operators via the console. The AI plan-edit route reads one optional
 * field, `ai_daily_limit`, to override the env-wide daily quota for a
 * specific user (see spec/services/ai-plan-editing.md → Quota). Any other
 * attributes on the row are passed through untouched.
 */
import { GetCommand } from '@aws-sdk/lib-dynamodb';
import { ddb, tableName } from '../infra/ddb.js';

export interface Entitlement {
  user_id: string;
  /** Per-user AI plan-edit daily limit; overrides AI_DAILY_LIMIT when set. */
  ai_daily_limit?: number;
  [key: string]: unknown;
}

export async function getEntitlement(
  user_id: string,
): Promise<Entitlement | null> {
  const result = await ddb.send(
    new GetCommand({
      TableName: tableName('entitlements'),
      Key: { user_id },
    }),
  );
  return (result.Item as Entitlement | undefined) ?? null;
}

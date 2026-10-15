import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '../integrations/supabase/types.ts';
import { assertBudgetAdmin } from '../budget/data.ts';
import { lineageSchema, overviewSchema, priceOverviewSchema } from './command-center.ts';

// Each RPC enforces owner/admin membership itself; the membership check here only turns
// a refusal into a clear message before any aggregation runs.
function rpcError(error: { code?: string; message: string }, fallback: string): Error {
  if (error.code === '42501') return new Error('Forbidden: owner or admin access required');
  if (error.code === 'P0002') return new Error('This budget no longer exists. Refresh and try again.');
  return new Error(fallback);
}

export async function getCommandCenterOverview(db: SupabaseClient<Database>, userId: string, organizationId: string) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc('get_budget_purchasing_overview', { _organization_id: organizationId });
  if (error) throw rpcError(error, 'Unable to load budget and purchasing data');
  return overviewSchema.parse(data);
}

export async function getBudgetLineage(db: SupabaseClient<Database>, userId: string, organizationId: string, budgetId: string) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc('get_budget_lineage', { _organization_id: organizationId, _budget_id: budgetId });
  if (error) throw rpcError(error, 'Unable to load budget detail');
  return lineageSchema.parse(data);
}

export async function getPriceIntelligenceOverview(db: SupabaseClient<Database>, userId: string, organizationId: string) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc('get_price_intelligence_overview', { _organization_id: organizationId });
  if (error) throw rpcError(error, 'Unable to load price intelligence');
  return priceOverviewSchema.parse(data);
}

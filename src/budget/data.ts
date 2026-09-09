import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '../integrations/supabase/types.ts';
import { canAccessBudget, budgetInputSchema } from './budget.ts';

export async function assertBudgetAdmin(db: SupabaseClient<Database>, userId: string, organizationId: string) {
  const { data, error } = await db.from('organization_memberships').select('role')
    .eq('organization_id', organizationId).eq('user_id', userId).eq('active', true).maybeSingle();
  if (error) throw new Error(error.message);
  if (!canAccessBudget(data?.role)) throw new Error('Forbidden: owner or admin access required');
}
export async function listBudgets(db: SupabaseClient<Database>, userId: string, organizationId: string) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.from('organization_budgets').select('id, name, amount, period_start, period_end, active').eq('organization_id', organizationId).eq('active', true).order('period_start', { ascending: false }).order('id');
  if (error) throw new Error(error.message);
  return data ?? [];
}
export async function getBudgetSummary(db: SupabaseClient<Database>, userId: string, organizationId: string, budgetId: string) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc('get_budget_summary', { _organization_id: organizationId, _budget_id: budgetId });
  if (error) throw new Error(error.message);
  if (!data?.[0]) throw new Error('Budget summary is unavailable. Refresh and try again.');
  return data[0];
}
export async function saveBudget(db: SupabaseClient<Database>, userId: string, input: unknown) {
  const { organizationId, id, ...fields } = budgetInputSchema.parse(input);
  await assertBudgetAdmin(db, userId, organizationId);
  const query = id
    ? db.from('organization_budgets').update(fields).eq('organization_id', organizationId).eq('id', id).eq('active', true)
    : db.from('organization_budgets').insert({ ...fields, organization_id: organizationId, active: true });
  const { data, error } = await query.select('id').single();
  if (error) throw new Error(error.code === '23505' ? 'An active budget already exists for this exact period. Choose another period or edit that budget.' : error.message);
  return data;
}

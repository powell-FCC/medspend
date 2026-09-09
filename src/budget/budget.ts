import { z } from 'zod';

const date = z.string().refine((value) => /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value, 'Enter a valid date.');
export const budgetFieldsSchema = z.object({
  name: z.string().trim().min(1, 'Enter a budget name.').max(200, 'Use 200 characters or fewer.'),
  amount: z.number({ invalid_type_error: 'Enter a budget amount.' }).finite().nonnegative('Budget amount must be zero or greater.'),
  period_start: date,
  period_end: date,
});
export const budgetInputSchema = budgetFieldsSchema.extend({ organizationId: z.string().uuid(), id: z.string().uuid().optional() })
  .refine((value) => value.period_end >= value.period_start, { path: ['period_end'], message: 'Period end cannot precede period start.' });
export const budgetFormSchema = budgetFieldsSchema.extend({
  amount: z.string().trim().min(1, 'Enter a budget amount.').refine((v) => Number.isFinite(Number(v)) && Number(v) >= 0, 'Enter an amount of zero or greater.').transform(Number),
}).refine((value) => value.period_end >= value.period_start, { path: ['period_end'], message: 'Period end cannot precede period start.' });
export type BudgetInput = z.infer<typeof budgetInputSchema>;
export type Budget = z.infer<typeof budgetFieldsSchema> & { id: string; active: boolean };
export type BudgetSummary = { budget_id: string; budget_name: string; period_start: string; period_end: string; budget_amount: number; actual_spend: number; remaining_amount: number; posted_invoice_count: number };
export const canAccessBudget = (role: string | undefined) => role === 'owner' || role === 'admin';
export const formatUSD = (amount: number) => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(amount);
export const formatPeriod = (start: string, end: string) => {
  const formatter = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
  return `${formatter.format(new Date(start))} – ${formatter.format(new Date(end))}`;
};
export const localToday = () => {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
};
// Current periods first, then latest start, latest end, and ID for stable ties.
export function selectActiveBudget(budgets: Budget[], today: string) {
  return budgets.filter((b) => b.active).sort((a, b) => {
    const current = (v: Budget) => Number(v.period_start <= today && v.period_end >= today);
    return current(b) - current(a) || b.period_start.localeCompare(a.period_start) || b.period_end.localeCompare(a.period_end) || a.id.localeCompare(b.id);
  })[0] ?? null;
}

import { createServerFn } from '@tanstack/react-start';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import { budgetInputSchema } from '@/budget/budget';
import { listBudgets, getBudgetSummary, saveBudget } from '@/budget/data';

const organizationInput = z.object({ organizationId: z.string().uuid() });
export const listBudgetsFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => organizationInput.parse(value))
  .handler(({ data, context }) => listBudgets(context.supabase, context.userId, data.organizationId));
export const getBudgetSummaryFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => organizationInput.extend({ budgetId: z.string().uuid() }).parse(value))
  .handler(({ data, context }) => getBudgetSummary(context.supabase, context.userId, data.organizationId, data.budgetId));
export const saveBudgetFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => budgetInputSchema.parse(value))
  .handler(({ data, context }) => saveBudget(context.supabase, context.userId, data));

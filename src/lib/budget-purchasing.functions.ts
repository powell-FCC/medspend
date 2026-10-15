import { createServerFn } from '@tanstack/react-start';
import { z } from 'zod';
import { requireSupabaseAuth } from '@/integrations/supabase/auth-middleware';
import { getBudgetLineage, getCommandCenterOverview, getPriceIntelligenceOverview } from '@/budget-purchasing/data';

const organizationInput = z.object({ organizationId: z.string().uuid() });
export const getCommandCenterOverviewFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => organizationInput.parse(value))
  .handler(({ data, context }) => getCommandCenterOverview(context.supabase, context.userId, data.organizationId));
export const getBudgetLineageFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => organizationInput.extend({ budgetId: z.string().uuid() }).parse(value))
  .handler(({ data, context }) => getBudgetLineage(context.supabase, context.userId, data.organizationId, data.budgetId));
export const getPriceIntelligenceOverviewFn = createServerFn({ method: 'POST' }).middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => organizationInput.parse(value))
  .handler(({ data, context }) => getPriceIntelligenceOverview(context.supabase, context.userId, data.organizationId));

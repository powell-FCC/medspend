import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import {
  getDocumentDetail,
  getSpendSeries,
  getSpendSummary,
  listCommitments,
  listProductLines,
  listProductSpend,
  listRemovals,
  listSpendDocuments,
  listVendorSpend,
} from "@/budget-analytics/data";
import { commitmentBuckets, documentFilters, productSortValues } from "@/budget-analytics/spend";

const uuid = z.string().uuid();
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const org = z.object({ organizationId: uuid });
const range = org.extend({ from: day, to: day });

export const getSpendSummaryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    org.extend({ budgetId: uuid.nullable() }).strict().parse(value),
  )
  .handler(({ data, context }) =>
    getSpendSummary(context.supabase, context.userId, data.organizationId, data.budgetId),
  );

export const getSpendSeriesFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => range.strict().parse(value))
  .handler(({ data, context }) =>
    getSpendSeries(context.supabase, context.userId, data.organizationId, data.from, data.to),
  );

export const listVendorSpendFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => range.strict().parse(value))
  .handler(({ data, context }) =>
    listVendorSpend(context.supabase, context.userId, data.organizationId, data.from, data.to),
  );

export const listProductSpendFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    range
      .extend({
        sort: z.enum(productSortValues),
        limit: z.number().int().min(1).max(200),
        offset: z.number().int().min(0),
      })
      .strict()
      .parse(value),
  )
  .handler(({ data, context }) =>
    listProductSpend(context.supabase, context.userId, data.organizationId, data),
  );

export const listCommitmentsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    range
      .extend({
        bucket: z.enum(commitmentBuckets),
        limit: z.number().int().min(1).max(200),
        offset: z.number().int().min(0),
      })
      .strict()
      .parse(value),
  )
  .handler(({ data, context }) =>
    listCommitments(context.supabase, context.userId, data.organizationId, data),
  );

export const listSpendDocumentsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    range
      .extend({
        filter: z.enum(documentFilters),
        value: z.string().max(64).nullable(),
        limit: z.number().int().min(1).max(200),
        cursor: z.object({ spendDate: day, invoiceId: uuid }).strict().nullable(),
      })
      .strict()
      .parse(value),
  )
  .handler(({ data, context }) =>
    listSpendDocuments(context.supabase, context.userId, data.organizationId, data),
  );

export const getDocumentDetailFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => org.extend({ invoiceId: uuid }).strict().parse(value))
  .handler(({ data, context }) =>
    getDocumentDetail(context.supabase, context.userId, data.organizationId, data.invoiceId),
  );

export const listRemovalsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => org.strict().parse(value))
  .handler(({ data, context }) =>
    listRemovals(context.supabase, context.userId, data.organizationId),
  );

export const listProductLinesFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    range.extend({ productId: uuid.nullable() }).strict().parse(value),
  )
  .handler(({ data, context }) =>
    listProductLines(context.supabase, context.userId, data.organizationId, data),
  );

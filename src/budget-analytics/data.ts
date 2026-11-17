import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../integrations/supabase/types.ts";
import { assertBudgetAdmin } from "../budget/data.ts";
import {
  commitmentListSchema,
  documentDetailSchema,
  documentListSchema,
  productLinesSchema,
  productSpendSchema,
  removalListSchema,
  spendSeriesSchema,
  spendSummarySchema,
  vendorSpendSchema,
  type CommitmentBucket,
  type DocumentFilter,
  type ProductSort,
} from "./spend.ts";

type Db = SupabaseClient<Database>;

// Every RPC checks access itself (owner + admin, or owner only for document-level detail);
// the membership check here only turns a refusal into a clear message first.
function rpcError(error: { code?: string; message: string }, fallback: string): Error {
  if (error.code === "42501")
    return new Error(
      /owner access/i.test(error.message)
        ? "Invoice-level detail is available to organization owners."
        : "Forbidden: owner or admin access required",
    );
  if (error.code === "P0002")
    return new Error("This record no longer exists. Refresh and try again.");
  if (error.code === "22023" || error.code === "22004") return new Error(error.message);
  return new Error(fallback);
}

export async function getSpendSummary(
  db: Db,
  userId: string,
  organizationId: string,
  budgetId: string | null,
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("get_financial_spend_summary", {
    _organization_id: organizationId,
    _budget_id: budgetId,
  });
  if (error) throw rpcError(error, "Unable to load spend");
  return spendSummarySchema.parse(data);
}

export async function getSpendSeries(
  db: Db,
  userId: string,
  organizationId: string,
  from: string,
  to: string,
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("get_financial_spend_series", {
    _organization_id: organizationId,
    _from: from,
    _to: to,
  });
  if (error) throw rpcError(error, "Unable to load spend over time");
  return spendSeriesSchema.parse(data);
}

export async function listVendorSpend(
  db: Db,
  userId: string,
  organizationId: string,
  from: string,
  to: string,
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("list_financial_vendor_spend", {
    _organization_id: organizationId,
    _from: from,
    _to: to,
    _limit: 100,
    _offset: 0,
  });
  if (error) throw rpcError(error, "Unable to load vendor spend");
  return vendorSpendSchema.parse(data);
}

export async function listProductSpend(
  db: Db,
  userId: string,
  organizationId: string,
  input: { from: string; to: string; sort: ProductSort; limit: number; offset: number },
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("list_financial_product_spend", {
    _organization_id: organizationId,
    _from: input.from,
    _to: input.to,
    _sort: input.sort,
    _limit: input.limit,
    _offset: input.offset,
  });
  if (error) throw rpcError(error, "Unable to load product spend");
  return productSpendSchema.parse(data);
}

export async function listCommitments(
  db: Db,
  userId: string,
  organizationId: string,
  input: { from: string; to: string; bucket: CommitmentBucket; limit: number; offset: number },
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("list_financial_commitments", {
    _organization_id: organizationId,
    _from: input.from,
    _to: input.to,
    _bucket: input.bucket,
    _limit: input.limit,
    _offset: input.offset,
  });
  if (error) throw rpcError(error, "Unable to load commitments");
  return commitmentListSchema.parse(data);
}

export async function listSpendDocuments(
  db: Db,
  userId: string,
  organizationId: string,
  input: {
    from: string;
    to: string;
    filter: DocumentFilter;
    value: string | null;
    limit: number;
    cursor: { spendDate: string; invoiceId: string } | null;
  },
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("list_financial_spend_documents", {
    _organization_id: organizationId,
    _from: input.from,
    _to: input.to,
    _filter: input.filter,
    _value: input.value,
    _limit: input.limit,
    _cursor_spend_date: input.cursor?.spendDate ?? null,
    _cursor_invoice_id: input.cursor?.invoiceId ?? null,
  });
  if (error) throw rpcError(error, "Unable to load documents");
  return documentListSchema.parse(data);
}

export async function getDocumentDetail(
  db: Db,
  userId: string,
  organizationId: string,
  invoiceId: string,
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("get_financial_document_detail", {
    _organization_id: organizationId,
    _invoice_id: invoiceId,
  });
  if (error) throw rpcError(error, "Unable to load the document");
  return documentDetailSchema.parse(data);
}

export async function listRemovals(db: Db, userId: string, organizationId: string) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("list_financial_document_removals", {
    _organization_id: organizationId,
    _limit: 50,
  });
  if (error) throw rpcError(error, "Unable to load removed documents");
  return removalListSchema.parse(data);
}

export async function listProductLines(
  db: Db,
  userId: string,
  organizationId: string,
  input: { productId: string | null; from: string; to: string },
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("list_financial_product_lines", {
    _organization_id: organizationId,
    _product_id: input.productId,
    _from: input.from,
    _to: input.to,
    _limit: 200,
  });
  if (error) throw rpcError(error, "Unable to load product lines");
  return productLinesSchema.parse(data);
}

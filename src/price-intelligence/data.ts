// Phase 6B.1 data layer. Every RPC checks owner/admin membership itself; the membership check
// here only turns a refusal into a clear message before any query runs. Nothing here writes.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, Json } from "../integrations/supabase/types.ts";
import { assertBudgetAdmin } from "../budget/data.ts";
import {
  detailSchema,
  listSchema,
  requestContextSchema,
  summarySchema,
  type PriceFilter,
  type PriceListCursor,
  type PriceSort,
} from "./vendor-intelligence.ts";

type Db = SupabaseClient<Database>;

function rpcError(error: { code?: string; message: string }, notFound: string, fallback: string) {
  if (error.code === "42501") return new Error("Forbidden: owner or admin access required");
  if (error.code === "P0002") return new Error(notFound);
  return new Error(fallback);
}

export async function listPriceIntelligenceProducts(
  db: Db,
  userId: string,
  organizationId: string,
  options: {
    sort: PriceSort;
    filter: PriceFilter;
    vendorId: string | null;
    cursor: PriceListCursor;
    limit?: number;
  },
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("list_price_intelligence_products", {
    _organization_id: organizationId,
    _sort: options.sort,
    _filter: options.filter,
    _vendor_id: options.vendorId,
    _cursor: options.cursor as Json | null,
    _limit: options.limit ?? 50,
  });
  if (error)
    throw rpcError(
      error,
      "Price intelligence is unavailable.",
      "Unable to load price intelligence",
    );
  return listSchema.parse(data);
}

export async function getPriceIntelligenceSummary(db: Db, userId: string, organizationId: string) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("get_price_intelligence_summary", {
    _organization_id: organizationId,
  });
  if (error)
    throw rpcError(
      error,
      "Price intelligence is unavailable.",
      "Unable to load price intelligence",
    );
  return summarySchema.parse(data);
}

export async function getProductVendorHistory(
  db: Db,
  userId: string,
  organizationId: string,
  target: { productId: string } | { inventoryItemId: string },
  cursor: { purchaseDate: string; createdAt: string; observationId: string } | null = null,
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("get_product_vendor_price_history", {
    _organization_id: organizationId,
    _product_id: "productId" in target ? target.productId : null,
    _inventory_item_id: "inventoryItemId" in target ? target.inventoryItemId : null,
    _cursor: cursor as Json | null,
    _limit: 50,
  });
  if (error)
    throw rpcError(
      error,
      "This product has no purchase history in this organization.",
      "Unable to load purchase history",
    );
  return detailSchema.parse(data);
}

export async function getSupplyRequestPriceContext(
  db: Db,
  userId: string,
  organizationId: string,
  requestId: string,
) {
  await assertBudgetAdmin(db, userId, organizationId);
  const { data, error } = await db.rpc("get_supply_request_price_context", {
    _organization_id: organizationId,
    _request_id: requestId,
  });
  if (error)
    throw rpcError(error, "This request no longer exists.", "Unable to load purchase history");
  return requestContextSchema.parse(data);
}

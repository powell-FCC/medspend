import { createServerFn } from "@tanstack/react-start";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { loadRequestItems, requireMembership } from "@/lib/supply-requests.functions";
import {
  QUICK_PICK_EXCLUDED_STATUSES,
  QUICK_PICK_HISTORY_REQUESTS,
  buildQuickPicks,
  buildRequestAgainLines,
  type AvailabilityLookups,
  type CatalogAvailabilityRow,
  type InventoryAvailabilityRow,
  type ProductAvailabilityRow,
  type RequestHistoryLine,
  type RequestLineIdentity,
} from "@/supply-requests/staff-workspace";

// Staff Workspace v2 read paths. Both are requester-owned, organization-scoped and
// read-only: they never insert, update or submit. A request built from them is created
// only through submitSupplyRequestFn -> submit_supply_request.

// The caller's RLS-scoped client, read without the generated table types: these reads
// span several tables whose rows are narrowed to explicit shapes below.
type Db = SupabaseClient;

function uniqueIds(values: Array<string | null | undefined>) {
  return Array.from(new Set(values.filter((value): value is string => !!value)));
}

// One bounded query per identity table, under the caller's row-level security. Staff
// see only their organization's products and active inventory; the global catalog is
// readable to every authenticated user, as search already exposes it.
async function loadAvailabilityLookups(
  db: Db,
  organizationId: string,
  identities: RequestLineIdentity[],
): Promise<AvailabilityLookups> {
  const productIds = uniqueIds(identities.map((identity) => identity.productId));
  const inventoryIds = uniqueIds(identities.map((identity) => identity.inventoryItemId));
  const catalogIds = uniqueIds(identities.map((identity) => identity.catalogVendorProductId));
  const empty = Promise.resolve({ data: [], error: null });
  const [products, inventory, catalog, specifications] = await Promise.all([
    productIds.length
      ? db
          .from("products")
          .select("id,name,unit_of_measure,manufacturer,pack_size,active,staff_requestable")
          .eq("organization_id", organizationId)
          .in("id", productIds)
      : empty,
    inventoryIds.length
      ? db
          .from("inventory_items")
          .select("id,name,unit,manufacturer,vendor_name,sku")
          .eq("organization_id", organizationId)
          .eq("active", true)
          .in("id", inventoryIds)
      : empty,
    catalogIds.length
      ? db
          .from("catalog_vendor_products")
          .select(
            "id,active,discontinued,vendor_sku,package_status,package_quantity,package_unit,package_description,product:catalog_products!catalog_vendor_products_catalog_product_id_fkey(name,manufacturer,active),vendor:catalog_vendors!catalog_vendor_products_catalog_vendor_id_fkey(name,active)",
          )
          .in("id", catalogIds)
      : empty,
    catalogIds.length
      ? db.rpc("get_supply_request_product_specifications", {
          _organization_id: organizationId,
          _catalog_vendor_product_ids: catalogIds,
        })
      : empty,
  ]);
  for (const result of [products, inventory, catalog, specifications]) {
    if (result.error) throw new Error(result.error.message);
  }
  return {
    products: new Map(
      ((products.data ?? []) as ProductAvailabilityRow[]).map((row) => [row.id, row]),
    ),
    inventory: new Map(
      ((inventory.data ?? []) as InventoryAvailabilityRow[]).map((row) => [row.id, row]),
    ),
    catalog: new Map(
      ((catalog.data ?? []) as CatalogAvailabilityRow[]).map((row) => [row.id, row]),
    ),
    specifications: new Map(
      (
        (specifications.data ?? []) as Array<{
          catalog_vendor_product_id: string;
          specification: string;
        }>
      ).map((row) => [row.catalog_vendor_product_id, row.specification]),
    ),
  };
}

export const getStaffQuickPicksFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    await requireMembership(context, data.organizationId);
    const db = context.supabase as unknown as Db;
    // The requester's own recent requests only. Declined and cancelled requests are not
    // suggested.
    const { data: requests, error } = await db
      .from("supply_requests")
      .select("id,created_at")
      .eq("organization_id", data.organizationId)
      .eq("requested_by", context.userId)
      .not("status", "in", `(${QUICK_PICK_EXCLUDED_STATUSES.join(",")})`)
      .order("created_at", { ascending: false })
      .limit(QUICK_PICK_HISTORY_REQUESTS);
    if (error) throw new Error(error.message);
    const requestedAt = new Map<string, string>(
      ((requests ?? []) as Array<{ id: string; created_at: string }>).map((row) => [
        row.id,
        row.created_at,
      ]),
    );
    if (requestedAt.size === 0) return { frequent: [], recent: [] };

    const { data: rows, error: itemsError } = await db
      .from("supply_request_items")
      .select(
        "supply_request_id,product_id,inventory_item_id,vendor_product_id,catalog_vendor_product_id,free_text_item,quantity,unit",
      )
      .eq("organization_id", data.organizationId)
      .in("supply_request_id", [...requestedAt.keys()])
      .is("free_text_item", null);
    if (itemsError) throw new Error(itemsError.message);
    const lines: RequestHistoryLine[] = (
      (rows ?? []) as Array<{
        supply_request_id: string;
        product_id: string | null;
        inventory_item_id: string | null;
        vendor_product_id: string | null;
        catalog_vendor_product_id: string | null;
        free_text_item: string | null;
        quantity: number;
        unit: string | null;
      }>
    ).map((row) => ({
      requestId: row.supply_request_id,
      requestedAt: requestedAt.get(row.supply_request_id) ?? "",
      productId: row.product_id,
      inventoryItemId: row.inventory_item_id,
      vendorProductId: row.vendor_product_id,
      catalogVendorProductId: row.catalog_vendor_product_id,
      freeTextItem: row.free_text_item,
      quantity: row.quantity,
      unit: row.unit,
    }));
    const lookups = await loadAvailabilityLookups(db, data.organizationId, lines);
    return buildQuickPicks(lines, lookups);
  });

// "Request again": copy a prior request's lines for a NEW cart. The historical request
// is only read; nothing is submitted here.
export const getStaffRequestAgainFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: z.string().uuid(), requestId: z.string().uuid() }).parse(d),
  )
  .handler(async ({ data, context }) => {
    await requireMembership(context, data.organizationId);
    const db = context.supabase as unknown as Db;
    const { data: row, error } = await db
      .from("supply_requests")
      .select("id,product_id,quantity,free_text_item,created_at,products(name,unit_of_measure)")
      .eq("id", data.requestId)
      .eq("organization_id", data.organizationId)
      .eq("requested_by", context.userId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    if (!row) throw new Error("Request not found");
    const items = (await loadRequestItems(db, data.organizationId, [row])).get(row.id) ?? [];
    const lookups = await loadAvailabilityLookups(db, data.organizationId, items);
    return {
      requestId: row.id as string,
      submittedAt: row.created_at as string,
      lines: buildRequestAgainLines(items, lookups),
    };
  });

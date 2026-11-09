// Phase 5A.10 discovery reads and Saved Items writes against the narrow RPCs, shared by the
// server functions (src/lib/product-discovery.functions.ts) and the real-JWT integration
// test. Every call runs as the signed-in user; the RPCs check active membership themselves
// and nothing here reads a table directly.
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import {
  buildDiscoverySections,
  type StaffDiscoveryProduct,
  type StaffDiscoverySection,
  type StaffDiscoverySections,
} from "./product-discovery.ts";

// The caller's client, read without the generated function types: rows are parsed below.
type Db = SupabaseClient;

const identitySource = z.enum([
  "inventory",
  "organization_catalog",
  "organization_product",
  "global_catalog",
]);

const productRow = {
  result_key: z.string().min(1),
  identity_source: identitySource,
  product_name: z.string().min(1),
  manufacturer: z.string().nullable(),
  vendor_name: z.string().nullable(),
  vendor_sku: z.string().nullable(),
  package_display: z.string(),
  package_status: z.enum(["verified", "source_only", "unknown"]),
  inventory_item_id: z.string().uuid().nullable(),
  product_id: z.string().uuid().nullable(),
  vendor_product_id: z.string().uuid().nullable(),
  catalog_vendor_product_id: z.string().uuid().nullable(),
  variant_detail: z.string().nullable(),
  unit: z.string().nullable(),
  pack_size: z.string().nullable(),
  is_saved: z.boolean(),
  approved_request_count: z.number().int().nonnegative(),
  last_approved_at: z.string().nullable(),
  purchase_count: z.number().int().nonnegative(),
  last_purchased_at: z.string().nullable(),
};

const searchRowSchema = z.object({ ...productRow, match_tier: z.number().int() }).strict();
const discoveryRowSchema = z
  .object({
    ...productRow,
    section: z.enum(["saved", "frequent", "purchased"]),
    section_rank: z.number().int().positive(),
  })
  .strict();

const specificationRowSchema = z
  .object({ catalog_vendor_product_id: z.string().uuid(), specification: z.string().min(1) })
  .strict();

type ProductRow = z.infer<z.ZodObject<typeof productRow>>;

function toProduct(
  row: ProductRow,
  specifications: ReadonlyMap<string, string>,
  matchTier: number | null,
): StaffDiscoveryProduct {
  return {
    resultId: row.result_key,
    identitySource: row.identity_source,
    productName: row.product_name,
    manufacturer: row.manufacturer,
    vendorName: row.vendor_name,
    vendorSku: row.vendor_sku,
    packageDisplay: row.package_display,
    packageStatus: row.package_status,
    specification: row.catalog_vendor_product_id
      ? (specifications.get(row.catalog_vendor_product_id) ?? null)
      : null,
    variantDetail: row.variant_detail,
    unit: row.unit,
    packSize: row.pack_size,
    inventoryItemId: row.inventory_item_id,
    productId: row.product_id,
    vendorProductId: row.vendor_product_id,
    catalogVendorProductId: row.catalog_vendor_product_id,
    isSaved: row.is_saved,
    approvedRequestCount: row.approved_request_count,
    lastApprovedAt: row.last_approved_at,
    purchaseCount: row.purchase_count,
    lastPurchasedAt: row.last_purchased_at,
    matchTier,
  };
}

// Trusted size/color specifications (Phase 5A.8B), for at most 50 catalog products.
async function loadSpecifications(db: Db, organizationId: string, rows: ProductRow[]) {
  const ids = [
    ...new Set(
      rows.flatMap((row) => (row.catalog_vendor_product_id ? [row.catalog_vendor_product_id] : [])),
    ),
  ].slice(0, 50);
  const specifications = new Map<string, string>();
  if (ids.length === 0) return specifications;
  const { data, error } = await db.rpc("get_supply_request_product_specifications", {
    _organization_id: organizationId,
    _catalog_vendor_product_ids: ids,
  });
  if (error) throw new Error(error.message);
  for (const row of specificationRowSchema.array().parse(data ?? [])) {
    specifications.set(row.catalog_vendor_product_id, row.specification);
  }
  return specifications;
}

export async function searchStaffProducts(
  db: Db,
  organizationId: string,
  query: string,
  limit = 20,
): Promise<StaffDiscoveryProduct[]> {
  const { data: rows, error } = await db.rpc("search_supply_request_products_with_signals", {
    _organization_id: organizationId,
    _query: query,
    _limit: limit,
  });
  if (error) throw new Error(error.message);
  const parsed = searchRowSchema.array().parse(rows ?? []);
  const specifications = await loadSpecifications(db, organizationId, parsed);
  return parsed.map((row) => toProduct(row, specifications, row.match_tier));
}

export const STAFF_DISCOVERY_HISTORY_LIMIT = 6;

export async function getStaffProductDiscovery(
  db: Db,
  organizationId: string,
): Promise<StaffDiscoverySections> {
  const { data: rows, error } = await db.rpc("get_staff_product_discovery", {
    _organization_id: organizationId,
    _limit: STAFF_DISCOVERY_HISTORY_LIMIT,
  });
  if (error) throw new Error(error.message);
  const parsed = discoveryRowSchema.array().parse(rows ?? []);
  const specifications = await loadSpecifications(db, organizationId, parsed);
  return buildDiscoverySections(
    parsed.map((row) => ({
      ...toProduct(row, specifications, null),
      section: row.section as StaffDiscoverySection,
    })),
  );
}

export type StaffSavedIdentity = {
  productId: string | null;
  catalogVendorProductId: string | null;
  inventoryItemId: string | null;
};

// Save or remove one of the caller's own Saved Items. Idempotent either way.
export async function setStaffProductSaved(
  db: Db,
  organizationId: string,
  identity: StaffSavedIdentity,
  saved: boolean,
): Promise<{ resultId: string; saved: boolean }> {
  const { data: rows, error } = await db.rpc(
    saved ? "save_staff_product" : "remove_staff_saved_product",
    {
      _organization_id: organizationId,
      _product_id: identity.productId,
      _catalog_vendor_product_id: identity.catalogVendorProductId,
      _inventory_item_id: identity.inventoryItemId,
    },
  );
  if (error) throw new Error(error.message);
  const row = z
    .array(z.object({ identity_key: z.string(), saved: z.boolean() }).passthrough())
    .length(1)
    .parse(rows ?? [])[0]!;
  return { resultId: row.identity_key, saved: row.saved };
}

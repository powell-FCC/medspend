// Invoice review actions: what the invoice-processing server functions do once the caller
// is authenticated. Each createServerFn handler passes the request's Supabase client and
// user id straight to one of these. Kept free of framework and path-alias imports so the
// same code can be run by the integration tests against a local Postgres and PostgREST.
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { CanonicalInvoiceExtraction } from "../extraction/types.ts";
import type { Database, Json } from "../integrations/supabase/types.ts";
import type { InvoiceCatalogSearch, InvoiceMatchResult } from "../types/invoice-processing.ts";
import { toInvoiceCatalogSearch } from "./catalog-match.ts";
import {
  derivedTotalKeys,
  recalculateDerivedTotals,
  type DerivedTotalKey,
} from "./derived-totals.ts";

type Db = SupabaseClient<Database>;

const uuid = z.string().uuid();
const optionalText = z.string().trim().max(500).default("");
export const reviewKey = z.object({ sourceFileId: uuid, organizationId: uuid });
export const itemInput = reviewKey.extend({
  id: uuid.optional(),
  sku: z.string().trim().max(120).default(""),
  description: z.string().trim().min(1).max(500),
  manufacturer: optionalText,
  category: z.string().trim().max(120).default(""),
  quantity: z.number().positive(),
  unitOfMeasure: z.string().trim().min(1).max(100),
  unitPrice: z.number().nonnegative(),
  totalPrice: z.number().nonnegative(),
  packageSize: z.string().trim().max(120).default(""),
  vendorProductId: uuid.optional().nullable(),
});
export const itemKeyInput = reviewKey.extend({ id: uuid });
export const confirmMatchInput = reviewKey.extend({
  itemId: uuid,
  productId: uuid,
  // The product the reviewer saw on the line (null if unmatched). Required: a caller must
  // say what it is replacing, and the database refuses if the line has changed since.
  expectedProductId: uuid.nullable(),
  rememberVendorSku: z.boolean().default(true),
});
export const catalogSearchInput = reviewKey.extend({ query: z.string().max(200).default("") });
export const catalogMatchInput = reviewKey.extend({
  itemId: uuid,
  catalogVendorProductId: uuid,
  expectedProductId: uuid.nullable(),
});

export type InvoiceReviewErrorCode =
  | "forbidden"
  | "rejected"
  | "conflict"
  | "unavailable"
  | "failed";

/** An error whose message is written for the reviewer. Database text never reaches it raw. */
export class InvoiceReviewError extends Error {
  code: InvoiceReviewErrorCode;
  constructor(code: InvoiceReviewErrorCode, message: string) {
    super(message);
    this.name = "InvoiceReviewError";
    this.code = code;
  }
}

export const MAPPING_CONFLICT_MESSAGE =
  "This match conflicts with a product or vendor SKU mapping your organization already has. Choose the existing product, or resolve the conflict in Catalog first.";
export const INVENTORY_SKU_CONFLICT_MESSAGE =
  "A line's vendor SKU is already used by a different inventory item from this vendor, so this invoice cannot be posted as matched. Match that line to the product that already carries the SKU, or correct the SKU on the line.";
export const NOT_DEPLOYED_MESSAGE =
  "This action is not available on the server yet. Try again after the latest update has been applied.";

/**
 * Turns a database or PostgREST error into an error that is safe to show.
 *
 * P0001 is what our own database functions raise on purpose; those messages are already
 * written for the reviewer and pass through. Everything else (constraint and trigger
 * failures, missing functions, anything unexpected) is replaced with a fixed message, so
 * constraint names, identifiers, and SQL never reach the screen.
 */
export function toInvoiceReviewError(
  error: { code?: string | null; message?: string | null },
  fallback: string,
): InvoiceReviewError {
  const code = error.code ?? "";
  const message = error.message ?? "";
  if (code === "P0001" && message) {
    return new InvoiceReviewError(/^Forbidden\b/.test(message) ? "forbidden" : "rejected", message);
  }
  // The posting gate raises its reviewer-facing message with a not-null code.
  if (code === "23502" && message.startsWith("Match or create a product for every invoice line")) {
    return new InvoiceReviewError("rejected", message);
  }
  if (code === "42501")
    return new InvoiceReviewError("forbidden", "Forbidden: owner access required");
  if (code === "23505" && message.includes("inventory_items_org_vendor_sku_unique")) {
    return new InvoiceReviewError("conflict", INVENTORY_SKU_CONFLICT_MESSAGE);
  }
  if (code.startsWith("23")) return new InvoiceReviewError("conflict", MAPPING_CONFLICT_MESSAGE);
  if (code === "PGRST202" || code === "42883") {
    return new InvoiceReviewError("unavailable", NOT_DEPLOYED_MESSAGE);
  }
  return new InvoiceReviewError("failed", fallback);
}

export async function assertOwner(db: Db, userId: string, organizationId: string) {
  const { data, error } = await db
    .from("organization_memberships")
    .select("role")
    .eq("organization_id", organizationId)
    .eq("user_id", userId)
    .eq("active", true)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (data?.role !== "owner") {
    throw new InvoiceReviewError("forbidden", "Forbidden: owner access required");
  }
}

export async function requireDraftInvoice(db: Db, organizationId: string, sourceFileId: string) {
  const { data, error } = await db
    .from("invoices")
    .select("id,processing_status,posted_at")
    .eq("organization_id", organizationId)
    .eq("source_file_id", sourceFileId)
    .single();
  if (error) throw new Error(error.message);
  if (data.processing_status === "completed" || data.posted_at) {
    throw new Error("Completed invoices cannot be edited.");
  }
  return data;
}

export async function markExtractionReviewed(
  db: Db,
  organizationId: string,
  sourceFileId: string,
  target: { header: true } | { itemIndex: number },
) {
  const { data } = await db
    .from("invoice_processing_jobs")
    .select("extraction_result")
    .eq("invoice_id", sourceFileId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (!data?.extraction_result) return;
  const extraction = structuredClone(
    data.extraction_result,
  ) as unknown as CanonicalInvoiceExtraction;
  const fields =
    "header" in target
      ? Object.values(extraction.header)
      : Object.values(extraction.items[target.itemIndex] ?? {});
  for (const field of fields) field.reviewed = true;
  await db
    .from("invoice_processing_jobs")
    .update({ extraction_result: extraction as unknown as Json })
    .eq("invoice_id", sourceFileId)
    .eq("organization_id", organizationId);
}

/**
 * Brings an invoice's calculated subtotal and total up to date with its current lines, tax,
 * and shipping, using the same calculation as extraction (see recalculateDerivedTotals).
 * A calculated amount that can no longer be calculated safely is cleared. Printed and
 * owner-entered amounts are never written. Returns whether anything was written.
 *
 * ownerEntered is the subtotal and total an owner just saved on the header form.
 */
export async function refreshDerivedInvoiceTotals(
  db: Db,
  organizationId: string,
  sourceFileId: string,
  ownerEntered?: Partial<Record<DerivedTotalKey, number | null>>,
): Promise<boolean> {
  const { data: job, error: jobError } = await db
    .from("invoice_processing_jobs")
    .select("extraction_result")
    .eq("invoice_id", sourceFileId)
    .eq("organization_id", organizationId)
    .maybeSingle();
  if (jobError) throw new Error(jobError.message);
  const stored = (job?.extraction_result ?? null) as unknown as CanonicalInvoiceExtraction | null;
  if (!stored || !derivedTotalKeys(stored).length) return false;

  const { data: invoice, error: invoiceError } = await db
    .from("invoices")
    .select(
      "id,subtotal,tax_amount,shipping_amount,invoice_total,total_amount,processing_status,posted_at",
    )
    .eq("organization_id", organizationId)
    .eq("source_file_id", sourceFileId)
    .single();
  if (invoiceError) throw new Error(invoiceError.message);
  if (invoice.processing_status === "completed" || invoice.posted_at) return false;
  const { data: items, error: itemsError } = await db
    .from("invoice_items")
    .select("description,quantity,unit_price,total_price")
    .eq("organization_id", organizationId)
    .eq("invoice_id", invoice.id);
  if (itemsError) throw new Error(itemsError.message);

  const refresh = recalculateDerivedTotals(
    stored,
    {
      subtotal: invoice.subtotal,
      tax: invoice.tax_amount,
      shipping: invoice.shipping_amount,
      total: invoice.total_amount ?? invoice.invoice_total,
    },
    (items ?? []).map((item) => ({
      description: item.description,
      quantity: item.quantity,
      unitPrice: item.unit_price,
      totalPrice: item.total_price,
    })),
    ownerEntered,
  );
  if (!refresh.changed) return false;

  const amounts: Database["public"]["Tables"]["invoices"]["Update"] = {};
  if ("subtotal" in refresh.amounts) amounts.subtotal = refresh.amounts.subtotal ?? null;
  if ("total" in refresh.amounts) {
    amounts.invoice_total = refresh.amounts.total ?? null;
    amounts.total_amount = refresh.amounts.total ?? null;
    amounts.total = refresh.amounts.total ?? null;
  }
  if (Object.keys(amounts).length) {
    const { error } = await db
      .from("invoices")
      .update(amounts)
      .eq("id", invoice.id)
      .eq("organization_id", organizationId);
    if (error) throw new Error(error.message);
  }
  const { error: extractionError } = await db
    .from("invoice_processing_jobs")
    .update({ extraction_result: refresh.extraction as unknown as Json })
    .eq("invoice_id", sourceFileId)
    .eq("organization_id", organizationId);
  if (extractionError) throw new Error(extractionError.message);
  return true;
}

export async function saveInvoiceItem(db: Db, userId: string, data: z.infer<typeof itemInput>) {
  await assertOwner(db, userId, data.organizationId);
  const invoice = await requireDraftInvoice(db, data.organizationId, data.sourceFileId);
  const payload = {
    sku: data.sku || null,
    description: data.description,
    manufacturer: data.manufacturer || null,
    category: data.category || null,
    quantity: data.quantity,
    unit_of_measure: data.unitOfMeasure,
    unit_price: data.unitPrice,
    total_price: data.totalPrice,
    package_size: data.packageSize || null,
    vendor_product_id: data.vendorProductId ?? null,
    product_id: null as string | null,
    review_status: "pending_review",
  };
  if (data.vendorProductId) {
    const { data: mapping, error: mappingError } = await db
      .from("vendor_products")
      .select("product_id")
      .eq("id", data.vendorProductId)
      .eq("organization_id", data.organizationId)
      .eq("active", true)
      .single();
    if (mappingError) throw new Error(mappingError.message);
    payload.product_id = mapping.product_id;
  }
  if (data.id) {
    const { data: existing } = await db
      .from("invoice_items")
      .select(
        "line_number,sku,description,manufacturer,unit_of_measure,package_size,product_id,vendor_product_id",
      )
      .eq("id", data.id)
      .eq("invoice_id", invoice.id)
      .eq("organization_id", data.organizationId)
      .maybeSingle();
    if (!data.vendorProductId && existing?.product_id) {
      const identityUnchanged =
        (existing.sku ?? "") === data.sku &&
        existing.description === data.description &&
        (existing.manufacturer ?? "") === data.manufacturer &&
        (existing.unit_of_measure ?? "") === data.unitOfMeasure &&
        (existing.package_size ?? "") === data.packageSize;
      // Keep the existing link and its mapping so provenance (manual or automatic) is unchanged.
      if (identityUnchanged) {
        payload.product_id = existing.product_id;
        payload.vendor_product_id = existing.vendor_product_id;
      }
    }
    const { error } = await db
      .from("invoice_items")
      .update(payload)
      .eq("id", data.id)
      .eq("invoice_id", invoice.id)
      .eq("organization_id", data.organizationId);
    if (error) throw new Error(error.message);
    if (existing?.line_number) {
      await markExtractionReviewed(db, data.organizationId, data.sourceFileId, {
        itemIndex: existing.line_number - 1,
      });
    }
    await refreshDerivedInvoiceTotals(db, data.organizationId, data.sourceFileId);
    return { id: data.id };
  }
  const { count, error: countError } = await db
    .from("invoice_items")
    .select("id", { count: "exact", head: true })
    .eq("invoice_id", invoice.id);
  if (countError) throw new Error(countError.message);
  const { data: item, error } = await db
    .from("invoice_items")
    .insert({
      invoice_id: invoice.id,
      organization_id: data.organizationId,
      line_number: (count ?? 0) + 1,
      ...payload,
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);
  await refreshDerivedInvoiceTotals(db, data.organizationId, data.sourceFileId);
  return { id: item.id };
}

export async function deleteInvoiceItem(
  db: Db,
  userId: string,
  data: z.infer<typeof itemKeyInput>,
) {
  await assertOwner(db, userId, data.organizationId);
  const invoice = await requireDraftInvoice(db, data.organizationId, data.sourceFileId);
  const { error } = await db
    .from("invoice_items")
    .delete()
    .eq("id", data.id)
    .eq("invoice_id", invoice.id)
    .eq("organization_id", data.organizationId);
  if (error) throw new Error(error.message);
  await refreshDerivedInvoiceTotals(db, data.organizationId, data.sourceFileId);
  return { ok: true };
}

// Shapes a confirm/match RPC result. When the database kept a catalog-adopted mapping
// instead of remembering the SKU for the chosen product, say which one, so the reviewer
// knows this match applies to this invoice only.
async function toMatchResult(
  db: Db,
  organizationId: string,
  result: Json,
): Promise<InvoiceMatchResult> {
  if (!result || typeof result !== "object" || Array.isArray(result) || !result.productId) {
    throw new InvoiceReviewError("failed", "The product match returned an invalid result.");
  }
  let preservedMapping: InvoiceMatchResult["preservedMapping"] = null;
  if (result.preservedVendorProductId) {
    const { data: mapping } = await db
      .from("vendor_products")
      .select("vendor_sku,product_id")
      .eq("id", String(result.preservedVendorProductId))
      .eq("organization_id", organizationId)
      .maybeSingle();
    if (mapping) {
      const { data: product } = await db
        .from("products")
        .select("name")
        .eq("id", mapping.product_id)
        .eq("organization_id", organizationId)
        .maybeSingle();
      preservedMapping = { vendorSku: mapping.vendor_sku, productName: product?.name ?? "" };
    }
  }
  return {
    productId: String(result.productId),
    vendorProductId: result.vendorProductId ? String(result.vendorProductId) : null,
    vendorSkuRemembered: result.vendorSkuRemembered === true,
    preservedMapping,
  };
}

export async function confirmInvoiceItemProduct(
  db: Db,
  userId: string,
  data: z.infer<typeof confirmMatchInput>,
): Promise<InvoiceMatchResult> {
  await assertOwner(db, userId, data.organizationId);
  await requireDraftInvoice(db, data.organizationId, data.sourceFileId);
  const { data: result, error } = await db.rpc("confirm_invoice_item_product_expected", {
    _organization_id: data.organizationId,
    _source_file_id: data.sourceFileId,
    _invoice_item_id: data.itemId,
    _product_id: data.productId,
    _expected_product_id: data.expectedProductId,
    _remember_vendor_sku: data.rememberVendorSku,
  });
  if (error) throw toInvoiceReviewError(error, "Could not update the product match.");
  return toMatchResult(db, data.organizationId, result);
}

// Manual recovery beyond the organization's own products: the global catalog of the catalog
// vendor this invoice's vendor is explicitly linked to. The database derives that vendor
// from the invoice; the caller cannot ask for another vendor's catalog.
export async function searchInvoiceCatalog(
  db: Db,
  userId: string,
  data: z.infer<typeof catalogSearchInput>,
): Promise<InvoiceCatalogSearch> {
  await assertOwner(db, userId, data.organizationId);
  const { data: result, error } = await db.rpc("search_invoice_line_catalog_listings", {
    _organization_id: data.organizationId,
    _source_file_id: data.sourceFileId,
    _query: data.query,
  });
  if (error) throw toInvoiceReviewError(error, "Could not search the vendor catalog.");
  return toInvoiceCatalogSearch(result);
}

// One explicit owner decision: adopt the chosen catalog listing if needed and match the line,
// atomically in the database. expectedProductId is the match the reviewer was shown; the
// database refuses if the line has since been matched to something else.
export async function matchInvoiceItemToCatalog(
  db: Db,
  userId: string,
  data: z.infer<typeof catalogMatchInput>,
): Promise<InvoiceMatchResult> {
  await assertOwner(db, userId, data.organizationId);
  await requireDraftInvoice(db, data.organizationId, data.sourceFileId);
  const { data: result, error } = await db.rpc("match_invoice_item_to_catalog_listing", {
    _organization_id: data.organizationId,
    _source_file_id: data.sourceFileId,
    _invoice_item_id: data.itemId,
    _catalog_vendor_product_id: data.catalogVendorProductId,
    _expected_product_id: data.expectedProductId,
  });
  if (error) throw toInvoiceReviewError(error, "Could not match this line to the catalog item.");
  return toMatchResult(db, data.organizationId, result);
}

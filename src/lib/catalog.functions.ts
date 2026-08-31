/* eslint-disable @typescript-eslint/no-explicit-any -- Supabase query builders are dynamically typed in this module. */
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import {
  CATALOG_ADMIN_PAGE_SIZE,
  escapePostgresLike,
  isCatalogAdminRole,
  normalizeCatalogSku,
  normalizeCatalogText,
  type CatalogAdminDetail,
  type CatalogAdminResult,
  type CatalogAdminSearchInput,
  type CatalogAdoptionResult,
  type CatalogStockResult,
} from "@/catalog-admin/catalog-admin";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

const orgId = z.string().uuid();
const optionalText = z.string().max(5000).optional().nullable();

async function assertAdmin(db: any, userId: string, organizationId: string) {
  const { data, error } = await db
    .from("organization_memberships")
    .select("role")
    .eq("organization_id", organizationId)
    .eq("user_id", userId)
    .eq("active", true)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data || !isCatalogAdminRole(data.role)) throw new Error("Forbidden");
}

function normalize(value: string) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

async function likelyDuplicates(
  db: any,
  table: "vendors" | "products",
  organizationId: string,
  name: string,
  excludeId?: string,
) {
  const normalized = normalize(name);
  const token =
    normalized
      .split(" ")
      .filter(Boolean)
      .sort((a, b) => b.length - a.length)[0] ?? normalized;
  let q = db
    .from(table)
    .select("id, name, active")
    .eq("organization_id", organizationId)
    .ilike("normalized_name", `%${token}%`)
    .limit(5);
  if (excludeId) q = q.neq("id", excludeId);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return (data ?? []).filter((row: any) => normalize(row.name) === normalized || token.length >= 4);
}

export const listCatalogFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        organizationId: orgId,
        q: z.string().max(120).default(""),
        includeArchived: z.boolean().default(true),
      })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const term = data.q.trim();
    const { data: aliasMatches, error: aliasSearchError } = term
      ? await db
          .from("product_aliases")
          .select("product_id")
          .eq("organization_id", data.organizationId)
          .ilike("normalized_alias", `%${term}%`)
          .limit(50)
      : { data: [], error: null };
    if (aliasSearchError) throw new Error(aliasSearchError.message);
    const aliasProductIds = (aliasMatches ?? []).map((row: any) => row.product_id);
    const list = async (
      table: string,
      select: string,
      searchColumns: string[],
      extraSearch: string[] = [],
    ) => {
      let query = db
        .from(table)
        .select(select)
        .eq("organization_id", data.organizationId)
        .order("name");
      if (!data.includeArchived) query = query.eq("active", true);
      if (term)
        query = query.or(
          [
            ...searchColumns.map((c) => `${c}.ilike.%${term.replaceAll(",", "")}%`),
            ...extraSearch,
          ].join(","),
        );
      const { data: rows, error } = await query;
      if (error) throw new Error(error.message);
      return rows ?? [];
    };
    const [categories, vendors, products] = await Promise.all([
      list("product_categories", "id,name,parent_category_id,active,created_at", [
        "name",
        "normalized_name",
      ]),
      list(
        "vendors",
        "id,name,account_number,contact_name,email,phone,website,notes,active,created_at,updated_at",
        ["name", "normalized_name", "account_number", "contact_name", "email"],
      ),
      list(
        "products",
        "id,name,description,category_id,preferred_vendor_id,manufacturer,vendor_item_number,internal_item_code,unit_of_measure,pack_size,active,staff_requestable,created_at,updated_at,product_aliases!product_aliases_product_id_fkey(id,alias)",
        [
          "name",
          "normalized_name",
          "description",
          "manufacturer",
          "vendor_item_number",
          "internal_item_code",
        ],
        aliasProductIds.length ? [`id.in.(${aliasProductIds.join(",")})`] : [],
      ),
    ]);
    return { categories, vendors, products };
  });

const catalogLifecycle = z.enum(["active", "discontinued", "all"]);
const catalogPackageStatus = z.enum(["verified", "source_only", "unknown", "all"]);
const catalogAdoption = z.enum(["adopted", "not_adopted", "all"]);

const catalogAdminSearchInput = z.object({
  organizationId: orgId,
  q: z.string().trim().max(120).default(""),
  vendorId: z.string().uuid().nullable().default(null),
  lifecycle: catalogLifecycle.default("active"),
  packageStatus: catalogPackageStatus.default("all"),
  adoption: catalogAdoption.default("all"),
  page: z.number().int().min(1).max(400).default(1),
});

const catalogAdminDetailSchema = z
  .object({
    catalogVendorProductId: z.string().uuid(),
    product: z
      .object({
        id: z.string().uuid(),
        name: z.string(),
        manufacturer: z.string().nullable(),
        description: z.string().nullable(),
        active: z.boolean(),
        verificationStatus: z.string(),
      })
      .strict(),
    vendor: z
      .object({
        id: z.string().uuid(),
        name: z.string(),
        website: z.string().nullable(),
        active: z.boolean(),
        vendorSku: z.string(),
        normalizedVendorSku: z.string(),
        manufacturerSku: z.string().nullable(),
      })
      .strict(),
    package: z
      .object({
        rawDescription: z.string().nullable(),
        verifiedQuantity: z.number().positive().nullable(),
        verifiedUnit: z.string().nullable(),
        status: z.enum(["verified", "source_only", "unknown"]),
      })
      .strict(),
    lifecycle: z
      .object({
        active: z.boolean(),
        discontinued: z.boolean(),
        verificationStatus: z.string(),
      })
      .strict(),
    provenance: z.array(
      z
        .object({
          sourceName: z.string(),
          sourceVersion: z.string(),
          sourcePage: z.string().nullable(),
          rawVendorSku: z.string().nullable(),
          rawProductName: z.string().nullable(),
          rawVariant: z.string().nullable(),
          rawPackage: z.string().nullable(),
        })
        .strict(),
    ),
    verificationOverrides: z.array(
      z
        .object({
          overrideType: z.string(),
          evidenceStatus: z.string(),
          productionRule: z.string(),
          sourceVendorSku: z.string().nullable(),
          verifiedVendorSku: z.string().nullable(),
          effectiveFrom: z.string(),
          sourceName: z.string().nullable(),
          sourceVersion: z.string().nullable(),
        })
        .strict(),
    ),
  })
  .strict();

const catalogAdoptionResultSchema = z
  .object({
    organizationId: z.string().uuid(),
    catalogVendorProductId: z.string().uuid(),
    vendorId: z.string().uuid(),
    productId: z.string().uuid(),
    vendorProductId: z.string().uuid(),
    vendorCreated: z.boolean(),
    productCreated: z.boolean(),
    vendorProductCreated: z.boolean(),
    alreadyAdopted: z.boolean(),
  })
  .strict();

const catalogStockResultSchema = z
  .object({
    organizationId: z.string().uuid(),
    catalogVendorProductId: z.string().uuid(),
    vendorProductId: z.string().uuid(),
    productId: z.string().uuid(),
    inventoryItemId: z.string().uuid(),
    inventoryCreated: z.boolean(),
    alreadyStocked: z.boolean(),
    quantity: z.number().nonnegative(),
    parLevel: z.number().nonnegative().nullable(),
    unit: z.string().min(1).max(80),
    active: z.boolean(),
  })
  .strict();

type CatalogSearchBucket =
  | "all"
  | "normalized_sku_exact"
  | "raw_sku_exact"
  | "sku_prefix"
  | "product_name"
  | "manufacturer"
  | "description";

type CatalogSearchTerms = {
  raw: string;
  normalizedSku: string;
  normalizedText: string;
  skuPrefixPattern: string;
  namePattern: string;
  descriptionPattern: string;
};

function catalogSearchTerms(query: string): CatalogSearchTerms {
  const raw = query.trim();
  const normalizedSku = normalizeCatalogSku(raw);
  const normalizedText = normalizeCatalogText(raw);
  return {
    raw,
    normalizedSku,
    normalizedText,
    skuPrefixPattern: `${escapePostgresLike(normalizedSku)}%`,
    namePattern: `%${escapePostgresLike(normalizedText)}%`,
    descriptionPattern: `%${escapePostgresLike(raw)}%`,
  };
}

function catalogSearchBuckets(terms: CatalogSearchTerms): CatalogSearchBucket[] {
  if (!terms.raw) return ["all"];
  return [
    ...(terms.normalizedSku
      ? (["normalized_sku_exact", "raw_sku_exact", "sku_prefix"] as const)
      : []),
    ...(terms.normalizedText ? (["product_name", "manufacturer", "description"] as const) : []),
  ];
}

function catalogAdminSelect(adoptionInner: boolean): string {
  return `
    id,
    catalog_product_id,
    catalog_vendor_id,
    vendor_sku,
    normalized_vendor_sku,
    manufacturer_sku,
    package_description,
    package_quantity,
    package_unit,
    package_status,
    active,
    discontinued,
    verification_status,
    product:catalog_products!catalog_vendor_products_catalog_product_id_fkey!inner(
      id,
      name,
      normalized_name,
      description,
      manufacturer,
      normalized_manufacturer,
      active
    ),
    vendor:catalog_vendors!catalog_vendor_products_catalog_vendor_id_fkey(
      id,
      name
    ),
    orgAdoptions:vendor_products!vendor_products_catalog_vendor_product_fk${adoptionInner ? "!inner" : ""}(
      id,
      organization_id,
      vendor_id,
      product_id,
      organizationVendor:vendors!vendor_products_vendor_org_fk(id,catalog_vendor_id),
      organizationProduct:products!vendor_products_product_org_fk(id,catalog_product_id)
    )
  `;
}

function applyCatalogAdminFilters(query: any, input: CatalogAdminSearchInput): any {
  let filtered = query.eq("orgAdoptions.organization_id", input.organizationId);
  if (input.vendorId) filtered = filtered.eq("catalog_vendor_id", input.vendorId);
  if (input.lifecycle === "active") {
    filtered = filtered.eq("active", true).eq("discontinued", false);
  } else if (input.lifecycle === "discontinued") {
    filtered = filtered.eq("discontinued", true);
  }
  if (input.packageStatus !== "all") {
    filtered = filtered.eq("package_status", input.packageStatus);
  }
  if (input.adoption === "not_adopted") {
    filtered = filtered.is("orgAdoptions", null);
  }
  return filtered;
}

function applyCatalogSearchBucket(
  query: any,
  bucket: CatalogSearchBucket,
  terms: CatalogSearchTerms,
): any {
  if (bucket === "all") return query;
  if (bucket === "normalized_sku_exact") {
    return query.eq("normalized_vendor_sku", terms.normalizedSku);
  }
  if (bucket === "raw_sku_exact") {
    return query.eq("vendor_sku", terms.raw).neq("normalized_vendor_sku", terms.normalizedSku);
  }
  if (bucket === "sku_prefix") {
    return query
      .ilike("normalized_vendor_sku", terms.skuPrefixPattern)
      .neq("normalized_vendor_sku", terms.normalizedSku)
      .neq("vendor_sku", terms.raw);
  }

  let filtered = query;
  if (terms.normalizedSku) {
    filtered = filtered
      .not("normalized_vendor_sku", "ilike", terms.skuPrefixPattern)
      .neq("vendor_sku", terms.raw);
  }
  if (bucket === "product_name") {
    return filtered.ilike("product.normalized_name", terms.namePattern);
  }
  filtered = filtered.not("product.normalized_name", "ilike", terms.namePattern);
  if (bucket === "manufacturer") {
    return filtered.ilike("product.normalized_manufacturer", terms.namePattern);
  }
  return filtered
    .or(`normalized_manufacturer.is.null,normalized_manufacturer.not.ilike.${terms.namePattern}`, {
      referencedTable: "product",
    })
    .ilike("product.description", terms.descriptionPattern);
}

function catalogAdminQuery(
  db: any,
  input: CatalogAdminSearchInput,
  bucket: CatalogSearchBucket,
  terms: CatalogSearchTerms,
  options: { count?: "exact"; head?: boolean } = {},
): any {
  const adoptionInner = input.adoption === "adopted";
  const selected = db
    .from("catalog_vendor_products")
    .select(catalogAdminSelect(adoptionInner), options);
  return applyCatalogSearchBucket(applyCatalogAdminFilters(selected, input), bucket, terms);
}

function relationOne(value: unknown): any | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value && typeof value === "object" ? value : null;
}

function relationMany(value: unknown): any[] {
  if (Array.isArray(value)) return value;
  return value && typeof value === "object" ? [value] : [];
}

function mapCatalogAdminRow(row: any): CatalogAdminResult {
  const product = relationOne(row.product);
  const vendor = relationOne(row.vendor);
  if (!product || !vendor) throw new Error("Catalog identity is incomplete");

  const adoptions = relationMany(row.orgAdoptions);
  let adoptionState: CatalogAdminResult["adoptionState"] = "not_adopted";
  let adoptionIssue: string | null = null;
  let organizationVendorProductId: string | null = null;
  let organizationProductId: string | null = null;

  if (adoptions.length === 1) {
    const adoption = adoptions[0];
    const organizationVendor = relationOne(adoption.organizationVendor);
    const organizationProduct = relationOne(adoption.organizationProduct);
    organizationVendorProductId = String(adoption.id);
    if (
      !organizationVendor ||
      !organizationProduct ||
      organizationVendor.id !== adoption.vendor_id ||
      organizationProduct.id !== adoption.product_id ||
      organizationVendor.catalog_vendor_id !== row.catalog_vendor_id ||
      organizationProduct.catalog_product_id !== row.catalog_product_id
    ) {
      adoptionState = "attention";
      adoptionIssue = "The organization catalog link is incomplete or inconsistent.";
    } else {
      adoptionState = "adopted";
      organizationProductId = String(adoption.product_id);
    }
  } else if (adoptions.length > 1) {
    adoptionState = "attention";
    adoptionIssue = "Multiple organization catalog links require review.";
  }

  return {
    catalogVendorProductId: String(row.id),
    catalogProductId: String(row.catalog_product_id),
    catalogVendorId: String(row.catalog_vendor_id),
    productName: String(product.name),
    description: product.description ?? null,
    manufacturer: product.manufacturer ?? null,
    productActive: Boolean(product.active),
    vendorName: String(vendor.name),
    vendorSku: String(row.vendor_sku),
    normalizedVendorSku: String(row.normalized_vendor_sku),
    manufacturerSku: row.manufacturer_sku ?? null,
    packageDescription: row.package_description ?? null,
    packageQuantity:
      row.package_quantity === null || row.package_quantity === undefined
        ? null
        : Number(row.package_quantity),
    packageUnit: row.package_unit ?? null,
    packageStatus: row.package_status,
    active: Boolean(row.active),
    discontinued: Boolean(row.discontinued),
    verificationStatus: String(row.verification_status),
    adoptionState,
    adoptionIssue,
    organizationVendorProductId,
    organizationProductId,
    inventoryState:
      adoptionState === "adopted"
        ? "not_stocked"
        : adoptionState === "attention"
          ? "attention"
          : "not_applicable",
    inventoryItemId: null,
    inventoryActive: null,
  };
}

async function markPartialCatalogLinks(
  db: any,
  organizationId: string,
  rows: CatalogAdminResult[],
): Promise<CatalogAdminResult[]> {
  const candidates = rows.filter((row) => row.adoptionState === "not_adopted");
  if (!candidates.length) return rows;
  const catalogVendorIds = [...new Set(candidates.map((row) => row.catalogVendorId))];
  const catalogProductIds = [...new Set(candidates.map((row) => row.catalogProductId))];
  const [vendorsResult, productsResult] = await Promise.all([
    db
      .from("vendors")
      .select("id,catalog_vendor_id")
      .eq("organization_id", organizationId)
      .in("catalog_vendor_id", catalogVendorIds),
    db
      .from("products")
      .select("id,catalog_product_id")
      .eq("organization_id", organizationId)
      .in("catalog_product_id", catalogProductIds),
  ]);
  if (vendorsResult.error || productsResult.error) {
    throw new Error("Unable to verify organization adoption state");
  }
  const linkedVendors = new Set(
    (vendorsResult.data ?? []).map((row: any) => row.catalog_vendor_id),
  );
  const linkedProducts = new Set(
    (productsResult.data ?? []).map((row: any) => row.catalog_product_id),
  );
  return rows.map((row) =>
    row.adoptionState === "not_adopted" &&
    (linkedVendors.has(row.catalogVendorId) || linkedProducts.has(row.catalogProductId))
      ? {
          ...row,
          adoptionState: "attention" as const,
          adoptionIssue: "A partial organization catalog link requires review before adoption.",
          inventoryState: "attention" as const,
        }
      : row,
  );
}

async function markCatalogInventoryState(
  db: any,
  organizationId: string,
  rows: CatalogAdminResult[],
): Promise<CatalogAdminResult[]> {
  const productIds = [
    ...new Set(
      rows
        .filter((row) => row.adoptionState === "adopted" && row.organizationProductId)
        .map((row) => row.organizationProductId as string),
    ),
  ];
  if (!productIds.length) return rows;

  const { data: inventoryRows, error } = await db
    .from("inventory_items")
    .select("id,product_id,active")
    .eq("organization_id", organizationId)
    .in("product_id", productIds);
  if (error) throw new Error("Unable to verify catalog inventory state");

  const inventoryByProduct = new Map<string, any[]>();
  for (const inventoryRow of inventoryRows ?? []) {
    if (!inventoryRow.product_id) continue;
    const matches = inventoryByProduct.get(inventoryRow.product_id) ?? [];
    matches.push(inventoryRow);
    inventoryByProduct.set(inventoryRow.product_id, matches);
  }

  return rows.map((row) => {
    if (row.adoptionState !== "adopted" || !row.organizationProductId) return row;
    const matches = inventoryByProduct.get(row.organizationProductId) ?? [];
    if (matches.length > 1) {
      return {
        ...row,
        inventoryState: "attention" as const,
        adoptionIssue: "Multiple inventory links require review.",
      };
    }
    if (matches.length === 1) {
      return {
        ...row,
        inventoryState: "stocked" as const,
        inventoryItemId: String(matches[0].id),
        inventoryActive: Boolean(matches[0].active),
      };
    }
    return row;
  });
}

export const listCatalogAdminVendorsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: orgId }).parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { data: vendors, error } = await db
      .from("catalog_vendors")
      .select("id,name")
      .order("name");
    if (error) throw new Error("Unable to load catalog vendors");
    return (vendors ?? []).map((vendor: any) => ({
      id: String(vendor.id),
      name: String(vendor.name),
    }));
  });

export const searchCatalogAdminFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => catalogAdminSearchInput.parse(d))
  .handler(async ({ data, context }) => {
    const input = data as CatalogAdminSearchInput;
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, input.organizationId);

    const terms = catalogSearchTerms(input.q);
    const buckets = catalogSearchBuckets(terms);
    const counts = await Promise.all(
      buckets.map(async (bucket) => {
        const { count, error } = await catalogAdminQuery(db, input, bucket, terms, {
          count: "exact",
          head: true,
        });
        if (error) throw new Error("Unable to search the global catalog");
        return count ?? 0;
      }),
    );

    const totalCount = counts.reduce((sum, count) => sum + count, 0);
    const pageOffset = (input.page - 1) * CATALOG_ADMIN_PAGE_SIZE;
    const pageEnd = pageOffset + CATALOG_ADMIN_PAGE_SIZE;
    let bucketOffset = 0;
    const slices: Array<{
      bucket: CatalogSearchBucket;
      start: number;
      end: number;
    }> = [];

    for (let index = 0; index < buckets.length; index += 1) {
      const bucketCount = counts[index];
      const bucketEnd = bucketOffset + bucketCount;
      const overlapStart = Math.max(pageOffset, bucketOffset);
      const overlapEnd = Math.min(pageEnd, bucketEnd);
      if (overlapStart < overlapEnd) {
        slices.push({
          bucket: buckets[index],
          start: overlapStart - bucketOffset,
          end: overlapEnd - bucketOffset - 1,
        });
      }
      bucketOffset = bucketEnd;
    }

    const pageParts = await Promise.all(
      slices.map(async ({ bucket, start, end }) => {
        const { data: rows, error } = await catalogAdminQuery(db, input, bucket, terms)
          .order("normalized_vendor_sku")
          .order("id")
          .range(start, end);
        if (error) throw new Error("Unable to load catalog search results");
        return rows ?? [];
      }),
    );

    const mapped = pageParts.flat().map(mapCatalogAdminRow);
    const linked = await markPartialCatalogLinks(db, input.organizationId, mapped);
    const rows = await markCatalogInventoryState(db, input.organizationId, linked);
    return {
      rows,
      page: input.page,
      pageSize: CATALOG_ADMIN_PAGE_SIZE,
      totalCount,
      totalPages: Math.ceil(totalCount / CATALOG_ADMIN_PAGE_SIZE),
    };
  });

export const getCatalogAdminDetailFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: orgId, catalogVendorProductId: z.string().uuid() }).parse(d),
  )
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { data: detail, error } = await db.rpc("get_catalog_vendor_product_admin_detail", {
      _organization_id: data.organizationId,
      _catalog_vendor_product_id: data.catalogVendorProductId,
    });
    if (error) {
      if (error.code === "42501") throw new Error("Forbidden");
      if (error.code === "P0002") throw new Error("This catalog item no longer exists");
      throw new Error("Unable to load catalog provenance");
    }
    return catalogAdminDetailSchema.parse(detail) as CatalogAdminDetail;
  });

export const adoptCatalogVendorProductFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: orgId, catalogVendorProductId: z.string().uuid() }).parse(d),
  )
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { data: result, error } = await db.rpc("adopt_catalog_vendor_product", {
      _organization_id: data.organizationId,
      _catalog_vendor_product_id: data.catalogVendorProductId,
    });
    if (error) {
      if (error.code === "42501") throw new Error("Forbidden");
      if (error.code === "P0002") throw new Error("This catalog item no longer exists");
      if (error.code === "23505" || error.code === "23514") {
        throw new Error(
          "Existing organization catalog links need review before this item can be added",
        );
      }
      throw new Error("Unable to add this item to the organization catalog");
    }
    return catalogAdoptionResultSchema.parse(result) as CatalogAdoptionResult;
  });

export const stockCatalogVendorProductFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        organizationId: orgId,
        catalogVendorProductId: z.string().uuid(),
        unit: z.string().trim().min(1).max(80).nullable().default(null),
        parLevel: z.number().finite().nonnegative().nullable().default(null),
      })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { data: result, error } = await db.rpc("stock_catalog_vendor_product", {
      _organization_id: data.organizationId,
      _catalog_vendor_product_id: data.catalogVendorProductId,
      _unit: data.unit,
      _par_level: data.parLevel,
    });
    if (error) {
      const message = String(error.message ?? "");
      if (error.code === "42501") throw new Error("Forbidden");
      if (error.code === "P0002") throw new Error("This catalog item no longer exists");
      if (error.code === "55000" && message.includes("Adopt this catalog product")) {
        throw new Error("Add this item to the organization catalog before adding inventory");
      }
      if (error.code === "55000" && message.includes("Inactive or discontinued")) {
        throw new Error("Inactive or discontinued catalog items cannot create new inventory");
      }
      if (error.code === "22023" && message.includes("Par level")) {
        throw new Error("Par level must be zero or greater");
      }
      if (error.code === "22023" || error.code === "22001") {
        throw new Error("Enter a valid inventory unit of 80 characters or fewer");
      }
      if (error.code === "23505" || error.code === "23514") {
        throw new Error("Existing catalog or inventory links need review before stocking");
      }
      throw new Error("Unable to add this catalog item to inventory");
    }
    return catalogStockResultSchema.parse(result) as CatalogStockResult;
  });

export const saveCategoryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        organizationId: orgId,
        id: z.string().uuid().optional(),
        name: z.string().trim().min(1).max(120),
        parentCategoryId: z.string().uuid().optional().nullable(),
      })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const payload = {
      organization_id: data.organizationId,
      name: data.name,
      parent_category_id: data.parentCategoryId ?? null,
    };
    const query = data.id
      ? db
          .from("product_categories")
          .update(payload)
          .eq("id", data.id)
          .eq("organization_id", data.organizationId)
      : db.from("product_categories").insert(payload);
    const { data: row, error } = await query.select("id").single();
    if (error)
      throw new Error(
        error.code === "23505"
          ? "An active category with this normalized name already exists"
          : error.message,
      );
    return { id: row.id as string };
  });

export const setCategoryActiveFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: orgId, id: z.string().uuid(), active: z.boolean() }).parse(d),
  )
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { error } = await db
      .from("product_categories")
      .update({ active: data.active })
      .eq("id", data.id)
      .eq("organization_id", data.organizationId);
    if (error)
      throw new Error(
        error.code === "23505"
          ? "Restore blocked by an active category with the same normalized name"
          : error.message,
      );
    return { ok: true };
  });

const vendorInput = z.object({
  organizationId: orgId,
  id: z.string().uuid().optional(),
  name: z.string().trim().min(1).max(160),
  accountNumber: optionalText,
  contactName: optionalText,
  email: optionalText,
  phone: optionalText,
  website: optionalText,
  notes: optionalText,
});
export const saveVendorFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => vendorInput.parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const warnings = await likelyDuplicates(db, "vendors", data.organizationId, data.name, data.id);
    const payload = {
      organization_id: data.organizationId,
      name: data.name,
      account_number: data.accountNumber || null,
      contact_name: data.contactName || null,
      email: data.email || null,
      phone: data.phone || null,
      website: data.website || null,
      notes: data.notes || null,
    };
    const query = data.id
      ? db
          .from("vendors")
          .update(payload)
          .eq("id", data.id)
          .eq("organization_id", data.organizationId)
      : db.from("vendors").insert(payload);
    const { data: row, error } = await query.select("id").single();
    if (error)
      throw new Error(
        error.code === "23505"
          ? "An active vendor with this normalized name already exists"
          : error.message,
      );
    return { id: row.id as string, warnings };
  });

export const setVendorActiveFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: orgId, id: z.string().uuid(), active: z.boolean() }).parse(d),
  )
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { error } = await db
      .from("vendors")
      .update({ active: data.active })
      .eq("id", data.id)
      .eq("organization_id", data.organizationId);
    if (error)
      throw new Error(
        error.code === "23505"
          ? "Restore blocked by an active vendor with the same normalized name"
          : error.message,
      );
    return { ok: true };
  });

const productInput = z.object({
  organizationId: orgId,
  id: z.string().uuid().optional(),
  name: z.string().trim().min(1).max(200),
  description: optionalText,
  categoryId: z.string().uuid().optional().nullable(),
  preferredVendorId: z.string().uuid().optional().nullable(),
  manufacturer: optionalText,
  vendorItemNumber: optionalText,
  internalItemCode: optionalText,
  unitOfMeasure: optionalText,
  packSize: optionalText,
  staffRequestable: z.boolean().default(true),
});
export const saveProductFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => productInput.parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const warnings = await likelyDuplicates(
      db,
      "products",
      data.organizationId,
      data.name,
      data.id,
    );
    const payload = {
      organization_id: data.organizationId,
      name: data.name,
      description: data.description || null,
      category_id: data.categoryId || null,
      preferred_vendor_id: data.preferredVendorId || null,
      manufacturer: data.manufacturer || null,
      vendor_item_number: data.vendorItemNumber || null,
      internal_item_code: data.internalItemCode || null,
      unit_of_measure: data.unitOfMeasure || null,
      unit: data.unitOfMeasure || null,
      pack_size: data.packSize || null,
      staff_requestable: data.staffRequestable,
      approved: data.staffRequestable,
    };
    const query = data.id
      ? db
          .from("products")
          .update(payload)
          .eq("id", data.id)
          .eq("organization_id", data.organizationId)
      : db.from("products").insert(payload);
    const { data: row, error } = await query.select("id").single();
    if (error)
      throw new Error(
        error.code === "23505"
          ? "An active product with this normalized name already exists"
          : error.message,
      );
    return { id: row.id as string, warnings };
  });

export const setProductActiveFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: orgId, id: z.string().uuid(), active: z.boolean() }).parse(d),
  )
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { error } = await db
      .from("products")
      .update({ active: data.active })
      .eq("id", data.id)
      .eq("organization_id", data.organizationId);
    if (error)
      throw new Error(
        error.code === "23505"
          ? "Restore blocked by an active product with the same normalized name"
          : error.message,
      );
    return { ok: true };
  });

export const saveAliasFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        organizationId: orgId,
        productId: z.string().uuid(),
        id: z.string().uuid().optional(),
        alias: z.string().trim().min(1).max(200),
      })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const payload = {
      organization_id: data.organizationId,
      product_id: data.productId,
      alias: data.alias,
    };
    const query = data.id
      ? db
          .from("product_aliases")
          .update(payload)
          .eq("id", data.id)
          .eq("organization_id", data.organizationId)
      : db.from("product_aliases").insert(payload);
    const { data: row, error } = await query.select("id").single();
    if (error)
      throw new Error(
        error.code === "23505" ? "This alias already exists for the product" : error.message,
      );
    return { id: row.id as string };
  });

export const deleteAliasFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: orgId, id: z.string().uuid() }).parse(d),
  )
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { error } = await db
      .from("product_aliases")
      .delete()
      .eq("id", data.id)
      .eq("organization_id", data.organizationId);
    if (error) throw new Error(error.message);
    return { ok: true };
  });

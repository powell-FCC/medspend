/* eslint-disable @typescript-eslint/no-explicit-any -- Supabase query builders are dynamically typed in this module. */
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { escapePostgresLike, isCatalogAdminRole } from "@/catalog-admin/catalog-admin";
import {
  describeCatalogVendorLinkError,
  type CatalogCoverage,
  type CatalogVendorLinkResult,
  type LinkableCatalogVendor,
  type OrganizationVendorLink,
} from "@/catalog-admin/vendor-management";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

const uuid = z.string().uuid();

async function assertAdmin(db: any, userId: string, organizationId: string) {
  const { data, error } = await db
    .from("organization_memberships")
    .select("role")
    .eq("organization_id", organizationId)
    .eq("user_id", userId)
    .eq("active", true)
    .maybeSingle();
  if (error) throw new Error("Unable to verify organization access");
  if (!data || !isCatalogAdminRole(data.role)) throw new Error("Forbidden");
}

function relationOne(value: unknown): any | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value && typeof value === "object" ? value : null;
}

const linkResultSchema = z
  .object({
    organizationId: uuid,
    vendorId: uuid,
    catalogVendorId: uuid,
    catalogVendorName: z.string(),
    alreadyLinked: z.boolean(),
    updatedAt: z.string(),
  })
  .strict();

const coverageListingSchema = z
  .object({
    id: uuid,
    vendorSku: z.string(),
    productName: z.string(),
    verificationStatus: z.string(),
    active: z.boolean(),
    discontinued: z.boolean(),
  })
  .strict();

const coverageSchema = z
  .object({
    vendorId: uuid,
    vendorName: z.string(),
    linked: z.boolean(),
    catalogVendor: z
      .object({ id: uuid, name: z.string(), active: z.boolean() })
      .strict()
      .nullable(),
    summary: z
      .object({
        mapped: z.number().int().nonnegative(),
        represented: z.number().int().nonnegative(),
        notRepresented: z.number().int().nonnegative(),
        inactiveMappings: z.number().int().nonnegative(),
      })
      .strict()
      .nullable(),
    rows: z.array(
      z
        .object({
          vendorProductId: uuid,
          vendorSku: z.string(),
          manufacturerSku: z.string().nullable(),
          packageSize: z.string().nullable(),
          unitOfMeasure: z.string().nullable(),
          mappingActive: z.boolean(),
          mappingCreatedAt: z.string(),
          productId: uuid,
          productName: z.string(),
          manufacturer: z.string().nullable(),
          productActive: z.boolean(),
          status: z.enum(["linked", "exact", "separator_equivalent", "ambiguous", "not_cataloged"]),
          listing: coverageListingSchema.nullable(),
        })
        .strict(),
    ),
    truncated: z.boolean(),
  })
  .strict();

export const listOrganizationVendorLinksFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: uuid }).parse(d))
  .handler(async ({ data, context }): Promise<OrganizationVendorLink[]> => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { data: rows, error } = await db
      .from("vendors")
      .select(
        "id,name,active,updated_at,catalog_vendor_id,catalogVendor:catalog_vendors!vendors_catalog_vendor_fk(id,name,active)",
      )
      .eq("organization_id", data.organizationId)
      .order("active", { ascending: false })
      .order("name");
    if (error) throw new Error("Unable to load organization vendors");
    return (rows ?? []).map((row: any) => {
      const catalogVendor = relationOne(row.catalogVendor);
      return {
        vendorId: String(row.id),
        vendorName: String(row.name),
        vendorActive: Boolean(row.active),
        updatedAt: String(row.updated_at),
        catalogVendorId: row.catalog_vendor_id ? String(row.catalog_vendor_id) : null,
        catalogVendorName: catalogVendor ? String(catalogVendor.name) : null,
        catalogVendorActive: catalogVendor ? Boolean(catalogVendor.active) : null,
      };
    });
  });

// Catalog vendors are global and readable by any signed-in user; the admin check keeps this
// search inside the management workflow. The organization's own links are attached so the
// dialog can show which catalog vendors are already taken.
export const searchLinkableCatalogVendorsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: uuid, q: z.string().trim().max(120).default("") }).parse(d),
  )
  .handler(async ({ data, context }): Promise<LinkableCatalogVendor[]> => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    let query = db.from("catalog_vendors").select("id,name,active").order("name").limit(50);
    if (data.q) query = query.ilike("name", `%${escapePostgresLike(data.q)}%`);
    const [catalogResult, linksResult] = await Promise.all([
      query,
      db
        .from("vendors")
        .select("name,catalog_vendor_id")
        .eq("organization_id", data.organizationId)
        .not("catalog_vendor_id", "is", null),
    ]);
    if (catalogResult.error || linksResult.error) {
      throw new Error("Unable to search catalog vendors");
    }
    const linkedBy = new Map<string, string>(
      (linksResult.data ?? []).map((row: any) => [String(row.catalog_vendor_id), String(row.name)]),
    );
    return (catalogResult.data ?? []).map((row: any) => ({
      id: String(row.id),
      name: String(row.name),
      active: Boolean(row.active),
      linkedOrganizationVendorName: linkedBy.get(String(row.id)) ?? null,
    }));
  });

export const linkOrganizationVendorFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        organizationId: uuid,
        vendorId: uuid,
        catalogVendorId: uuid,
        expectedUpdatedAt: z.string().min(1).max(64),
      })
      .parse(d),
  )
  .handler(async ({ data, context }): Promise<CatalogVendorLinkResult> => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { data: result, error } = await db.rpc("link_organization_vendor_to_catalog_vendor", {
      _organization_id: data.organizationId,
      _vendor_id: data.vendorId,
      _catalog_vendor_id: data.catalogVendorId,
      _expected_updated_at: data.expectedUpdatedAt,
    });
    if (error) throw new Error(describeCatalogVendorLinkError(error.code, error.message));
    return linkResultSchema.parse(result);
  });

export const getVendorCatalogCoverageFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: uuid, vendorId: uuid }).parse(d))
  .handler(async ({ data, context }): Promise<CatalogCoverage> => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { data: result, error } = await db.rpc("get_organization_vendor_catalog_coverage", {
      _organization_id: data.organizationId,
      _vendor_id: data.vendorId,
    });
    if (error) {
      if (error.code === "42501") throw new Error("Forbidden");
      if (error.code === "P0002")
        throw new Error("This vendor no longer exists in this organization");
      throw new Error("Unable to load catalog coverage");
    }
    return coverageSchema.parse(result);
  });

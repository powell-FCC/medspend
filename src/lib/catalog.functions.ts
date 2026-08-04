import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
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
  if (!data || !["owner", "admin"].includes(data.role)) throw new Error("Forbidden");
}

function normalize(value: string) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

async function likelyDuplicates(db: any, table: "vendors" | "products", organizationId: string, name: string, excludeId?: string) {
  const normalized = normalize(name);
  const token = normalized.split(" ").filter(Boolean).sort((a, b) => b.length - a.length)[0] ?? normalized;
  let q = db.from(table).select("id, name, active").eq("organization_id", organizationId).ilike("normalized_name", `%${token}%`).limit(5);
  if (excludeId) q = q.neq("id", excludeId);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return (data ?? []).filter((row: any) => normalize(row.name) === normalized || token.length >= 4);
}

export const listCatalogFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: orgId, q: z.string().max(120).default(""), includeArchived: z.boolean().default(true) }).parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const term = data.q.trim();
    const { data: aliasMatches, error: aliasSearchError } = term
      ? await db.from("product_aliases").select("product_id").eq("organization_id", data.organizationId).ilike("normalized_alias", `%${term}%`).limit(50)
      : { data: [], error: null };
    if (aliasSearchError) throw new Error(aliasSearchError.message);
    const aliasProductIds = (aliasMatches ?? []).map((row: any) => row.product_id);
    const list = async (table: string, select: string, searchColumns: string[], extraSearch: string[] = []) => {
      let query = db.from(table).select(select).eq("organization_id", data.organizationId).order("name");
      if (!data.includeArchived) query = query.eq("active", true);
      if (term) query = query.or([...searchColumns.map((c) => `${c}.ilike.%${term.replaceAll(",", "")}%`), ...extraSearch].join(","));
      const { data: rows, error } = await query;
      if (error) throw new Error(error.message);
      return rows ?? [];
    };
    const [categories, vendors, products] = await Promise.all([
      list("product_categories", "id,name,parent_category_id,active,created_at", ["name", "normalized_name"]),
      list("vendors", "id,name,account_number,contact_name,email,phone,website,notes,active,created_at,updated_at", ["name", "normalized_name", "account_number", "contact_name", "email"]),
      list("products", "id,name,description,category_id,preferred_vendor_id,manufacturer,vendor_item_number,internal_item_code,unit_of_measure,pack_size,active,staff_requestable,created_at,updated_at,product_aliases!product_aliases_product_id_fkey(id,alias)", ["name", "normalized_name", "description", "manufacturer", "vendor_item_number", "internal_item_code"], aliasProductIds.length ? [`id.in.(${aliasProductIds.join(",")})`] : []),
    ]);
    return { categories, vendors, products };
  });

export const saveCategoryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: orgId, id: z.string().uuid().optional(), name: z.string().trim().min(1).max(120), parentCategoryId: z.string().uuid().optional().nullable() }).parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const payload = { organization_id: data.organizationId, name: data.name, parent_category_id: data.parentCategoryId ?? null };
    const query = data.id
      ? db.from("product_categories").update(payload).eq("id", data.id).eq("organization_id", data.organizationId)
      : db.from("product_categories").insert(payload);
    const { data: row, error } = await query.select("id").single();
    if (error) throw new Error(error.code === "23505" ? "An active category with this normalized name already exists" : error.message);
    return { id: row.id as string };
  });

export const setCategoryActiveFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: orgId, id: z.string().uuid(), active: z.boolean() }).parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const { error } = await db.from("product_categories").update({ active: data.active }).eq("id", data.id).eq("organization_id", data.organizationId);
    if (error) throw new Error(error.code === "23505" ? "Restore blocked by an active category with the same normalized name" : error.message);
    return { ok: true };
  });

const vendorInput = z.object({
  organizationId: orgId, id: z.string().uuid().optional(), name: z.string().trim().min(1).max(160),
  accountNumber: optionalText, contactName: optionalText, email: optionalText, phone: optionalText,
  website: optionalText, notes: optionalText,
});
export const saveVendorFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth]).inputValidator((d: unknown) => vendorInput.parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any;
    await assertAdmin(db, context.userId, data.organizationId);
    const warnings = await likelyDuplicates(db, "vendors", data.organizationId, data.name, data.id);
    const payload = { organization_id: data.organizationId, name: data.name, account_number: data.accountNumber || null, contact_name: data.contactName || null, email: data.email || null, phone: data.phone || null, website: data.website || null, notes: data.notes || null };
    const query = data.id ? db.from("vendors").update(payload).eq("id", data.id).eq("organization_id", data.organizationId) : db.from("vendors").insert(payload);
    const { data: row, error } = await query.select("id").single();
    if (error) throw new Error(error.code === "23505" ? "An active vendor with this normalized name already exists" : error.message);
    return { id: row.id as string, warnings };
  });

export const setVendorActiveFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth]).inputValidator((d: unknown) => z.object({ organizationId: orgId, id: z.string().uuid(), active: z.boolean() }).parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any; await assertAdmin(db, context.userId, data.organizationId);
    const { error } = await db.from("vendors").update({ active: data.active }).eq("id", data.id).eq("organization_id", data.organizationId);
    if (error) throw new Error(error.code === "23505" ? "Restore blocked by an active vendor with the same normalized name" : error.message);
    return { ok: true };
  });

const productInput = z.object({
  organizationId: orgId, id: z.string().uuid().optional(), name: z.string().trim().min(1).max(200),
  description: optionalText, categoryId: z.string().uuid().optional().nullable(), preferredVendorId: z.string().uuid().optional().nullable(),
  manufacturer: optionalText, vendorItemNumber: optionalText, internalItemCode: optionalText,
  unitOfMeasure: optionalText, packSize: optionalText, staffRequestable: z.boolean().default(true),
});
export const saveProductFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth]).inputValidator((d: unknown) => productInput.parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any; await assertAdmin(db, context.userId, data.organizationId);
    const warnings = await likelyDuplicates(db, "products", data.organizationId, data.name, data.id);
    const payload = { organization_id: data.organizationId, name: data.name, description: data.description || null, category_id: data.categoryId || null, preferred_vendor_id: data.preferredVendorId || null, manufacturer: data.manufacturer || null, vendor_item_number: data.vendorItemNumber || null, internal_item_code: data.internalItemCode || null, unit_of_measure: data.unitOfMeasure || null, unit: data.unitOfMeasure || null, pack_size: data.packSize || null, staff_requestable: data.staffRequestable, approved: data.staffRequestable };
    const query = data.id ? db.from("products").update(payload).eq("id", data.id).eq("organization_id", data.organizationId) : db.from("products").insert(payload);
    const { data: row, error } = await query.select("id").single();
    if (error) throw new Error(error.code === "23505" ? "An active product with this normalized name already exists" : error.message);
    return { id: row.id as string, warnings };
  });

export const setProductActiveFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth]).inputValidator((d: unknown) => z.object({ organizationId: orgId, id: z.string().uuid(), active: z.boolean() }).parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any; await assertAdmin(db, context.userId, data.organizationId);
    const { error } = await db.from("products").update({ active: data.active }).eq("id", data.id).eq("organization_id", data.organizationId);
    if (error) throw new Error(error.code === "23505" ? "Restore blocked by an active product with the same normalized name" : error.message);
    return { ok: true };
  });

export const saveAliasFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth]).inputValidator((d: unknown) => z.object({ organizationId: orgId, productId: z.string().uuid(), id: z.string().uuid().optional(), alias: z.string().trim().min(1).max(200) }).parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any; await assertAdmin(db, context.userId, data.organizationId);
    const payload = { organization_id: data.organizationId, product_id: data.productId, alias: data.alias };
    const query = data.id ? db.from("product_aliases").update(payload).eq("id", data.id).eq("organization_id", data.organizationId) : db.from("product_aliases").insert(payload);
    const { data: row, error } = await query.select("id").single();
    if (error) throw new Error(error.code === "23505" ? "This alias already exists for the product" : error.message);
    return { id: row.id as string };
  });

export const deleteAliasFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth]).inputValidator((d: unknown) => z.object({ organizationId: orgId, id: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    const db = context.supabase as any; await assertAdmin(db, context.userId, data.organizationId);
    const { error } = await db.from("product_aliases").delete().eq("id", data.id).eq("organization_id", data.organizationId);
    if (error) throw new Error(error.message); return { ok: true };
  });

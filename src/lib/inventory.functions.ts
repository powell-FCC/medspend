import { createServerFn } from "@tanstack/react-start";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import type { Database } from "@/integrations/supabase/types";
import { getInventoryStatus } from "@/inventory/status";
import { locationAdjustmentReasons } from "@/types/inventory";
import type {
  InventoryCategory,
  InventoryItem,
  InventoryLocation,
  InventoryLocationBalance,
} from "@/types/inventory";

const uuid = z.string().uuid();
const optionalText = z.string().trim().max(500).optional().nullable();
const itemInput = z.object({
  id: uuid.optional(),
  organizationId: uuid,
  name: z.string().trim().min(1).max(200),
  description: optionalText,
  sku: optionalText,
  vendorName: optionalText,
  category: optionalText,
  manufacturer: optionalText,
  // Starting stock for a new item (it lands in Unassigned). Ignored when editing: existing
  // stock changes only through location adjustments and moves.
  quantity: z.number().nonnegative().default(0),
  unit: z.string().trim().min(1).max(80),
  parLevel: z.number().nonnegative().optional().nullable(),
});

async function assertOwner(db: SupabaseClient<Database>, userId: string, organizationId: string) {
  const { data, error } = await db
    .from("organization_memberships")
    .select("role")
    .eq("organization_id", organizationId)
    .eq("user_id", userId)
    .eq("active", true)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (data?.role !== "owner") throw new Error("Forbidden: owner access required");
}

const toLocation = (
  row: Database["public"]["Tables"]["inventory_locations"]["Row"],
): InventoryLocation => ({
  id: row.id,
  organizationId: row.organization_id,
  name: row.name,
  description: row.description,
  kind: row.kind === "unassigned" ? "unassigned" : "storage",
  active: row.active,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

const toBalance = (
  row: Database["public"]["Tables"]["inventory_location_balances"]["Row"],
): InventoryLocationBalance => ({
  inventoryItemId: row.inventory_item_id,
  inventoryLocationId: row.inventory_location_id,
  quantity: Number(row.quantity),
  version: row.version,
  updatedAt: row.updated_at,
});

async function unassignedLocationId(db: SupabaseClient<Database>, organizationId: string) {
  const { data, error } = await db
    .from("inventory_locations")
    .select("id")
    .eq("organization_id", organizationId)
    .eq("kind", "unassigned")
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error("This organization has no Unassigned inventory location.");
  return data.id;
}

const toItem = (row: Database["public"]["Tables"]["inventory_items"]["Row"]): InventoryItem => ({
  id: row.id,
  organizationId: row.organization_id,
  name: row.name,
  description: row.description,
  sku: row.sku,
  vendorName: row.vendor_name,
  category: row.category,
  manufacturer: row.manufacturer,
  quantity: row.quantity,
  unit: row.unit,
  parLevel: row.par_level,
  active: row.active,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

export const listInventoryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        search: z.string().max(120).default(""),
        category: z.string().max(120).default(""),
        status: z.enum(["all", "active", "archived"]).default("active"),
        lowStock: z.boolean().default(false),
      })
      .parse(value),
  )
  .handler(async ({ data, context }) => {
    let query = context.supabase
      .from("inventory_items")
      .select("*")
      .eq("organization_id", data.organizationId)
      .order("name");
    if (data.status === "active") query = query.eq("active", true);
    if (data.status === "archived") query = query.eq("active", false);
    if (data.category) query = query.eq("category", data.category);
    const search = data.search.trim().replaceAll(",", "");
    if (search)
      query = query.or(
        `name.ilike.%${search}%,sku.ilike.%${search}%,vendor_name.ilike.%${search}%,manufacturer.ilike.%${search}%`,
      );
    // Location rows are owner-only under RLS; other roles simply receive none.
    const [itemsResult, categoriesResult, locationsResult, balancesResult] = await Promise.all([
      query,
      context.supabase
        .from("inventory_categories")
        .select("*")
        .eq("organization_id", data.organizationId)
        .order("name"),
      context.supabase
        .from("inventory_locations")
        .select("*")
        .eq("organization_id", data.organizationId),
      context.supabase
        .from("inventory_location_balances")
        .select("*")
        .eq("organization_id", data.organizationId),
    ]);
    if (itemsResult.error) throw new Error(itemsResult.error.message);
    if (categoriesResult.error) throw new Error(categoriesResult.error.message);
    if (locationsResult.error) throw new Error(locationsResult.error.message);
    if (balancesResult.error) throw new Error(balancesResult.error.message);
    const items = (itemsResult.data ?? [])
      .map(toItem)
      .filter(
        (item) =>
          !data.lowStock ||
          ["low", "critical"].includes(
            getInventoryStatus(item.quantity, item.parLevel, item.active),
          ),
      );
    const categories: InventoryCategory[] = (categoriesResult.data ?? []).map((row) => ({
      id: row.id,
      organizationId: row.organization_id,
      name: row.name,
      createdAt: row.created_at,
    }));
    const locations = (locationsResult.data ?? []).map(toLocation);
    const balances = (balancesResult.data ?? []).map(toBalance);
    return { items, categories, locations, balances };
  });

export const saveInventoryItemFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => itemInput.parse(value))
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const payload = {
      name: data.name,
      description: data.description || null,
      sku: data.sku || null,
      vendor_name: data.vendorName || null,
      category: data.category || null,
      manufacturer: data.manufacturer || null,
      unit: data.unit,
      par_level: data.parLevel ?? null,
    };
    if (data.id) {
      const { error } = await context.supabase
        .from("inventory_items")
        .update(payload)
        .eq("id", data.id)
        .eq("organization_id", data.organizationId);
      if (error) throw new Error(error.message);
      return { id: data.id };
    }
    const { data: row, error } = await context.supabase
      .from("inventory_items")
      .insert({ organization_id: data.organizationId, ...payload, quantity: 0 })
      .select("id")
      .single();
    if (error) throw new Error(error.message);
    if (data.quantity > 0) {
      const { error: adjustmentError } = await context.supabase.rpc(
        "adjust_inventory_location_quantity",
        {
          _organization_id: data.organizationId,
          _inventory_item_id: row.id,
          _inventory_location_id: await unassignedLocationId(context.supabase, data.organizationId),
          _adjustment_amount: data.quantity,
          _reason: "Manual adjustment",
        },
      );
      if (adjustmentError) throw new Error(adjustmentError.message);
    }
    return { id: row.id };
  });

export const adjustInventoryQuantityFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        inventoryItemId: uuid,
        inventoryLocationId: uuid,
        amount: z
          .number()
          .finite()
          .refine((n) => n !== 0),
        reason: z.enum(locationAdjustmentReasons as [string, ...string[]]),
      })
      .parse(value),
  )
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: result, error } = await context.supabase.rpc(
      "adjust_inventory_location_quantity",
      {
        _organization_id: data.organizationId,
        _inventory_item_id: data.inventoryItemId,
        _inventory_location_id: data.inventoryLocationId,
        _adjustment_amount: data.amount,
        _reason: data.reason,
      },
    );
    if (error) throw new Error(error.message);
    const values = result as { itemQuantity: number; locationQuantity: number };
    return {
      quantity: Number(values.itemQuantity),
      locationQuantity: Number(values.locationQuantity),
    };
  });

export const setInventoryItemActiveFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, id: uuid, active: z.boolean() }).parse(value),
  )
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { error } = await context.supabase
      .from("inventory_items")
      .update({ active: data.active })
      .eq("id", data.id)
      .eq("organization_id", data.organizationId);
    if (error) throw new Error(error.message);
    return { ok: true };
  });

export const saveInventoryCategoryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        id: uuid.optional(),
        name: z.string().trim().min(1).max(120),
      })
      .parse(value),
  )
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    if (data.id) {
      const { data: previous, error: readError } = await context.supabase
        .from("inventory_categories")
        .select("name")
        .eq("id", data.id)
        .eq("organization_id", data.organizationId)
        .single();
      if (readError) throw new Error(readError.message);
      const { error } = await context.supabase
        .from("inventory_categories")
        .update({ name: data.name })
        .eq("id", data.id)
        .eq("organization_id", data.organizationId);
      if (error)
        throw new Error(error.code === "23505" ? "That category already exists." : error.message);
      const { error: itemError } = await context.supabase
        .from("inventory_items")
        .update({ category: data.name })
        .eq("organization_id", data.organizationId)
        .eq("category", previous.name);
      if (itemError) throw new Error(itemError.message);
      return { id: data.id };
    }
    const { data: row, error } = await context.supabase
      .from("inventory_categories")
      .insert({ organization_id: data.organizationId, name: data.name })
      .select("id")
      .single();
    if (error)
      throw new Error(error.code === "23505" ? "That category already exists." : error.message);
    return { id: row.id };
  });

export const deleteInventoryCategoryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: uuid, id: uuid }).parse(value))
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: category, error: readError } = await context.supabase
      .from("inventory_categories")
      .select("name")
      .eq("id", data.id)
      .eq("organization_id", data.organizationId)
      .single();
    if (readError) throw new Error(readError.message);
    const { count, error: useError } = await context.supabase
      .from("inventory_items")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", data.organizationId)
      .eq("category", category.name);
    if (useError) throw new Error(useError.message);
    if (count) throw new Error("Category is in use and cannot be deleted.");
    const { error } = await context.supabase
      .from("inventory_categories")
      .delete()
      .eq("id", data.id);
    if (error) throw new Error(error.message);
    return { ok: true };
  });

// ---- Phase 7A.1: physical inventory locations (owner only; the RPCs re-check the role) ----

const locationName = z.string().trim().min(1).max(120);
const locationDescription = z.string().trim().max(500).optional().nullable();

export const createInventoryLocationFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({ organizationId: uuid, name: locationName, description: locationDescription })
      .parse(value),
  )
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: id, error } = await context.supabase.rpc("create_inventory_location", {
      _organization_id: data.organizationId,
      _name: data.name,
      _description: data.description || undefined,
    });
    if (error) throw new Error(error.message);
    return { id };
  });

export const updateInventoryLocationFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        inventoryLocationId: uuid,
        name: locationName,
        description: locationDescription,
      })
      .parse(value),
  )
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { error } = await context.supabase.rpc("update_inventory_location", {
      _organization_id: data.organizationId,
      _inventory_location_id: data.inventoryLocationId,
      _name: data.name,
      _description: data.description || undefined,
    });
    if (error) throw new Error(error.message);
    return { ok: true };
  });

export const setInventoryLocationActiveFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, inventoryLocationId: uuid, active: z.boolean() }).parse(value),
  )
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { error } = await context.supabase.rpc("set_inventory_location_active", {
      _organization_id: data.organizationId,
      _inventory_location_id: data.inventoryLocationId,
      _active: data.active,
    });
    if (error) throw new Error(error.message);
    return { ok: true };
  });

export const moveInventoryStockFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        inventoryItemId: uuid,
        fromInventoryLocationId: uuid,
        toInventoryLocationId: uuid,
        quantity: z.number().finite().positive(),
        requestKey: z.string().trim().min(1).max(200),
      })
      .parse(value),
  )
  .handler(async ({ data, context }) => {
    await assertOwner(context.supabase, context.userId, data.organizationId);
    const { data: result, error } = await context.supabase.rpc("move_inventory_stock", {
      _organization_id: data.organizationId,
      _inventory_item_id: data.inventoryItemId,
      _from_inventory_location_id: data.fromInventoryLocationId,
      _to_inventory_location_id: data.toInventoryLocationId,
      _quantity: data.quantity,
      _idempotency_key: data.requestKey,
    });
    if (error) throw new Error(error.message);
    const values = result as { transferId: string; replayed: boolean };
    return { transferId: values.transferId, replayed: values.replayed };
  });

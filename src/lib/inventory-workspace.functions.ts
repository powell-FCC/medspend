import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import {
  getWorkspaceItemBalances,
  getWorkspaceLocation,
  listAllWorkspaceLocations,
  listWorkspaceItemsPage,
  listWorkspaceLocationStockPage,
} from "@/inventory/workspace-reads";

// Phase 7B.1 Inventory workspace reads for owners and admins. The work lives in
// src/inventory/workspace-reads.ts: owner+admin database functions only, keyset paged.

const uuid = z.string().uuid();
const cursor = z
  .object({ name: z.string().max(200), id: uuid })
  .nullable()
  .default(null);
const statusFilter = z.enum(["active", "archived", "all"]);

export const listWorkspaceLocationsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, status: statusFilter.default("all") }).parse(value),
  )
  .handler(async ({ data, context }) => ({
    locations: await listAllWorkspaceLocations(context.supabase, data.organizationId, data.status),
  }));

export const getWorkspaceLocationFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, locationId: uuid }).parse(value),
  )
  .handler(({ data, context }) =>
    getWorkspaceLocation(context.supabase, data.organizationId, data.locationId),
  );

export const listWorkspaceLocationStockFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        locationId: uuid,
        cursor,
        limit: z.number().int().min(1).max(500).default(100),
      })
      .parse(value),
  )
  .handler(({ data, context }) => listWorkspaceLocationStockPage(context.supabase, data));

export const listWorkspaceItemsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        search: z.string().max(120).default(""),
        category: z.string().max(120).default(""),
        status: statusFilter.default("active"),
        lowStock: z.boolean().default(false),
        cursor,
        limit: z.number().int().min(1).max(500).default(100),
      })
      .parse(value),
  )
  .handler(({ data, context }) => listWorkspaceItemsPage(context.supabase, data));

export const getWorkspaceItemBalancesFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, inventoryItemId: uuid }).parse(value),
  )
  .handler(({ data, context }) =>
    getWorkspaceItemBalances(context.supabase, data.organizationId, data.inventoryItemId),
  );

// Categories are readable by every member through RLS today; the workspace only lists names.
export const listWorkspaceCategoriesFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: uuid }).parse(value))
  .handler(async ({ data, context }) => {
    const { data: rows, error } = await context.supabase
      .from("inventory_categories")
      .select("id, organization_id, name, created_at")
      .eq("organization_id", data.organizationId)
      .order("name");
    if (error) throw new Error(error.message);
    return (rows ?? []).map((row) => ({
      id: row.id,
      organizationId: row.organization_id,
      name: row.name,
      createdAt: row.created_at,
    }));
  });

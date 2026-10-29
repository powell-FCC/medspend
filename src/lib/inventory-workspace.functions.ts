import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import {
  getCountSession,
  getWorkspaceItemBalances,
  getWorkspaceLocation,
  listAllWorkspaceLocations,
  listAdjustmentHistoryPage,
  listCountHistoryPage,
  listTransferHistoryPage,
  listWorkspaceItemsPage,
  listWorkspaceLocationStockPage,
} from "@/inventory/workspace-reads";
import { adjustmentHistoryReasons } from "@/inventory/activity";

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

// Phase 7B.2 count history: read-only, owner+admin, filtered and keyset paged in the database.
export const listCountHistoryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        locationId: uuid.nullable().default(null),
        countedBy: uuid.nullable().default(null),
        changedOnly: z.boolean().default(false),
        submittedFrom: z.string().datetime({ offset: true }).nullable().default(null),
        submittedBefore: z.string().datetime({ offset: true }).nullable().default(null),
        cursor: z
          .object({ submittedAt: z.string().datetime({ offset: true }), id: uuid })
          .nullable()
          .default(null),
        limit: z.number().int().min(1).max(200).default(50),
      })
      .parse(value),
  )
  .handler(({ data, context }) => listCountHistoryPage(context.supabase, data));

export const getCountSessionFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, sessionId: uuid }).parse(value),
  )
  .handler(({ data, context }) =>
    getCountSession(context.supabase, data.organizationId, data.sessionId),
  );

// Phase 7B.3 inventory activity: read-only, owner+admin, filtered and keyset paged in the
// database.
const isoDateTime = z.string().datetime({ offset: true });
const activityInput = z.object({
  organizationId: uuid,
  locationId: uuid.nullable().default(null),
  itemId: uuid.nullable().default(null),
  createdBy: uuid.nullable().default(null),
  createdFrom: isoDateTime.nullable().default(null),
  createdBefore: isoDateTime.nullable().default(null),
  cursor: z.object({ createdAt: isoDateTime, id: uuid }).nullable().default(null),
  limit: z.number().int().min(1).max(200).default(50),
});

export const listTransferHistoryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => activityInput.parse(value))
  .handler(({ data, context }) => listTransferHistoryPage(context.supabase, data));

export const listAdjustmentHistoryFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    activityInput
      .extend({ reason: z.enum(adjustmentHistoryReasons).nullable().default(null) })
      .parse(value),
  )
  .handler(({ data, context }) => listAdjustmentHistoryPage(context.supabase, data));

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

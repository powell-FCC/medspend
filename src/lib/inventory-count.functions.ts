import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import type { CountPage, CountSummary, LabelResolution } from "@/inventory/count";

// Phase 7A.2 physical counts. Every call goes through a SECURITY DEFINER function that
// checks membership itself and returns staff-safe fields only; nothing here reads inventory
// tables directly. Owners additionally issue and revoke QR labels.

const uuid = z.string().uuid();
const token = z.string().regex(/^[A-Za-z0-9_-]{43}$/);

// Quantities travel as decimal strings: the database parses them exactly.
const countLine = z.object({
  inventoryItemId: uuid,
  observedVersion: z.number().int().positive(),
  countedQuantity: z
    .string()
    .trim()
    .regex(/^\d{1,10}(\.\d{1,6})?$/),
});

// A label token resolves for active members of its organization only. Anyone else (and any
// malformed token) gets the same bare 'unavailable'.
export const resolveCountLabelFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ token: z.string().max(200) }).parse(value))
  .handler(async ({ data, context }): Promise<LabelResolution> => {
    if (!token.safeParse(data.token).success) return { status: "unavailable" };
    const { data: result, error } = await context.supabase.rpc("resolve_inventory_count_label", {
      _token: data.token,
    });
    if (error) throw new Error(error.message);
    return result as unknown as LabelResolution;
  });

export const listCountableLocationsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: uuid }).parse(value))
  .handler(async ({ data, context }) => {
    const { data: rows, error } = await context.supabase.rpc("list_countable_inventory_locations", {
      _organization_id: data.organizationId,
    });
    if (error) throw new Error(error.message);
    return (rows ?? []).map((row) => ({
      id: row.inventory_location_id,
      name: row.name,
      lastCountedAt: row.last_counted_at,
    }));
  });

export const getCountLocationFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, locationId: uuid }).parse(value),
  )
  .handler(async ({ data, context }): Promise<CountPage> => {
    const { data: page, error } = await context.supabase.rpc("get_inventory_count_location", {
      _organization_id: data.organizationId,
      _inventory_location_id: data.locationId,
    });
    if (error) throw new Error(error.message);
    // Quantities arrive as exact decimal text (the function casts them).
    return page as unknown as CountPage;
  });

export const submitCountFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: uuid,
        locationId: uuid,
        lines: z.array(countLine).min(1).max(1000),
        requestKey: z.string().trim().min(1).max(200),
      })
      .parse(value),
  )
  .handler(async ({ data, context }): Promise<CountSummary> => {
    const { data: result, error } = await context.supabase.rpc("submit_inventory_count", {
      _organization_id: data.organizationId,
      _inventory_location_id: data.locationId,
      _lines: data.lines,
      _idempotency_key: data.requestKey,
    });
    if (error) throw new Error(error.message);
    return result as unknown as CountSummary;
  });

// Owners: QR labels.

export const listLocationCountStatusFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: uuid }).parse(value))
  .handler(async ({ data, context }) => {
    const { data: rows, error } = await context.supabase.rpc(
      "list_inventory_location_count_status",
      { _organization_id: data.organizationId },
    );
    if (error) throw new Error(error.message);
    return (rows ?? []).map((row) => ({
      locationId: row.inventory_location_id,
      activeLabelCount: row.active_label_count,
      lastLabelIssuedAt: row.last_label_issued_at,
      lastCountedAt: row.last_counted_at,
    }));
  });

export const issueLocationLabelFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, locationId: uuid }).parse(value),
  )
  .handler(async ({ data, context }) => {
    const { data: result, error } = await context.supabase.rpc("issue_inventory_location_label", {
      _organization_id: data.organizationId,
      _inventory_location_id: data.locationId,
    });
    if (error) throw new Error(error.message);
    return result as unknown as {
      labelId: string;
      token: string;
      issuedAt: string;
      locationId: string;
      locationName: string;
    };
  });

export const revokeLocationLabelsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z.object({ organizationId: uuid, locationId: uuid }).parse(value),
  )
  .handler(async ({ data, context }) => {
    const { data: revoked, error } = await context.supabase.rpc(
      "revoke_inventory_location_labels",
      { _organization_id: data.organizationId, _inventory_location_id: data.locationId },
    );
    if (error) throw new Error(error.message);
    return { revoked: revoked ?? 0 };
  });

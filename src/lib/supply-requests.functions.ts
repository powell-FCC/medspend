import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

const requestTypeEnum = z.enum(["reorder", "low_stock", "out_of_stock", "new_item"]);
const statusEnum = z.enum([
  "submitted",
  "under_review",
  "approved",
  "ordered",
  "received",
  "completed",
  "denied",
]);

// Staff submit: organization_id is DERIVED server-side from the caller's active membership.
export const submitSupplyRequestFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        organizationId: z.string().uuid(), // asserted, then re-verified server side
        requestType: requestTypeEnum,
        productId: z.string().uuid().optional().nullable(),
        freeTextItem: z.string().optional().nullable(),
        quantity: z.number().positive().optional().nullable(),
        teamId: z.string().uuid().optional().nullable(),
        locationId: z.string().uuid().optional().nullable(),
        notes: z.string().optional().nullable(),
      })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    // Verify caller has an active membership in the claimed org.
    const { data: mem, error: memErr } = await context.supabase
      .from("organization_memberships")
      .select("organization_id, role")
      .eq("user_id", context.userId)
      .eq("organization_id", data.organizationId)
      .eq("active", true)
      .maybeSingle();
    if (memErr) throw new Error(memErr.message);
    if (!mem) throw new Error("Not a member of this organization");

    if (!data.productId && !data.freeTextItem?.trim()) {
      throw new Error("Product or free-text item required");
    }

    const { data: row, error } = await context.supabase
      .from("supply_requests")
      .insert({
        organization_id: mem.organization_id, // derived from membership, never client-trusted directly
        requested_by: context.userId,
        request_type: data.requestType,
        product_id: data.productId ?? null,
        free_text_item: data.freeTextItem ?? null,
        quantity: data.quantity ?? null,
        team_id: data.teamId ?? null,
        location_id: data.locationId ?? null,
        notes: data.notes ?? null,
        status: "submitted",
      })
      .select("id")
      .single();
    if (error) throw new Error(error.message);
    return { id: row.id };
  });

export const listMyRequestsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    const { data: rows, error } = await context.supabase
      .from("supply_requests")
      .select(
        "id, request_type, quantity, status, notes, free_text_item, product_id, ordered_at, received_at, created_at, products(name)",
      )
      .eq("organization_id", data.organizationId)
      .eq("requested_by", context.userId)
      .order("created_at", { ascending: false });
    if (error) throw new Error(error.message);
    return (rows ?? []).map((r) => ({
      id: r.id,
      requestType: r.request_type,
      quantity: r.quantity,
      status: r.status,
      notes: r.notes,
      itemName: (r.products as { name: string } | null)?.name ?? r.free_text_item ?? "—",
      orderedAt: r.ordered_at,
      receivedAt: r.received_at,
      createdAt: r.created_at,
    }));
  });

export const listOrgRequestsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    const { data: rows, error } = await context.supabase
      .from("supply_requests")
      .select(
        "id, request_type, quantity, status, notes, free_text_item, requested_by, ordered_at, received_at, created_at, products(name)",
      )
      .eq("organization_id", data.organizationId)
      .order("created_at", { ascending: false });
    if (error) throw new Error(error.message);
    const ids = Array.from(new Set((rows ?? []).map((r) => r.requested_by)));
    const profileMap: Record<string, { full_name: string | null; email: string | null }> = {};
    if (ids.length) {
      const { data: p } = await context.supabase.from("profiles").select("id, full_name, email").in("id", ids);
      for (const x of p ?? []) profileMap[x.id] = { full_name: x.full_name, email: x.email };
    }
    return (rows ?? []).map((r) => ({
      id: r.id,
      requestType: r.request_type,
      quantity: r.quantity,
      status: r.status,
      notes: r.notes,
      itemName: (r.products as { name: string } | null)?.name ?? r.free_text_item ?? "—",
      requestedBy:
        profileMap[r.requested_by]?.full_name ?? profileMap[r.requested_by]?.email ?? "—",
      orderedAt: r.ordered_at,
      receivedAt: r.received_at,
      createdAt: r.created_at,
    }));
  });

export const updateRequestStatusFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        id: z.string().uuid(),
        status: statusEnum,
        internalNote: z.string().optional().nullable(),
        staffVisibleNote: z.string().optional().nullable(),
        orderedAt: z.string().datetime().optional().nullable(),
        receivedAt: z.string().datetime().optional().nullable(),
      })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    // Get current for org + status
    const { data: cur, error: getErr } = await context.supabase
      .from("supply_requests")
      .select("organization_id, status")
      .eq("id", data.id)
      .single();
    if (getErr) throw new Error(getErr.message);

    const patch: {
      status: typeof data.status;
      ordered_at?: string | null;
      received_at?: string | null;
    } = { status: data.status };
    if (data.orderedAt !== undefined) patch.ordered_at = data.orderedAt;
    if (data.receivedAt !== undefined) patch.received_at = data.receivedAt;

    const { error: upErr } = await context.supabase
      .from("supply_requests")
      .update(patch)
      .eq("id", data.id);
    if (upErr) throw new Error(upErr.message);

    if (data.internalNote || data.staffVisibleNote || cur.status !== data.status) {
      const { error: insErr } = await context.supabase.from("supply_request_updates").insert({
        organization_id: cur.organization_id,
        supply_request_id: data.id,
        author_id: context.userId,
        status_from: cur.status,
        status_to: data.status,
        internal_note: data.internalNote ?? null,
        staff_visible_note: data.staffVisibleNote ?? null,
      });
      if (insErr) throw new Error(insErr.message);
    }
    return { ok: true };
  });

export const listRequestUpdatesFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ requestId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    const { data: rows, error } = await context.supabase
      .from("supply_request_updates")
      .select("id, status_from, status_to, internal_note, staff_visible_note, created_at")
      .eq("supply_request_id", data.requestId)
      .order("created_at", { ascending: true });
    if (error) throw new Error(error.message);
    return rows ?? [];
  });

export const searchProductsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: z.string().uuid(), q: z.string().max(80) }).parse(d),
  )
  .handler(async ({ data, context }) => {
    if (!data.q.trim()) return [] as { id: string; name: string; unit: string | null }[];
    const { data: rows, error } = await context.supabase
      .from("products")
      .select("id, name, unit")
      .eq("organization_id", data.organizationId)
      .ilike("name", `%${data.q}%`)
      .limit(20);
    if (error) throw new Error(error.message);
    return rows ?? [];
  });
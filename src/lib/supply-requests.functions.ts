import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import { SUPPLY_REQUEST_STATUSES } from "@/supply-requests/lifecycle";
import type { SupplyRequestStatus } from "@/supply-requests/lifecycle";
import { multiItemSupplyRequestInputSchema } from "@/supply-requests/validation";
import {
  summarizeStaffRequests,
  translateStaffRequestStatus,
  type StaffRequestViewModel,
  type StaffRequestDetailViewModel,
  type SupplyRequestItemViewModel,
  summarizeRequestItems,
} from "@/supply-requests/staff-dashboard";
import {
  buildAdminRequestDashboard,
  requestAgeInDays,
  translateAdminRequestStatus,
  translateAdminRequestType,
  type AdminSupplyRequestViewModel,
} from "@/supply-requests/admin-dashboard";

const statusEnum = z.enum(SUPPLY_REQUEST_STATUSES);

async function requireMembership(context: { supabase: any; userId: string }, organizationId: string) {
  const { data, error } = await context.supabase.from("organization_memberships")
    .select("organization_id, role, default_team_id, default_location_id").eq("user_id", context.userId)
    .eq("organization_id", organizationId).eq("active", true).maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error("Not a member of this organization");
  return data as { organization_id: string; role: "owner" | "admin" | "staff"; default_team_id: string | null; default_location_id: string | null };
}

async function requireAdmin(context: { supabase: any; userId: string }, organizationId: string) {
  const membership = await requireMembership(context, organizationId);
  if (!["owner", "admin"].includes(membership.role)) throw new Error("Forbidden: administrator access required");
  return membership;
}

async function requireRelatedRecord(
  context: { supabase: any }, table: "products" | "teams" | "locations",
  id: string | null | undefined, organizationId: string,
) {
  if (!id) return;
  let query = context.supabase.from(table).select("id").eq("id", id)
    .eq("organization_id", organizationId).eq("active", true);
  if (table === "products") query = query.eq("staff_requestable", true);
  const { data, error } = await query.maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error(`Selected ${table.slice(0, -1)} is unavailable for this organization`);
}

async function loadRequestItems(
  db: any,
  organizationId: string,
  requests: Array<{ id: string; product_id: string | null; free_text_item: string | null; quantity: number | null; products?: unknown }>,
) {
  const requestIds = requests.map((request) => request.id);
  const byRequest = new Map<string, SupplyRequestItemViewModel[]>();
  if (requestIds.length) {
    const { data, error } = await db.from("supply_request_items")
      .select("id,supply_request_id,product_id,free_text_item,quantity,unit,products(name,unit_of_measure)")
      .eq("organization_id", organizationId).in("supply_request_id", requestIds)
      .order("created_at", { ascending: true });
    if (error) throw new Error(error.message);
    for (const row of data ?? []) {
      const product = row.products as { name: string; unit_of_measure: string | null } | null;
      const items = byRequest.get(row.supply_request_id) ?? [];
      items.push({ id: row.id, productId: row.product_id, name: product?.name ?? row.free_text_item ?? "Requested item", quantity: row.quantity, unit: row.unit ?? product?.unit_of_measure ?? null });
      byRequest.set(row.supply_request_id, items);
    }
  }
  for (const request of requests) {
    if (byRequest.has(request.id)) continue;
    const product = request.products as { name: string; unit_of_measure: string | null } | null;
    if (request.product_id || request.free_text_item) {
      byRequest.set(request.id, [{ id: `legacy:${request.id}`, productId: request.product_id, name: product?.name ?? request.free_text_item ?? "Requested item", quantity: request.quantity ?? 1, unit: product?.unit_of_measure ?? null }]);
    } else byRequest.set(request.id, []);
  }
  return byRequest;
}

// Staff submit: organization_id is DERIVED server-side from the caller's active membership.
export const submitSupplyRequestFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    multiItemSupplyRequestInputSchema.parse(d),
  )
  .handler(async ({ data, context }) => {
    await requireMembership(context, data.organizationId);
    const { data: requestId, error } = await (context.supabase as any).rpc("submit_supply_request", {
      _organization_id: data.organizationId,
      _request_type: data.requestType,
      _team_id: data.teamId ?? null,
      _location_id: data.locationId ?? null,
      _notes: data.notes?.trim() || null,
      _items: data.items.map((item) => ({ productId: item.productId ?? null, freeTextItem: item.productId ? null : item.freeTextItem?.trim(), quantity: item.quantity })),
    });
    if (error) throw new Error(error.message);
    return { id: requestId as string };
  });

export const listMyRequestsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    await requireMembership(context, data.organizationId);
    const { data: rows, error } = await context.supabase
      .from("supply_requests")
      .select(
        "id, request_type, quantity, status, notes, free_text_item, product_id, ordered_at, received_at, created_at, updated_at, products(name)",
      )
      .eq("organization_id", data.organizationId)
      .eq("requested_by", context.userId)
      .order("created_at", { ascending: false });
    if (error) throw new Error(error.message);
    const ids = (rows ?? []).map((row) => row.id);
    const itemsByRequest = await loadRequestItems(context.supabase, data.organizationId, rows ?? []);
    const latestVisibleUpdates = new Map<string, { note: string; status: SupplyRequestStatus | null; createdAt: string }>();
    if (ids.length) {
      const { data: updates, error: updatesError } = await context.supabase.from("supply_request_updates")
        .select("supply_request_id,status_to,staff_visible_note,created_at")
        .in("supply_request_id", ids).not("staff_visible_note", "is", null)
        .order("created_at", { ascending: false });
      if (updatesError) throw new Error(updatesError.message);
      for (const update of updates ?? []) {
        if (!latestVisibleUpdates.has(update.supply_request_id) && update.staff_visible_note) {
          latestVisibleUpdates.set(update.supply_request_id, {
            note: update.staff_visible_note,
            status: update.status_to as SupplyRequestStatus | null,
            createdAt: update.created_at,
          });
        }
      }
    }
    return (rows ?? []).map((r) => {
      const items = itemsByRequest.get(r.id) ?? [];
      const first = items[0];
      return ({
      id: r.id,
      requestType: r.request_type,
      quantity: items.length === 1 ? first?.quantity ?? r.quantity : null,
      status: r.status,
      notes: r.notes,
      itemCount: items.length,
      items,
      itemName: summarizeRequestItems(items) || (r.products as { name: string } | null)?.name || r.free_text_item || "—",
      orderedAt: r.ordered_at,
      receivedAt: r.received_at,
      createdAt: r.created_at,
      latestStaffVisibleNote: latestVisibleUpdates.get(r.id)?.note ?? null,
      latestStatusChange: r.status,
      latestUpdateAt: r.updated_at,
    }); });
  });

export const getStaffDashboardFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    await requireMembership(context, data.organizationId);
    const { data: rows, error } = await context.supabase
      .from("supply_requests")
      .select("id,product_id,quantity,status,free_text_item,created_at,updated_at,products(name,unit_of_measure)")
      .eq("organization_id", data.organizationId)
      .eq("requested_by", context.userId)
      .order("created_at", { ascending: false });
    if (error) throw new Error(error.message);
    const ids = (rows ?? []).map((row) => row.id);
    const itemsByRequest = await loadRequestItems(context.supabase, data.organizationId, rows ?? []);
    const latestMessages = new Map<string, { message: string; createdAt: string }>();
    if (ids.length) {
      const { data: updates, error: updatesError } = await context.supabase
        .from("supply_request_updates")
        .select("supply_request_id,staff_visible_note,created_at")
        .eq("organization_id", data.organizationId)
        .in("supply_request_id", ids)
        .not("staff_visible_note", "is", null)
        .order("created_at", { ascending: false });
      if (updatesError) throw new Error(updatesError.message);
      for (const update of updates ?? []) {
        if (!latestMessages.has(update.supply_request_id) && update.staff_visible_note) {
          latestMessages.set(update.supply_request_id, {
            message: update.staff_visible_note,
            createdAt: update.created_at,
          });
        }
      }
    }

    const recentRequests: StaffRequestViewModel[] = (rows ?? []).map((row) => {
      const status = translateStaffRequestStatus(row.status as SupplyRequestStatus);
      const product = row.products as { name: string; unit_of_measure: string | null } | null;
      const message = latestMessages.get(row.id);
      const items = itemsByRequest.get(row.id) ?? [];
      const first = items[0];
      return {
        id: row.id,
        itemCount: items.length,
        items,
        itemName: summarizeRequestItems(items) || product?.name || row.free_text_item || "Requested item",
        quantity: items.length === 1 ? first?.quantity ?? row.quantity : null,
        unit: items.length === 1 ? first?.unit ?? product?.unit_of_measure ?? null : null,
        statusLabel: status.label,
        statusGroup: status.group,
        submittedAt: row.created_at,
        lastUpdatedAt:
          message && message.createdAt > row.updated_at ? message.createdAt : row.updated_at,
        staffMessage: message?.message ?? null,
      };
    });

    return {
      summary: summarizeStaffRequests(recentRequests),
      recentRequests,
      attentionItems: recentRequests.filter((request) => request.statusGroup === "ACTION_REQUIRED"),
    };
  });

export const getStaffRequestDetailFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: z.string().uuid(), requestId: z.string().uuid() }).parse(d),
  )
  .handler(async ({ data, context }) => {
    await requireMembership(context, data.organizationId);
    const { data: row, error } = await context.supabase
      .from("supply_requests")
      .select("id,product_id,quantity,status,free_text_item,created_at,updated_at,products(name,unit_of_measure)")
      .eq("id", data.requestId)
      .eq("organization_id", data.organizationId)
      .eq("requested_by", context.userId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    if (!row) throw new Error("Request not found");

    const { data: updates, error: updatesError } = await context.supabase
      .from("supply_request_updates")
      .select("status_to,staff_visible_note,created_at")
      .eq("organization_id", data.organizationId)
      .eq("supply_request_id", row.id)
      .order("created_at", { ascending: true });
    if (updatesError) throw new Error(updatesError.message);

    const visibleUpdates = updates ?? [];
    const latestMessage = [...visibleUpdates].reverse().find((update) => update.staff_visible_note);
    const product = row.products as { name: string; unit_of_measure: string | null } | null;
    const items = (await loadRequestItems(context.supabase, data.organizationId, [row])).get(row.id) ?? [];
    const first = items[0];
    const status = translateStaffRequestStatus(row.status as SupplyRequestStatus);
    const detail: StaffRequestDetailViewModel = {
      id: row.id,
      itemCount: items.length,
      items,
      itemName: summarizeRequestItems(items) || product?.name || row.free_text_item || "Requested item",
      quantity: items.length === 1 ? first?.quantity ?? row.quantity : null,
      unit: items.length === 1 ? first?.unit ?? product?.unit_of_measure ?? null : null,
      statusLabel: status.label,
      statusGroup: status.group,
      submittedAt: row.created_at,
      lastUpdatedAt: row.updated_at,
      staffMessage: latestMessage?.staff_visible_note ?? null,
      timeline: [
        { label: "Requested", occurredAt: row.created_at, message: null },
        ...visibleUpdates.flatMap((update) => {
          if (!update.status_to) return [];
          const translated = translateStaffRequestStatus(update.status_to as SupplyRequestStatus);
          return [{
            label: translated.label,
            occurredAt: update.created_at,
            message: update.staff_visible_note,
          }];
        }),
      ],
    };
    return detail;
  });

export const listOrgRequestsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    await requireAdmin(context, data.organizationId);
    const { data: rows, error } = await context.supabase
      .from("supply_requests")
      .select(
        "id, request_type, product_id, quantity, status, notes, free_text_item, requested_by, ordered_at, received_at, created_at, products(name,unit_of_measure)",
      )
      .eq("organization_id", data.organizationId)
      .order("created_at", { ascending: false });
    if (error) throw new Error(error.message);
    const itemsByRequest = await loadRequestItems(context.supabase, data.organizationId, rows ?? []);
    const ids = Array.from(new Set((rows ?? []).map((r) => r.requested_by)));
    const profileMap: Record<string, { full_name: string | null; email: string | null }> = {};
    if (ids.length) {
      const { data: p } = await context.supabase.from("profiles").select("id, full_name, email").in("id", ids);
      for (const x of p ?? []) profileMap[x.id] = { full_name: x.full_name, email: x.email };
    }
    return (rows ?? []).map((r) => {
      const items = itemsByRequest.get(r.id) ?? [];
      const first = items[0];
      return ({
      id: r.id,
      requestType: r.request_type,
      quantity: items.length === 1 ? first?.quantity ?? r.quantity : null,
      status: r.status,
      notes: r.notes,
      itemCount: items.length,
      items,
      itemName: summarizeRequestItems(items) || (r.products as { name: string } | null)?.name || r.free_text_item || "—",
      requestedBy:
        profileMap[r.requested_by]?.full_name ?? profileMap[r.requested_by]?.email ?? "—",
      orderedAt: r.ordered_at,
      receivedAt: r.received_at,
      createdAt: r.created_at,
    }); });
  });

export const getAdminSupplyRequestDashboardFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    await requireAdmin(context, data.organizationId);
    const { data: rows, error } = await context.supabase
      .from("supply_requests")
      .select(
        "id,request_type,quantity,status,notes,free_text_item,requested_by,product_id,created_at,updated_at,products(name,unit_of_measure),teams(name),locations(name)",
      )
      .eq("organization_id", data.organizationId)
      .order("created_at", { ascending: false });
    if (error) throw new Error(error.message);

    const requestIds = (rows ?? []).map((row) => row.id);
    const itemsByRequest = await loadRequestItems(context.supabase, data.organizationId, rows ?? []);
    const requesterIds = Array.from(new Set((rows ?? []).map((row) => row.requested_by)));
    const [identitiesResult, updatesResult] = await Promise.all([
      requesterIds.length
        ? context.supabase.rpc("list_organization_member_identities", { _organization_id: data.organizationId })
        : Promise.resolve({ data: [], error: null }),
      requestIds.length
        ? context.supabase.from("supply_request_updates")
          .select("supply_request_id,internal_note,staff_visible_note,created_at")
          .eq("organization_id", data.organizationId)
          .in("supply_request_id", requestIds)
          .order("created_at", { ascending: false })
        : Promise.resolve({ data: [], error: null }),
    ]);
    if (identitiesResult.error) throw new Error(identitiesResult.error.message);
    if (updatesResult.error) throw new Error(updatesResult.error.message);

    const identities = new Map(
      (identitiesResult.data ?? []).map((identity) => [identity.user_id, identity]),
    );
    const updateInfo = new Map<string, {
      latestStaffMessage: string | null;
      latestInternalNote: string | null;
      latestUpdateAt: string | null;
    }>();
    for (const update of updatesResult.data ?? []) {
      const current = updateInfo.get(update.supply_request_id) ?? {
        latestStaffMessage: null,
        latestInternalNote: null,
        latestUpdateAt: null,
      };
      if (!current.latestUpdateAt) current.latestUpdateAt = update.created_at;
      if (!current.latestStaffMessage && update.staff_visible_note) {
        current.latestStaffMessage = update.staff_visible_note;
      }
      if (!current.latestInternalNote && update.internal_note) {
        current.latestInternalNote = update.internal_note;
      }
      updateInfo.set(update.supply_request_id, current);
    }

    const now = new Date();
    const requests: AdminSupplyRequestViewModel[] = (rows ?? []).map((row) => {
      const lifecycleStatus = row.status as SupplyRequestStatus;
      const translation = translateAdminRequestStatus(lifecycleStatus);
      const product = row.products as { name: string; unit_of_measure: string | null } | null;
      const team = row.teams as { name: string } | null;
      const location = row.locations as { name: string } | null;
      const updates = updateInfo.get(row.id);
      const requesterIdentity = identities.get(row.requested_by);
      const items = itemsByRequest.get(row.id) ?? [];
      const first = items[0];
      return {
        id: row.id,
        itemCount: items.length,
        items,
        itemName: summarizeRequestItems(items) || product?.name || row.free_text_item || "Requested item",
        quantity: items.length === 1 ? first?.quantity ?? row.quantity : null,
        unit: items.length === 1 ? first?.unit ?? product?.unit_of_measure ?? null : null,
        requesterName: requesterIdentity?.display_name ?? `Member ${row.requested_by.slice(0, 8)}`,
        requesterEmail: requesterIdentity?.email ?? null,
        team: team?.name ?? requesterIdentity?.default_team_name ?? null,
        location: location?.name ?? requesterIdentity?.default_location_name ?? null,
        requestTypeLabel: translateAdminRequestType(row.request_type),
        queueGroup: translation.queueGroup,
        statusLabel: translation.statusLabel,
        nextAction: translation.nextAction,
        lifecycleStatus,
        submittedAt: row.created_at,
        updatedAt: row.updated_at,
        ageInDays: requestAgeInDays(row.created_at, now),
        staffNote: row.notes,
        latestStaffMessage: updates?.latestStaffMessage ?? null,
        latestInternalNote: updates?.latestInternalNote ?? null,
        latestUpdateAt: updates?.latestUpdateAt ?? row.updated_at,
        hasExistingProduct: items.some((item) => !!item.productId),
        isNewItem: items.some((item) => !item.productId),
      };
    });
    return buildAdminRequestDashboard(requests);
  });

export const updateRequestStatusFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        organizationId: z.string().uuid(),
        id: z.string().uuid(),
        status: statusEnum,
        internalNote: z.string().optional().nullable(),
        staffVisibleNote: z.string().optional().nullable(),
      })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    await requireAdmin(context, data.organizationId);
    const internalNote = data.internalNote?.trim();
    const staffVisibleNote = data.staffVisibleNote?.trim();
    const { data: result, error } = await context.supabase.rpc("transition_supply_request", {
      _organization_id: data.organizationId,
      _request_id: data.id,
      _status: data.status,
      ...(internalNote ? { _internal_note: internalNote } : {}),
      ...(staffVisibleNote ? { _staff_visible_note: staffVisibleNote } : {}),
    });
    if (error) throw new Error(error.message);
    return result;
  });

export const listRequestUpdatesFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ requestId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    const { data: request, error: requestError } = await context.supabase.from("supply_requests")
      .select("organization_id,requested_by").eq("id", data.requestId).single();
    if (requestError) throw new Error(requestError.message);
    const membership = await requireMembership(context, request.organization_id);
    const isAdmin = membership.role === "owner" || membership.role === "admin";
    if (!isAdmin && request.requested_by !== context.userId) throw new Error("Forbidden");
    let query = context.supabase.from("supply_request_updates")
      .select("id,status_from,status_to,internal_note,staff_visible_note,created_at")
      .eq("organization_id", request.organization_id).eq("supply_request_id", data.requestId)
      .order("created_at", { ascending: true });
    if (!isAdmin) query = query.not("staff_visible_note", "is", null);
    const { data: rows, error } = await query;
    if (error) throw new Error(error.message);
    return (rows ?? []).map((row) => ({
      id: row.id,
      statusFrom: row.status_from,
      statusTo: row.status_to,
      staffVisibleNote: row.staff_visible_note,
      internalNote: isAdmin ? row.internal_note : undefined,
      createdAt: row.created_at,
    }));
  });

export const searchProductsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z.object({ organizationId: z.string().uuid(), q: z.string().max(80) }).parse(d),
  )
  .handler(async ({ data, context }) => {
    if (!data.q.trim()) return [] as { id: string; name: string; unit: string | null }[];
    const db = context.supabase as any;
    const term = data.q.trim().replaceAll(",", "");
    const { data: aliases, error: aliasError } = await db
      .from("product_aliases")
      .select("product_id, alias")
      .eq("organization_id", data.organizationId)
      .ilike("normalized_alias", `%${term}%`)
      .limit(20);
    if (aliasError) throw new Error(aliasError.message);
    const aliasProductIds = (aliases ?? []).map((row: any) => row.product_id);
    const search = ["name", "normalized_name", "manufacturer", "description", "vendor_item_number", "internal_item_code"]
      .map((column) => `${column}.ilike.%${term}%`);
    if (aliasProductIds.length) search.push(`id.in.(${aliasProductIds.join(",")})`);
    const { data: rows, error } = await db
      .from("products")
      .select("id, name, unit_of_measure")
      .eq("organization_id", data.organizationId)
      .eq("active", true)
      .eq("staff_requestable", true)
      .or(search.join(","))
      .limit(20);
    if (error) throw new Error(error.message);
    return (rows ?? []).map((row: any) => ({ id: row.id, name: row.name, unit: row.unit_of_measure }));
  });

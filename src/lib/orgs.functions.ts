import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

export const createOrganizationFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ name: z.string().min(1).max(120) }).parse(d))
  .handler(async ({ data, context }) => {
    const { data: orgId, error } = await context.supabase.rpc("create_organization", { _name: data.name });
    if (error) throw new Error(error.message);
    return { organizationId: orgId as unknown as string };
  });

export const createInvitationFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        organizationId: z.string().uuid(),
        email: z.string().email(),
        name: z.string().optional().nullable(),
        role: z.enum(["owner", "admin", "staff"]).default("staff"),
        defaultTeamId: z.string().uuid().optional().nullable(),
        defaultLocationId: z.string().uuid().optional().nullable(),
      })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    const { data: token, error } = await context.supabase.rpc("create_invitation", {
      _organization_id: data.organizationId,
      _invited_email: data.email,
      _invited_name: (data.name ?? null) as string,
      _invited_role: data.role,
      _default_team_id: (data.defaultTeamId ?? null) as string,
      _default_location_id: (data.defaultLocationId ?? null) as string,
    });
    if (error) throw new Error(error.message);
    return { token: token as unknown as string };
  });

export const acceptInvitationFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ token: z.string().min(16) }).parse(d))
  .handler(async ({ data, context }) => {
    const { data: rows, error } = await context.supabase.rpc("accept_invitation", { _raw_token: data.token });
    if (error) throw new Error(error.message);
    const row = Array.isArray(rows) ? rows[0] : rows;
    if (!row) throw new Error("no result");
    return {
      organizationId: row.organization_id as string,
      role: row.role as "owner" | "admin" | "staff",
      route: row.route as string,
    };
  });

export const revokeInvitationFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ id: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    const { error } = await context.supabase.rpc("revoke_invitation", { _id: data.id });
    if (error) throw new Error(error.message);
    return { ok: true };
  });

// Return active memberships joined with org name — canonical role source.
export const listMyMembershipsFn = createServerFn({ method: "GET" })
  .middleware([requireSupabaseAuth])
  .handler(async ({ context }) => {
    const { data, error } = await context.supabase
      .from("organization_memberships")
      .select(
        "id, organization_id, role, active, default_team_id, default_location_id, organizations(name)",
      )
      .eq("user_id", context.userId)
      .eq("active", true);
    if (error) throw new Error(error.message);
    return (data ?? []).map((m) => ({
      id: m.id,
      organizationId: m.organization_id,
      role: m.role as "owner" | "admin" | "staff",
      defaultTeamId: m.default_team_id,
      defaultLocationId: m.default_location_id,
      organizationName: (m.organizations as { name: string } | null)?.name ?? "",
    }));
  });

export const listOrgInvitesFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    const { data: rows, error } = await context.supabase
      .from("organization_invites")
      .select("id, invited_email, invited_name, invited_role, expires_at, accepted_at, revoked_at, created_at")
      .eq("organization_id", data.organizationId)
      .order("created_at", { ascending: false });
    if (error) throw new Error(error.message);
    return rows ?? [];
  });

export const listOrgMembersFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) => z.object({ organizationId: z.string().uuid() }).parse(d))
  .handler(async ({ data, context }) => {
    const { data: rows, error } = await context.supabase
      .from("organization_memberships")
      .select("id, user_id, role, active, joined_at")
      .eq("organization_id", data.organizationId);
    if (error) throw new Error(error.message);
    const { data: identities, error: identityError } = await context.supabase
      .rpc("list_organization_member_identities", { _organization_id: data.organizationId });
    if (identityError) throw new Error(identityError.message);
    const identityByUser = new Map((identities ?? []).map((identity) => [identity.user_id, identity]));
    return (rows ?? []).map((r) => ({
      id: r.id,
      userId: r.user_id,
      role: r.role,
      active: r.active,
      joinedAt: r.joined_at,
      fullName: identityByUser.get(r.user_id)?.display_name ?? `Member ${r.user_id.slice(0, 8)}`,
      email: identityByUser.get(r.user_id)?.email ?? null,
    }));
  });

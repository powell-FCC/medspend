import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";

const kindEnum = z.enum(["teams", "locations"]);

async function assertMember(
  supabase: { from: (t: string) => any },
  userId: string,
  organizationId: string,
) {
  const { data, error } = await supabase
    .from("organization_memberships")
    .select("role")
    .eq("user_id", userId)
    .eq("organization_id", organizationId)
    .eq("active", true)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) throw new Error("Not a member of this organization");
  return data.role as "owner" | "admin" | "staff";
}

export const listOrgStructureFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({ organizationId: z.string().uuid(), includeArchived: z.boolean().default(false) })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    await assertMember(context.supabase as never, context.userId, data.organizationId);
    const pull = async (table: "teams" | "locations") => {
      let q = context.supabase
        .from(table)
        .select("id, name, active, created_at")
        .eq("organization_id", data.organizationId)
        .order("name", { ascending: true });
      if (!data.includeArchived) q = q.eq("active", true);
      const { data: rows, error } = await q;
      if (error) throw new Error(error.message);
      return rows ?? [];
    };
    return { teams: await pull("teams"), locations: await pull("locations") };
  });

export const createOrgStructureFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({ organizationId: z.string().uuid(), kind: kindEnum, name: z.string().min(1).max(120) })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    const role = await assertMember(context.supabase as never, context.userId, data.organizationId);
    if (role !== "owner" && role !== "admin") throw new Error("Forbidden");
    const { data: row, error } = await context.supabase
      .from(data.kind)
      .insert({ organization_id: data.organizationId, name: data.name.trim() })
      .select("id")
      .single();
    if (error) throw new Error(error.message);
    return { id: row.id as string };
  });

export const updateOrgStructureFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((d: unknown) =>
    z
      .object({
        organizationId: z.string().uuid(),
        kind: kindEnum,
        id: z.string().uuid(),
        name: z.string().min(1).max(120).optional(),
        active: z.boolean().optional(),
      })
      .parse(d),
  )
  .handler(async ({ data, context }) => {
    const role = await assertMember(context.supabase as never, context.userId, data.organizationId);
    if (role !== "owner" && role !== "admin") throw new Error("Forbidden");
    const patch: { name?: string; active?: boolean } = {};
    if (data.name !== undefined) patch.name = data.name.trim();
    if (data.active !== undefined) patch.active = data.active;
    if (!Object.keys(patch).length) return { ok: true };
    const { error } = await context.supabase
      .from(data.kind)
      .update(patch)
      .eq("id", data.id)
      .eq("organization_id", data.organizationId);
    if (error) throw new Error(error.message);
    return { ok: true };
  });

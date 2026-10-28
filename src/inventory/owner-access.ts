import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/integrations/supabase/types";

// Every inventory mutation is owner-only here, in the server function, and again inside its
// database function. Admins read the Inventory workspace but never pass this check.
export async function assertInventoryOwner(
  db: SupabaseClient<Database>,
  userId: string,
  organizationId: string,
) {
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

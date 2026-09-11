import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/integrations/supabase/types";

export async function requireOrganizationAdmin(
  supabase: SupabaseClient<Database>,
  userId: string,
  organizationId: string,
) {
  const { data, error } = await supabase
    .from("organization_memberships")
    .select("role")
    .eq("organization_id", organizationId)
    .eq("user_id", userId)
    .eq("active", true)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data || (data.role !== "owner" && data.role !== "admin")) throw new Error("Forbidden");
  return data.role;
}

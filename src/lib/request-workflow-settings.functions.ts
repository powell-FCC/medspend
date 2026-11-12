import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import {
  REQUEST_WORKFLOW_PROFILES,
  parseRequestWorkflowSettings,
  type OrganizationRequestWorkflowSettings,
} from "@/supply-requests/workflow-profiles";

// Phase 7C.0: the organization's request workflow profile (Admin Settings). Both functions run as
// the signed-in user; the database functions check administrative authority (is_org_admin).

export const getRequestWorkflowSettingsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: z.string().uuid() }).parse(value))
  .handler(async ({ data, context }): Promise<OrganizationRequestWorkflowSettings> => {
    const { data: result, error } = await context.supabase.rpc(
      "get_organization_request_workflow_settings",
      { _organization_id: data.organizationId },
    );
    if (error) throw new Error(error.message);
    return parseRequestWorkflowSettings(result);
  });

export const updateRequestWorkflowSettingsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: z.string().uuid(),
        workflowProfile: z.enum(REQUEST_WORKFLOW_PROFILES),
      })
      .parse(value),
  )
  .handler(async ({ data, context }): Promise<OrganizationRequestWorkflowSettings> => {
    const { data: result, error } = await context.supabase.rpc(
      "update_organization_request_workflow_settings",
      { _organization_id: data.organizationId, _workflow_profile: data.workflowProfile },
    );
    if (error) throw new Error(error.message);
    return parseRequestWorkflowSettings(result);
  });

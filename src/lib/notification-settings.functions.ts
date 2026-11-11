import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { requireSupabaseAuth } from "@/integrations/supabase/auth-middleware";
import {
  SUPPORTED_TIMEZONE_VALUES,
  parseNotificationSettings,
  type OrganizationNotificationSettings,
} from "@/notifications/settings";

// Phase 6C.3: the organization's approver digest preference. Both functions run as the signed-in
// user; the database functions check administrative authority (is_org_admin) themselves, and the
// master sending switch is not editable here.

export const getNotificationSettingsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) => z.object({ organizationId: z.string().uuid() }).parse(value))
  .handler(async ({ data, context }): Promise<OrganizationNotificationSettings> => {
    const { data: result, error } = await context.supabase.rpc(
      "get_organization_notification_settings",
      {
        _organization_id: data.organizationId,
      },
    );
    if (error) throw new Error(error.message);
    return parseNotificationSettings(result);
  });

export const updateNotificationSettingsFn = createServerFn({ method: "POST" })
  .middleware([requireSupabaseAuth])
  .inputValidator((value: unknown) =>
    z
      .object({
        organizationId: z.string().uuid(),
        digestEnabled: z.boolean(),
        digestFrequency: z.enum(["daily", "weekdays", "weekly"]),
        digestSendHour: z.number().int().min(0).max(23),
        digestWeekday: z.number().int().min(1).max(7),
        timezone: z.enum(SUPPORTED_TIMEZONE_VALUES),
      })
      .parse(value),
  )
  .handler(async ({ data, context }): Promise<OrganizationNotificationSettings> => {
    const { data: result, error } = await context.supabase.rpc(
      "update_organization_notification_settings",
      {
        _organization_id: data.organizationId,
        _digest_enabled: data.digestEnabled,
        _digest_frequency: data.digestFrequency,
        _digest_send_hour: data.digestSendHour,
        _digest_weekday: data.digestWeekday,
        _timezone: data.timezone,
      },
    );
    if (error) throw new Error(error.message);
    return parseNotificationSettings(result);
  });

// Entry point for the Worker's scheduled (cron) handler. Server only.
//
// Fails safe: when a required binding is missing (for example SUPABASE_SERVICE_ROLE_KEY or
// RESEND_API_KEY before they are configured), the run does nothing and logs which binding
// NAMES are missing. Nothing is claimed, so nothing is marked or lost; events raised meanwhile
// are expired or suppressed by the database rules instead of being sent late.
import { resolveNotificationConfig } from "./config.ts";
import { createSinkEmailProvider } from "./providers/fake.ts";
import { createResendProvider } from "./providers/resend.ts";
import { createServiceRoleClient, createSupabaseNotificationStore } from "./supabase-store.ts";
import { NOTIFICATION_SENDER } from "./templates.ts";
import type { EmailProvider } from "./types.ts";
import { runNotificationCycle, type NotificationCycleResult } from "./worker.ts";

export type ScheduledRunOutcome =
  | { status: "skipped"; reason: string; missing: string[] }
  | { status: "completed"; result: NotificationCycleResult }
  | { status: "failed"; error: string };

export async function runScheduledNotifications(
  env: Record<string, unknown>,
  options: {
    fallbackSupabaseUrl?: string;
    fetch?: typeof fetch;
    log?: (message: string) => void;
  } = {},
): Promise<ScheduledRunOutcome> {
  const log = options.log ?? ((message: string) => console.log(message));
  const resolved = resolveNotificationConfig(env, options.fallbackSupabaseUrl);
  if (!resolved.ok) {
    log(
      `notifications: skipped (${resolved.reason}${resolved.missing.length ? `: missing ${resolved.missing.join(", ")}` : ""})`,
    );
    return { status: "skipped", reason: resolved.reason, missing: resolved.missing };
  }
  const { config } = resolved;
  const doFetch = options.fetch ?? fetch;
  try {
    const provider: EmailProvider =
      config.provider.kind === "resend"
        ? createResendProvider({ apiKey: config.provider.apiKey, fetch: doFetch })
        : createSinkEmailProvider(config.provider.endpoint, doFetch);
    const store = createSupabaseNotificationStore(
      createServiceRoleClient(config.supabaseUrl, config.serviceRoleKey, doFetch),
    );
    const result = await runNotificationCycle({
      store,
      provider,
      sender: NOTIFICATION_SENDER,
      appBaseUrl: config.appBaseUrl,
      log,
    });
    log(`notifications: ${JSON.stringify(result)}`);
    return { status: "completed", result };
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown error";
    log(`notifications: run failed: ${message}`);
    return { status: "failed", error: message };
  }
}

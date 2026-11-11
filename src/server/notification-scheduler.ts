// Nitro runtime plugin: runs the Phase 6C.3 notification cycle from the Worker's scheduled
// (cron) handler. The cron schedule itself is repo-managed in wrangler.jsonc ("triggers") and
// becomes active only through the normal deployment. One schedule serves every organization;
// which digests are due is decided in the database from each organization's local time.
//
// The notification code is imported on the first scheduled event only, so ordinary requests
// never load it.
import { definePlugin } from "nitro";

type ScheduledHookPayload = {
  controller: { cron: string; scheduledTime: number };
  env: Record<string, unknown>;
};

export default definePlugin((nitroApp) => {
  const hooks = nitroApp.hooks as unknown as {
    hook(
      name: "cloudflare:scheduled",
      handler: (payload: ScheduledHookPayload) => Promise<void>,
    ): void;
  };
  hooks.hook("cloudflare:scheduled", async ({ env }) => {
    const { runScheduledNotifications } = await import("../notifications/scheduled.server.ts");
    await runScheduledNotifications(env ?? {}, {
      fallbackSupabaseUrl: (import.meta.env as { VITE_SUPABASE_URL?: string } | undefined)
        ?.VITE_SUPABASE_URL,
    });
  });
});

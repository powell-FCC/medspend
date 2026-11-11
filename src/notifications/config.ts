// Runtime configuration for the scheduled notification worker, read from the Worker's bindings
// (secrets and vars). Never logs or returns secret values: problems are reported by binding
// NAME only.
//
// Bindings:
//   SUPABASE_URL                       Supabase project URL (falls back to the build-time
//                                      VITE_SUPABASE_URL the app already ships with)
//   SUPABASE_SERVICE_ROLE_KEY          secret, required
//   NOTIFICATIONS_EMAIL_PROVIDER       "resend" (default) or "fake"
//   RESEND_API_KEY                     secret, required when the provider is "resend"
//   NOTIFICATIONS_FAKE_EMAIL_ENDPOINT  loopback http URL, required when the provider is "fake"
//   APP_BASE_URL                       links in emails (default https://app.sport-spend.com)
import { DEFAULT_APP_BASE_URL } from "./templates.ts";
import { isLoopbackUrl } from "./providers/fake.ts";

export type NotificationRuntimeConfig = {
  supabaseUrl: string;
  serviceRoleKey: string;
  provider: { kind: "resend"; apiKey: string } | { kind: "fake"; endpoint: string };
  appBaseUrl: string;
};

export type NotificationConfigResult =
  | { ok: true; config: NotificationRuntimeConfig }
  | { ok: false; reason: string; missing: string[] };

type Env = Record<string, unknown>;

function read(env: Env, name: string): string | undefined {
  const value = env[name];
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}

export function resolveNotificationConfig(
  env: Env,
  fallbackSupabaseUrl?: string,
): NotificationConfigResult {
  const missing: string[] = [];
  const supabaseUrl = read(env, "SUPABASE_URL") ?? (fallbackSupabaseUrl?.trim() || undefined);
  const serviceRoleKey = read(env, "SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl) missing.push("SUPABASE_URL");
  if (!serviceRoleKey) missing.push("SUPABASE_SERVICE_ROLE_KEY");

  const providerName = (read(env, "NOTIFICATIONS_EMAIL_PROVIDER") ?? "resend").toLowerCase();
  let provider: NotificationRuntimeConfig["provider"] | undefined;
  if (providerName === "resend") {
    const apiKey = read(env, "RESEND_API_KEY");
    if (!apiKey) missing.push("RESEND_API_KEY");
    else provider = { kind: "resend", apiKey };
  } else if (providerName === "fake") {
    const endpoint = read(env, "NOTIFICATIONS_FAKE_EMAIL_ENDPOINT");
    if (!endpoint) missing.push("NOTIFICATIONS_FAKE_EMAIL_ENDPOINT");
    else if (!isLoopbackUrl(endpoint)) {
      return {
        ok: false,
        reason: "NOTIFICATIONS_FAKE_EMAIL_ENDPOINT must be a loopback http URL",
        missing: [],
      };
    } else provider = { kind: "fake", endpoint };
  } else {
    return {
      ok: false,
      reason: "NOTIFICATIONS_EMAIL_PROVIDER must be resend or fake",
      missing: [],
    };
  }

  const appBaseUrl = read(env, "APP_BASE_URL") ?? DEFAULT_APP_BASE_URL;
  if (!/^https?:\/\/[^\s/]+/.test(appBaseUrl)) {
    return { ok: false, reason: "APP_BASE_URL must be an http(s) URL", missing: [] };
  }

  if (missing.length > 0 || !provider || !supabaseUrl || !serviceRoleKey) {
    return { ok: false, reason: "notification bindings are not configured", missing };
  }
  return { ok: true, config: { supabaseUrl, serviceRoleKey, provider, appBaseUrl } };
}

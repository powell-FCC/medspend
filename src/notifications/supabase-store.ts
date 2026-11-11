// Service-role implementation of NotificationStore over the Phase 6C.3 RPCs. Trusted server
// code only (the scheduled handler and tests): it uses a service-role key, and
// claim_notification_deliveries returns recipients' sign-in email addresses.
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Database, Json } from "../integrations/supabase/types.ts";
import type { ClaimedDelivery, NotificationStore } from "./types.ts";

function isNewSupabaseApiKey(value: string): boolean {
  return value.startsWith("sb_publishable_") || value.startsWith("sb_secret_");
}

/** A service-role client that never persists a session. Mirrors client.server.ts key handling. */
export function createServiceRoleClient(
  url: string,
  serviceRoleKey: string,
  doFetch: typeof fetch = fetch,
): SupabaseClient<Database> {
  return createClient<Database>(url, serviceRoleKey, {
    global: {
      fetch: (input, init) => {
        const headers = new Headers(init?.headers);
        // New Supabase API keys are opaque strings, not bearer JWTs.
        if (
          isNewSupabaseApiKey(serviceRoleKey) &&
          headers.get("Authorization") === `Bearer ${serviceRoleKey}`
        ) {
          headers.delete("Authorization");
        }
        headers.set("apikey", serviceRoleKey);
        return doFetch(input, { ...init, headers });
      },
    },
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });
}

function fail(operation: string, error: { message: string } | null): never {
  throw new Error(`${operation} failed: ${error?.message ?? "unknown error"}`);
}

export function createSupabaseNotificationStore(
  client: SupabaseClient<Database>,
): NotificationStore {
  return {
    async enqueueDueDigests(now?: Date) {
      const { data, error } = await client.rpc(
        "enqueue_due_notification_digests",
        now ? { _now: now.toISOString() } : {},
      );
      if (error) fail("enqueue_due_notification_digests", error);
      return Number(data ?? 0);
    },
    async dispatchEvents(limit: number) {
      const { data, error } = await client.rpc("dispatch_notification_events", { _limit: limit });
      if (error) fail("dispatch_notification_events", error);
      return Number(data ?? 0);
    },
    async claimDeliveries(limit: number, leaseSeconds: number) {
      const { data, error } = await client.rpc("claim_notification_deliveries", {
        _limit: limit,
        _lease_seconds: leaseSeconds,
      });
      if (error) fail("claim_notification_deliveries", error);
      return (data ?? []).map(
        (row): ClaimedDelivery => ({
          deliveryId: row.delivery_id,
          claimToken: row.claim_token,
          attempt: row.attempt,
          channel: row.channel as ClaimedDelivery["channel"],
          eventType: row.event_type as ClaimedDelivery["eventType"],
          recipientEmail: row.recipient_email,
          context: row.context as unknown as ClaimedDelivery["context"],
        }),
      );
    },
    async completeDelivery(input) {
      const { data, error } = await client.rpc("complete_notification_delivery", {
        _delivery_id: input.deliveryId,
        _claim_token: input.claimToken,
        _outcome: input.outcome,
        _provider: input.provider,
        _provider_message_id: input.providerMessageId,
        _error: input.error,
        _provider_metadata: (input.providerMetadata ?? null) as Json,
      });
      if (error) fail("complete_notification_delivery", error);
      return String(data);
    },
  };
}

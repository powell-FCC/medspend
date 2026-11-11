// Phase 6C.3 delivery cycle. Runs from the Worker's scheduled handler (and from tests):
//   1. enqueue due approver digests (organization-local schedule, at most one per period);
//   2. dispatch pending events into deliveries for the organization's current recipients;
//   3. claim leased batches of due deliveries, render, send through the provider adapter, and
//      record each outcome.
// All idempotency and concurrency control lives in the database (unique keys, row locks,
// leases and claim tokens), so overlapping or repeated runs cannot double-send. A provider
// failure only affects that delivery: it is retried with backoff or dead-lettered.
import { renderNotificationEmail } from "./templates.ts";
import type { ClaimedDelivery, EmailProvider, NotificationStore } from "./types.ts";

export type NotificationCycleOptions = {
  store: NotificationStore;
  provider: EmailProvider;
  sender: string;
  appBaseUrl: string;
  batchSize?: number;
  maxBatches?: number;
  leaseSeconds?: number;
  dispatchLimit?: number;
  now?: () => Date;
  log?: (message: string) => void;
};

export type NotificationCycleResult = {
  digestsEnqueued: number;
  eventsDispatched: number;
  claimed: number;
  sent: number;
  retrying: number;
  dead: number;
  staleClaims: number;
  renderFailures: number;
};

async function deliverOne(
  delivery: ClaimedDelivery,
  options: NotificationCycleOptions,
  result: NotificationCycleResult,
): Promise<void> {
  let rendered;
  try {
    rendered = renderNotificationEmail(delivery, {
      appBaseUrl: options.appBaseUrl,
      now: options.now?.() ?? new Date(),
    });
  } catch (error) {
    result.renderFailures += 1;
    const status = await options.store.completeDelivery({
      deliveryId: delivery.deliveryId,
      claimToken: delivery.claimToken,
      outcome: "permanent_failure",
      provider: null,
      providerMessageId: null,
      error: `render failed: ${error instanceof Error ? error.message : "unknown"}`.slice(0, 300),
      providerMetadata: null,
    });
    if (status === "dead") result.dead += 1;
    return;
  }

  const sendResult = await options.provider.send({
    from: options.sender,
    to: delivery.recipientEmail,
    subject: rendered.subject,
    html: rendered.html,
    text: rendered.text,
    idempotencyKey: `notification-delivery-${delivery.deliveryId}`,
  });

  const status = await options.store.completeDelivery({
    deliveryId: delivery.deliveryId,
    claimToken: delivery.claimToken,
    outcome: sendResult.ok
      ? "sent"
      : sendResult.retryable
        ? "retryable_failure"
        : "permanent_failure",
    provider: sendResult.provider,
    providerMessageId: sendResult.ok ? sendResult.messageId : null,
    error: sendResult.ok ? null : sendResult.error,
    providerMetadata: sendResult.ok ? (sendResult.metadata ?? null) : null,
  });
  if (status === "sent") result.sent += 1;
  else if (status === "pending") result.retrying += 1;
  else if (status === "dead") result.dead += 1;
  else result.staleClaims += 1;
}

export async function runNotificationCycle(
  options: NotificationCycleOptions,
): Promise<NotificationCycleResult> {
  const batchSize = options.batchSize ?? 20;
  const maxBatches = options.maxBatches ?? 10;
  const leaseSeconds = options.leaseSeconds ?? 300;
  const result: NotificationCycleResult = {
    digestsEnqueued: 0,
    eventsDispatched: 0,
    claimed: 0,
    sent: 0,
    retrying: 0,
    dead: 0,
    staleClaims: 0,
    renderFailures: 0,
  };

  result.digestsEnqueued = await options.store.enqueueDueDigests(options.now?.());
  result.eventsDispatched = await options.store.dispatchEvents(options.dispatchLimit ?? 200);

  for (let batch = 0; batch < maxBatches; batch += 1) {
    const claimed = await options.store.claimDeliveries(batchSize, leaseSeconds);
    if (claimed.length === 0) break;
    result.claimed += claimed.length;
    // Sequential within a batch: small volumes, and it keeps provider rate limits simple.
    for (const delivery of claimed) {
      try {
        await deliverOne(delivery, options, result);
      } catch (error) {
        // A database error while recording an outcome leaves the lease to expire; the
        // delivery is claimed again later (the provider idempotency key covers a resend).
        options.log?.(
          `notifications: delivery ${delivery.deliveryId} not recorded: ${error instanceof Error ? error.message : "unknown"}`,
        );
      }
    }
    if (claimed.length < batchSize) break;
  }
  return result;
}

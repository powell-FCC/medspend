// Phase 6C.3 notification types. Provider-neutral: nothing here names an email provider.

export type NotificationEventType =
  | "request_submitted"
  | "request_approved"
  | "request_denied"
  | "approver_digest";

export type NotificationChannel = "email";

/** One outgoing email, as every provider adapter receives it. */
export type EmailMessage = {
  from: string;
  to: string;
  subject: string;
  html: string;
  text: string;
  /** Stable per delivery: lets a provider drop a resend after a lost response. */
  idempotencyKey: string;
};

/**
 * Outcome of one send. `retryable` failures are tried again with backoff (network errors,
 * timeouts, rate limits, provider 5xx); other failures are permanent (rejected message).
 * Provider identifiers are opaque to the rest of the system.
 */
export type EmailSendResult =
  | { ok: true; provider: string; messageId: string | null; metadata?: Record<string, unknown> }
  | { ok: false; provider: string; retryable: boolean; error: string };

export interface EmailProvider {
  readonly name: string;
  send(message: EmailMessage): Promise<EmailSendResult>;
}

export type RequestItemSummary = {
  itemCount: number;
  items: { label: string; quantity: number | null; unit: string | null }[];
};

export type RequestNotificationContext = {
  organizationName: string | null;
  recipientName: string | null;
  audience: "approver" | "requester";
  /** The organization's notification time zone (IANA), for displayed times. */
  timezone: string;
  requestId: string;
  reference: string;
  requestType: string;
  submittedAt: string;
  requesterName: string;
  items: RequestItemSummary;
  requestNote?: string | null;
  decidedAt?: string | null;
  staffVisibleNote?: string | null;
};

export type DigestSectionKey =
  | "awaitingReview"
  | "underReview"
  | "approvedNotOrdered"
  | "orderedNotReceived";

export type DigestSection = {
  count: number;
  oldestAt: string | null;
  items: {
    requestId: string;
    reference: string;
    requesterName: string;
    since: string;
    items: RequestItemSummary;
  }[];
};

export type DigestNotificationContext = {
  organizationName: string | null;
  recipientName: string | null;
  audience: "approver";
  localDate: string;
  frequency: "daily" | "weekdays" | "weekly";
  timezone: string;
  digest: {
    totalCount: number;
    thresholdDays: number;
    sections: Record<DigestSectionKey, DigestSection>;
  };
};

/** A delivery leased to this worker by claim_notification_deliveries. */
export type ClaimedDelivery = {
  deliveryId: string;
  claimToken: string;
  attempt: number;
  channel: NotificationChannel;
  eventType: NotificationEventType;
  recipientEmail: string;
  context: RequestNotificationContext | DigestNotificationContext;
};

export type DeliveryOutcome = "sent" | "retryable_failure" | "permanent_failure";

/** The service-role database operations the worker needs (see supabase-store.ts). */
export interface NotificationStore {
  enqueueDueDigests(now?: Date): Promise<number>;
  dispatchEvents(limit: number): Promise<number>;
  claimDeliveries(limit: number, leaseSeconds: number): Promise<ClaimedDelivery[]>;
  completeDelivery(input: {
    deliveryId: string;
    claimToken: string;
    outcome: DeliveryOutcome;
    provider: string | null;
    providerMessageId: string | null;
    error: string | null;
    providerMetadata: Record<string, unknown> | null;
  }): Promise<string>;
}

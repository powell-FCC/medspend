import type { SupplyRequestStatus } from "@/supply-requests/lifecycle";

// Phase 7C.0: organization request workflow profiles. A profile changes only which actions are
// offered and how the canonical lifecycle is presented. Every canonical status and audit row
// still exists underneath; the database enforces which compound actions a profile enables.

export const REQUEST_WORKFLOW_PROFILES = ["lean", "standard", "detailed"] as const;
export type RequestWorkflowProfile = (typeof REQUEST_WORKFLOW_PROFILES)[number];

// No settings row means detailed (today's behavior).
export const DEFAULT_REQUEST_WORKFLOW_PROFILE: RequestWorkflowProfile = "detailed";

export function parseRequestWorkflowProfile(value: unknown): RequestWorkflowProfile {
  return REQUEST_WORKFLOW_PROFILES.includes(value as RequestWorkflowProfile)
    ? (value as RequestWorkflowProfile)
    : DEFAULT_REQUEST_WORKFLOW_PROFILE;
}

export const REQUEST_WORKFLOW_PROFILE_OPTIONS: readonly {
  value: RequestWorkflowProfile;
  label: string;
  description: string;
  stages: string;
}[] = [
  {
    value: "lean",
    label: "Lean",
    description:
      "Fewer steps for integrated teams. Approval also marks the request ordered; receiving also completes it.",
    stages: "Needs Review → Awaiting Delivery → Completed",
  },
  {
    value: "standard",
    label: "Standard",
    description: "Separate approval and ordering, with receiving and completion combined.",
    stages: "Needs Review → Awaiting Order → Awaiting Delivery → Completed",
  },
  {
    value: "detailed",
    label: "Detailed",
    description:
      "Full request workflow with separate approval, ordering, receiving, staff-ready and completion stages.",
    stages: "Needs Review → Awaiting Order → Awaiting Delivery → Ready for Staff → Completed",
  },
];

export type OrganizationRequestWorkflowSettings = {
  organizationId: string;
  workflowProfile: RequestWorkflowProfile;
  updatedAt: string | null;
};

export function parseRequestWorkflowSettings(value: unknown): OrganizationRequestWorkflowSettings {
  const row = (value ?? {}) as Record<string, unknown>;
  if (typeof row.organizationId !== "string")
    throw new Error("Request workflow settings are unavailable.");
  return {
    organizationId: row.organizationId,
    workflowProfile: parseRequestWorkflowProfile(row.workflowProfile),
    updatedAt: typeof row.updatedAt === "string" ? row.updatedAt : null,
  };
}

// --- Admin queues ---------------------------------------------------------------------------

export const ADMIN_QUEUE_ORDER = [
  "needsReview",
  "awaitingOrder",
  "awaitingDelivery",
  "readyForStaff",
  "completed",
] as const;
export type WorkflowQueueKey = (typeof ADMIN_QUEUE_ORDER)[number];

const OPTIONAL_QUEUES: Readonly<Record<RequestWorkflowProfile, readonly WorkflowQueueKey[]>> = {
  lean: ["awaitingOrder", "readyForStaff"],
  standard: ["readyForStaff"],
  detailed: [],
};

// A profile hides only EMPTY optional queues. A queue holding real requests (for example an
// approved request from before a switch to Lean) always shows, and so does the queue the admin
// is looking at (a digest link may point at a queue that has since emptied).
export function visibleAdminQueues(
  profile: RequestWorkflowProfile,
  summary: Readonly<Record<WorkflowQueueKey, number>>,
  current?: WorkflowQueueKey,
): WorkflowQueueKey[] {
  const hidden = OPTIONAL_QUEUES[profile];
  return ADMIN_QUEUE_ORDER.filter(
    (queue) => !hidden.includes(queue) || summary[queue] > 0 || queue === current,
  );
}

// --- Admin primary actions --------------------------------------------------------------------

export type AdminWorkflowActionKind =
  | "approve"
  | "approve_and_order"
  | "mark_ordered"
  | "mark_received"
  | "receive_and_complete"
  | "complete";

export type AdminWorkflowAction = {
  kind: AdminWorkflowActionKind;
  label: string;
  // The canonical status the request ends in.
  resultStatus: SupplyRequestStatus;
};

// The drawer's primary action for a request in a canonical status. Every open status has an
// action in every profile, so a profile change never strands a request.
export function adminPrimaryAction(
  profile: RequestWorkflowProfile,
  status: SupplyRequestStatus,
): AdminWorkflowAction | null {
  switch (status) {
    case "submitted":
    case "under_review":
      return profile === "lean"
        ? { kind: "approve_and_order", label: "Approve & Order", resultStatus: "ordered" }
        : { kind: "approve", label: "Approve", resultStatus: "approved" };
    case "approved":
      return { kind: "mark_ordered", label: "Mark Ordered", resultStatus: "ordered" };
    case "ordered":
      return profile === "detailed"
        ? { kind: "mark_received", label: "Mark Received", resultStatus: "received" }
        : { kind: "receive_and_complete", label: "Receive & Complete", resultStatus: "completed" };
    case "received":
      return { kind: "complete", label: "Complete Request", resultStatus: "completed" };
    default:
      return null;
  }
}

// The queue card's button. Pending requests open the drawer to decide; every other open status
// names the drawer's primary action, so the card and drawer always agree for the profile.
export function adminQueueCardAction(
  profile: RequestWorkflowProfile,
  status: SupplyRequestStatus,
): string | null {
  if (status === "submitted" || status === "under_review") return "View Request";
  return adminPrimaryAction(profile, status)?.label ?? null;
}

export function adminActionFeedback(kind: AdminWorkflowActionKind | "decline"): string {
  switch (kind) {
    case "approve":
      return "Request approved. Staff can see the decision.";
    case "approve_and_order":
      return "Request approved and marked ordered. Staff can see the decision.";
    case "decline":
      return "Request declined. Your reason is visible to staff.";
    case "receive_and_complete":
      return "Request received and completed.";
    default:
      return "Request updated.";
  }
}

// --- Staff presentation ---------------------------------------------------------------------

// Lean bundles approval and ordering, so an ordered request reads as one step for staff.
export function staffStatusOverride(
  profile: RequestWorkflowProfile,
  status: SupplyRequestStatus,
): { label: string; description: string } | null {
  if (profile === "lean" && status === "ordered") {
    return {
      label: "Approved & ordered",
      description: "Approved and ordered, waiting for delivery",
    };
  }
  return null;
}

// --- History collapse -----------------------------------------------------------------------

export const COMPOUND_ACTIONS = ["approve_and_order", "receive_and_complete"] as const;
export type CompoundAction = (typeof COMPOUND_ACTIONS)[number];

export function parseCompoundAction(value: unknown): CompoundAction | null {
  return COMPOUND_ACTIONS.includes(value as CompoundAction) ? (value as CompoundAction) : null;
}

export const COMPOUND_ACTION_LABELS: Readonly<Record<CompoundAction, string>> = {
  approve_and_order: "Approved & ordered",
  receive_and_complete: "Received & completed",
};

export type CollapsibleUpdate = {
  status_to: SupplyRequestStatus | null;
  compound_action: CompoundAction | null;
  created_at: string;
};

export type CollapsedUpdate<T extends CollapsibleUpdate> = T & {
  // Every canonical row the step stands for (one row for an ordinary transition).
  canonicalRows: T[];
};

// One user action is one step. The rows one compound action wrote are adjacent (same
// transaction timestamp, canonical order) and carry the same marker; they collapse into the
// last row (the final status), keeping the note written on it, or on any earlier row of the
// bundle if a note were ever written there. The database keeps every canonical row.
export function collapseCompoundUpdates<
  T extends CollapsibleUpdate & {
    staff_visible_note?: string | null;
    internal_note?: string | null;
  },
>(updates: readonly T[]): CollapsedUpdate<T>[] {
  const steps: CollapsedUpdate<T>[] = [];
  for (const update of updates) {
    const previous = steps[steps.length - 1];
    if (
      previous &&
      update.compound_action &&
      previous.compound_action === update.compound_action &&
      previous.created_at === update.created_at
    ) {
      const merged: CollapsedUpdate<T> = {
        ...update,
        canonicalRows: [...previous.canonicalRows, update],
      };
      if ("staff_visible_note" in update) {
        merged.staff_visible_note =
          update.staff_visible_note ?? previous.staff_visible_note ?? null;
      }
      if ("internal_note" in update) {
        merged.internal_note = update.internal_note ?? previous.internal_note ?? null;
      }
      steps[steps.length - 1] = merged;
      continue;
    }
    steps.push({ ...update, canonicalRows: [update] });
  }
  return steps;
}

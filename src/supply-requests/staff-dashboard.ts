import type { SupplyRequestStatus } from "@/supply-requests/lifecycle";
import { deliveredToLabel } from "./receiving.ts";
import {
  COMPOUND_ACTION_LABELS,
  DEFAULT_REQUEST_WORKFLOW_PROFILE,
  collapseCompoundUpdates,
  staffStatusOverride,
  type CompoundAction,
  type RequestWorkflowProfile,
} from "./workflow-profiles.ts";

// Staff-facing groupings of the canonical lifecycle. They are presentation only: the
// database statuses are unchanged. READY is the admin "Ready for Staff" queue
// (status 'received'). Declined and cancelled are terminal and ask nothing of the
// requester, so neither is an "attention" state.
export const STAFF_REQUEST_STATUS_GROUPS = [
  "ACTIVE",
  "READY",
  "COMPLETED",
  "DECLINED",
  "CANCELLED",
] as const;

export type StaffRequestStatusGroup = (typeof STAFF_REQUEST_STATUS_GROUPS)[number];

export type StaffRequestStatus = {
  label: string;
  description: string;
  group: StaffRequestStatusGroup;
};

export type StaffRequestViewModel = {
  id: string;
  itemCount: number;
  items: SupplyRequestItemViewModel[];
  itemName: string;
  quantity: number | null;
  unit: string | null;
  statusLabel: string;
  statusDescription: string;
  statusGroup: StaffRequestStatusGroup;
  submittedAt: string;
  lastUpdatedAt: string;
  staffMessage: string | null;
};

export type SupplyRequestItemViewModel = {
  id: string;
  productId: string | null;
  inventoryItemId: string | null;
  vendorProductId: string | null;
  catalogVendorProductId: string | null;
  name: string;
  quantity: number;
  unit: string | null;
  freeTextItem?: string | null;
  manufacturer?: string | null;
  vendorName?: string | null;
  vendorSku?: string | null;
  packageDisplay?: string | null;
};

export type StaffDashboardViewModel = {
  summary: {
    activeRequests: number;
    readyRequests: number;
    completedRequests: number;
  };
  // Every open request (bounded), newest first. READY requests are included.
  openRequests: StaffRequestViewModel[];
  // Completed, declined and cancelled requests, newest first, one page at a time.
  pastRequests: StaffRequestViewModel[];
  hasMorePastRequests: boolean;
};

export type StaffRequestTimelineItem = {
  label: string;
  occurredAt: string;
  message: string | null;
  // Phase 7C: e.g. "Delivered to First Team ATR" (from the receipt's name snapshot).
  destination?: string | null;
};

export type StaffRequestDetailViewModel = StaffRequestViewModel & {
  timeline: StaffRequestTimelineItem[];
  lifecycleStatus: SupplyRequestStatus;
  canEdit: boolean;
  canCancel: boolean;
  editGuidance: string | null;
  requestType: "reorder" | "low_stock" | "out_of_stock" | "new_item";
  teamId: string | null;
  locationId: string | null;
  notes: string | null;
};

// Each label keeps the canonical meaning of its status. 'received' is the admin
// "Ready for Staff" state; 'ordered' and 'approved' say only what has happened.
const STAFF_STATUS: Readonly<Record<SupplyRequestStatus, StaffRequestStatus>> = {
  submitted: { label: "Submitted", description: "Waiting for review", group: "ACTIVE" },
  under_review: { label: "Under review", description: "Being reviewed", group: "ACTIVE" },
  approved: { label: "Approved", description: "Approved, not yet ordered", group: "ACTIVE" },
  ordered: { label: "Ordered", description: "Ordered, waiting for delivery", group: "ACTIVE" },
  received: { label: "Ready", description: "Received and ready for you", group: "READY" },
  completed: { label: "Completed", description: "Request completed", group: "COMPLETED" },
  denied: { label: "Declined", description: "This request was declined", group: "DECLINED" },
  cancelled: { label: "Cancelled", description: "You cancelled this request", group: "CANCELLED" },
};

export const STAFF_OPEN_STATUSES = [
  "submitted",
  "under_review",
  "approved",
  "ordered",
  "received",
] as const satisfies readonly SupplyRequestStatus[];

export const STAFF_PAST_STATUSES = [
  "completed",
  "denied",
  "cancelled",
] as const satisfies readonly SupplyRequestStatus[];

export function isStaffOpenRequest(request: Pick<StaffRequestViewModel, "statusGroup">): boolean {
  return request.statusGroup === "ACTIVE" || request.statusGroup === "READY";
}

export function isStaffPastRequest(request: Pick<StaffRequestViewModel, "statusGroup">): boolean {
  return !isStaffOpenRequest(request);
}

// Bounds for the staff history queries. Open requests are few by nature; past requests
// page in so a long history never loads at once.
export const STAFF_OPEN_REQUEST_LIMIT = 100;
export const STAFF_PAST_REQUEST_PAGE_SIZE = 20;
export const STAFF_PAST_REQUEST_MAX = 200;

// Phase 7C.0: the organization's workflow profile may present a canonical status more simply
// (Lean: an ordered request reads "Approved & ordered"). The group never changes.
export function translateStaffRequestStatus(
  status: SupplyRequestStatus,
  profile: RequestWorkflowProfile = DEFAULT_REQUEST_WORKFLOW_PROFILE,
): StaffRequestStatus {
  const base = STAFF_STATUS[status];
  const override = staffStatusOverride(profile, status);
  return override ? { ...base, ...override } : base;
}

export function summarizeRequestItems(items: SupplyRequestItemViewModel[]): string {
  if (items.length === 1) return items[0].name;
  return `${items.length} items`;
}

// "Gloves, Tape and 2 more" — a short, human summary of what a request contains.
export function describeRequestContents(
  items: Pick<SupplyRequestItemViewModel, "name">[],
  shown = 2,
): string {
  if (items.length === 0) return "No items";
  const names = items.slice(0, shown).map((item) => item.name);
  const remaining = items.length - names.length;
  if (remaining <= 0) return names.join(", ");
  return `${names.join(", ")} and ${remaining} more`;
}

export function summarizeStaffRequests(
  requests: StaffRequestViewModel[],
): StaffDashboardViewModel["summary"] {
  return requests.reduce(
    (summary, request) => {
      if (request.statusGroup === "ACTIVE") summary.activeRequests += 1;
      if (request.statusGroup === "READY") summary.readyRequests += 1;
      if (request.statusGroup === "COMPLETED") summary.completedRequests += 1;
      return summary;
    },
    { activeRequests: 0, readyRequests: 0, completedRequests: 0 },
  );
}

// The staff-safe audited updates, as list_staff_supply_request_updates returns them.
export type StaffRequestUpdateRow = {
  status_to: SupplyRequestStatus | null;
  staff_visible_note: string | null;
  event_kind: string | null;
  created_at: string;
  // Phase 7C.0: set on every canonical row one bundled action wrote.
  compound_action?: CompoundAction | null;
  // Phase 7C: the receipt's destination (name snapshot), on the received row.
  receiving_destination?: string | null;
  receiving_destination_kind?: string | null;
};

const STAFF_COMPOUND_LABELS: Readonly<Record<CompoundAction, string>> = {
  approve_and_order: COMPOUND_ACTION_LABELS.approve_and_order,
  receive_and_complete: "Completed",
};

// Only stored events: the request's creation time and the staff-safe audited updates.
// Nothing is inferred from the current status. The canonical rows one compound action wrote
// (Approve & Order, Receive & Complete) show as one step with its final status and note.
export function buildStaffRequestTimeline(
  submittedAt: string,
  updates: StaffRequestUpdateRow[],
  profile: RequestWorkflowProfile = DEFAULT_REQUEST_WORKFLOW_PROFILE,
): StaffRequestTimelineItem[] {
  const steps = collapseCompoundUpdates(
    updates.map((update) => ({ ...update, compound_action: update.compound_action ?? null })),
  );
  return [
    { label: "Submitted", occurredAt: submittedAt, message: null },
    ...steps.flatMap((update): StaffRequestTimelineItem[] => {
      if (update.event_kind === "requester_edited") {
        return [{ label: "You edited this request", occurredAt: update.created_at, message: null }];
      }
      if (update.event_kind === "requester_cancelled") {
        return [{ label: "Request cancelled", occurredAt: update.created_at, message: null }];
      }
      if (!update.status_to) return [];
      const label =
        update.compound_action && update.canonicalRows.length > 1
          ? STAFF_COMPOUND_LABELS[update.compound_action]
          : translateStaffRequestStatus(update.status_to, profile).label;
      const receipt = update.canonicalRows.find((row) => row.receiving_destination);
      return [
        {
          label,
          occurredAt: update.created_at,
          message: update.staff_visible_note,
          ...(receipt?.receiving_destination
            ? {
                destination: deliveredToLabel(
                  receipt.receiving_destination,
                  receipt.receiving_destination_kind,
                ),
              }
            : {}),
        },
      ];
    }),
  ];
}

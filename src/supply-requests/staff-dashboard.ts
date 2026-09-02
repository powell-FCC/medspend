import type { SupplyRequestStatus } from "@/supply-requests/lifecycle";

export const STAFF_REQUEST_STATUS_GROUPS = [
  "ACTIVE",
  "READY",
  "COMPLETED",
  "ACTION_REQUIRED",
] as const;

export type StaffRequestStatusGroup = (typeof STAFF_REQUEST_STATUS_GROUPS)[number];

export type StaffRequestStatus = {
  label: string;
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
};

export type StaffDashboardViewModel = {
  summary: {
    activeRequests: number;
    readyRequests: number;
    completedRequests: number;
  };
  recentRequests: StaffRequestViewModel[];
  attentionItems: StaffRequestViewModel[];
};

export type StaffRequestTimelineItem = {
  label: string;
  occurredAt: string;
  message: string | null;
};

export type StaffRequestDetailViewModel = StaffRequestViewModel & {
  timeline: StaffRequestTimelineItem[];
};

const STAFF_STATUS: Readonly<Record<SupplyRequestStatus, StaffRequestStatus>> = {
  submitted: { label: "Submitted", group: "ACTIVE" },
  under_review: { label: "Reviewing", group: "ACTIVE" },
  approved: { label: "Approved", group: "ACTIVE" },
  ordered: { label: "Ordered", group: "ACTIVE" },
  received: { label: "Ready", group: "READY" },
  completed: { label: "Completed", group: "COMPLETED" },
  denied: { label: "Not Approved", group: "ACTION_REQUIRED" },
};

export function translateStaffRequestStatus(status: SupplyRequestStatus): StaffRequestStatus {
  return STAFF_STATUS[status];
}

export function summarizeRequestItems(items: SupplyRequestItemViewModel[]): string {
  if (items.length === 1) return items[0].name;
  return `${items.length} items`;
}

export function summarizeStaffRequests(requests: StaffRequestViewModel[]): StaffDashboardViewModel["summary"] {
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

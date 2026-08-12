import type { SupplyRequestStatus } from "@/supply-requests/lifecycle";
import type { SupplyRequestItemViewModel } from "@/supply-requests/staff-dashboard";

export const ADMIN_REQUEST_QUEUE_GROUPS = [
  "NEEDS_REVIEW",
  "AWAITING_ORDER",
  "AWAITING_DELIVERY",
  "READY_FOR_STAFF",
  "COMPLETED",
] as const;

export type AdminRequestQueueGroup = (typeof ADMIN_REQUEST_QUEUE_GROUPS)[number];

export type AdminQueueTranslation = {
  queueGroup: AdminRequestQueueGroup;
  statusLabel: string;
  nextAction: string | null;
};

export type AdminSupplyRequestViewModel = {
  id: string;
  itemCount: number;
  items: SupplyRequestItemViewModel[];
  itemName: string;
  quantity: number | null;
  unit: string | null;
  requesterName: string;
  requesterEmail: string | null;
  team: string | null;
  location: string | null;
  requestTypeLabel: string;
  queueGroup: AdminRequestQueueGroup;
  statusLabel: string;
  nextAction: string | null;
  lifecycleStatus: SupplyRequestStatus;
  submittedAt: string;
  updatedAt: string;
  ageInDays: number;
  staffNote: string | null;
  latestStaffMessage: string | null;
  latestInternalNote: string | null;
  latestUpdateAt: string;
  hasExistingProduct: boolean;
  isNewItem: boolean;
};

export type AdminSupplyRequestDashboard = {
  summary: {
    needsReview: number;
    awaitingOrder: number;
    awaitingDelivery: number;
    readyForStaff: number;
    completed: number;
  };
  queues: {
    needsReview: AdminSupplyRequestViewModel[];
    awaitingOrder: AdminSupplyRequestViewModel[];
    awaitingDelivery: AdminSupplyRequestViewModel[];
    readyForStaff: AdminSupplyRequestViewModel[];
    completed: AdminSupplyRequestViewModel[];
  };
};

const QUEUE_TRANSLATIONS: Readonly<Record<SupplyRequestStatus, AdminQueueTranslation>> = {
  submitted: { queueGroup: "NEEDS_REVIEW", statusLabel: "Submitted", nextAction: "Review Request" },
  under_review: { queueGroup: "NEEDS_REVIEW", statusLabel: "Under Review", nextAction: "Approve or Decline" },
  approved: { queueGroup: "AWAITING_ORDER", statusLabel: "Approved", nextAction: "Mark Ordered" },
  ordered: { queueGroup: "AWAITING_DELIVERY", statusLabel: "Ordered", nextAction: "Mark Received" },
  received: { queueGroup: "READY_FOR_STAFF", statusLabel: "Ready for Staff", nextAction: "Complete Request" },
  completed: { queueGroup: "COMPLETED", statusLabel: "Completed", nextAction: null },
  denied: { queueGroup: "COMPLETED", statusLabel: "Denied", nextAction: null },
};

const REQUEST_TYPE_LABELS = {
  reorder: "Supply Request",
  low_stock: "Low Stock",
  out_of_stock: "Out of Stock",
  new_item: "New Item",
} as const;

export function translateAdminRequestStatus(status: SupplyRequestStatus): AdminQueueTranslation {
  return QUEUE_TRANSLATIONS[status];
}

export function translateAdminRequestType(type: keyof typeof REQUEST_TYPE_LABELS): string {
  return REQUEST_TYPE_LABELS[type];
}

export function requestAgeInDays(submittedAt: string, now = new Date()): number {
  const elapsed = now.getTime() - new Date(submittedAt).getTime();
  return Math.max(0, Math.floor(elapsed / 86_400_000));
}

export function buildAdminRequestDashboard(
  requests: AdminSupplyRequestViewModel[],
): AdminSupplyRequestDashboard {
  const queues: AdminSupplyRequestDashboard["queues"] = {
    needsReview: [],
    awaitingOrder: [],
    awaitingDelivery: [],
    readyForStaff: [],
    completed: [],
  };
  for (const request of requests) {
    if (request.queueGroup === "NEEDS_REVIEW") queues.needsReview.push(request);
    if (request.queueGroup === "AWAITING_ORDER") queues.awaitingOrder.push(request);
    if (request.queueGroup === "AWAITING_DELIVERY") queues.awaitingDelivery.push(request);
    if (request.queueGroup === "READY_FOR_STAFF") queues.readyForStaff.push(request);
    if (request.queueGroup === "COMPLETED") queues.completed.push(request);
  }
  return {
    summary: {
      needsReview: queues.needsReview.length,
      awaitingOrder: queues.awaitingOrder.length,
      awaitingDelivery: queues.awaitingDelivery.length,
      readyForStaff: queues.readyForStaff.length,
      completed: queues.completed.length,
    },
    queues,
  };
}

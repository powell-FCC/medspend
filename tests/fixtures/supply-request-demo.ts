import type { AdminSupplyRequestViewModel } from "../../src/supply-requests/admin-dashboard.ts";

const base = {
  quantity: 6,
  unit: "boxes",
  requesterName: "Alex Morgan",
  team: "Medical Team",
  location: "Training Room",
  requestTypeLabel: "Supply Request",
  submittedAt: "2026-08-12T13:00:00.000Z",
  updatedAt: "2026-08-12T13:00:00.000Z",
  ageInDays: 2,
  staffNote: "Needed for the weekend match.",
  latestInternalNote: "Confirm storage location before notifying staff.",
  latestUpdateAt: "2026-08-13T13:00:00.000Z",
  hasExistingProduct: true,
  isNewItem: false,
} as const;

export const supplyRequestDemoFixture: AdminSupplyRequestViewModel[] = [
  { ...base, id: "demo-needs-review", itemName: "Athletic Tape", lifecycleStatus: "submitted", queueGroup: "NEEDS_REVIEW", statusLabel: "Submitted", nextAction: "Review Request", latestStaffMessage: null },
  { ...base, id: "demo-awaiting-order", itemName: "Nitrile Gloves", lifecycleStatus: "approved", queueGroup: "AWAITING_ORDER", statusLabel: "Approved", nextAction: "Mark Ordered", latestStaffMessage: "Approved. Ordering today." },
  { ...base, id: "demo-awaiting-delivery", itemName: "Cold Packs", lifecycleStatus: "ordered", queueGroup: "AWAITING_DELIVERY", statusLabel: "Ordered", nextAction: "Mark Received", latestStaffMessage: "Arriving Friday morning." },
  { ...base, id: "demo-ready", itemName: "Elastic Wrap", lifecycleStatus: "received", queueGroup: "READY_FOR_STAFF", statusLabel: "Ready for Staff", nextAction: "Complete Request", latestStaffMessage: "Available in medical storage." },
  { ...base, id: "demo-completed", itemName: "Gauze Pads", lifecycleStatus: "completed", queueGroup: "COMPLETED", statusLabel: "Completed", nextAction: null, latestStaffMessage: "Request fulfilled." },
];

export const supplyRequestDemoHistory = {
  "demo-needs-review": [
    { status: "submitted", at: "2026-08-12T13:00:00.000Z", staffMessage: null, internalNote: null },
  ],
  "demo-awaiting-order": [
    { status: "submitted", at: "2026-08-12T13:00:00.000Z", staffMessage: null, internalNote: null },
    { status: "under_review", at: "2026-08-12T15:00:00.000Z", staffMessage: "We're reviewing your request.", internalNote: null },
    { status: "approved", at: "2026-08-13T13:00:00.000Z", staffMessage: "Approved. Ordering today.", internalNote: "Use standard medical supplier." },
  ],
  "demo-awaiting-delivery": [
    { status: "approved", at: "2026-08-12T15:00:00.000Z", staffMessage: "Approved.", internalNote: null },
    { status: "ordered", at: "2026-08-13T13:00:00.000Z", staffMessage: "Arriving Friday morning.", internalNote: "Order confirmed." },
  ],
  "demo-ready": [
    { status: "ordered", at: "2026-08-12T15:00:00.000Z", staffMessage: "Order placed.", internalNote: null },
    { status: "received", at: "2026-08-13T13:00:00.000Z", staffMessage: "Available in medical storage.", internalNote: "Stored in cabinet B." },
  ],
  "demo-completed": [
    { status: "received", at: "2026-08-12T15:00:00.000Z", staffMessage: "Ready for pickup.", internalNote: null },
    { status: "completed", at: "2026-08-13T13:00:00.000Z", staffMessage: "Request fulfilled.", internalNote: "Handed to requester." },
  ],
} as const;

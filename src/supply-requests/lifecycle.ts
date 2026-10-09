export const SUPPLY_REQUEST_STATUSES = [
  'submitted',
  'under_review',
  'approved',
  'ordered',
  'received',
  'completed',
  'denied',
] as const;

export type SupplyRequestStatus = (typeof SUPPLY_REQUEST_STATUSES)[number];

export const ALLOWED_SUPPLY_REQUEST_TRANSITIONS: Readonly<Record<SupplyRequestStatus, readonly SupplyRequestStatus[]>> = {
  submitted: ['under_review', 'denied'],
  under_review: ['approved', 'denied'],
  approved: ['ordered', 'denied'],
  ordered: ['received', 'denied'],
  received: ['completed'],
  completed: [],
  denied: [],
};

export function canTransitionSupplyRequest(from: SupplyRequestStatus, to: SupplyRequestStatus): boolean {
  return ALLOWED_SUPPLY_REQUEST_TRANSITIONS[from].includes(to);
}

export function allowedNextSupplyRequestStatuses(status: SupplyRequestStatus): readonly SupplyRequestStatus[] {
  return ALLOWED_SUPPLY_REQUEST_TRANSITIONS[status];
}


// Phase 6C: a requester may edit their own request only before admin review begins.
// The database RPC enforces this; the UI uses it only to avoid offering a doomed action.
export const REQUESTER_EDITABLE_STATUS: SupplyRequestStatus = 'submitted';

export function canRequesterEditSupplyRequest(status: SupplyRequestStatus): boolean {
  return status === REQUESTER_EDITABLE_STATUS;
}

export function requesterEditGuidance(status: SupplyRequestStatus): string | null {
  if (canRequesterEditSupplyRequest(status)) return 'You can make changes until this request enters review.';
  if (status === 'under_review') return 'This request is being reviewed and can no longer be edited.';
  return null;
}

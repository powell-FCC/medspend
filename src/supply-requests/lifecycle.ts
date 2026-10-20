export const SUPPLY_REQUEST_STATUSES = [
  'submitted',
  'under_review',
  'approved',
  'ordered',
  'received',
  'completed',
  'denied',
  // Phase 6C.2: terminal. Reached only through the requester cancellation RPC.
  'cancelled',
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
  cancelled: [],
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
  if (status === 'cancelled') return 'You cancelled this request. It will not be reviewed or fulfilled.';
  return null;
}

// Phase 6C.2: cancellation uses exactly the edit window. The admin transition matrix
// above never reaches 'cancelled'; only cancel_submitted_supply_request does, and it is
// the enforcement boundary.
export function canRequesterCancelSupplyRequest(status: SupplyRequestStatus): boolean {
  return canRequesterEditSupplyRequest(status);
}

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


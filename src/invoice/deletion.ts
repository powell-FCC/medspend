import type { ProcessingStatus } from '@/types/invoice-processing';

export type InvoiceDocumentType =
  | 'INVOICE' | 'ORDER_CONFIRMATION' | 'PURCHASE_ORDER'
  | 'CREDIT_MEMO' | 'STATEMENT' | 'UNKNOWN';

export interface InvoiceDeletionState {
  status: ProcessingStatus;
  processingStatus: string | null;
  postedAt: string | null;
}

export interface InvoiceDeletionEligibility {
  eligible: boolean;
  reason: string | null;
}

export interface InventoryLedgerEntry {
  id: string;
  adjustmentAmount: number;
  belongsToDeletedInvoice: boolean;
}

export interface ReconstructedLedgerEntry extends InventoryLedgerEntry {
  previousQuantity: number;
  newQuantity: number;
}

export function reconstructInventoryLedger(currentQuantity: number, entries: InventoryLedgerEntry[]) {
  const removedQuantity = entries.filter((entry) => entry.belongsToDeletedInvoice)
    .reduce((total, entry) => total + entry.adjustmentAmount, 0);
  const quantity = currentQuantity - removedQuantity;
  if (removedQuantity < 0 || quantity < 0) throw new Error('Removing this invoice would make current inventory negative.');
  const remaining = entries.filter((entry) => !entry.belongsToDeletedInvoice);
  let running = quantity - remaining.reduce((total, entry) => total + entry.adjustmentAmount, 0);
  if (running < 0) throw new Error('The remaining inventory history would begin below zero.');
  const ledger: ReconstructedLedgerEntry[] = remaining.map((entry) => {
    const previousQuantity = running;
    running += entry.adjustmentAmount;
    if (running < 0) throw new Error('The remaining inventory history would become negative.');
    return { ...entry, previousQuantity, newQuantity: running };
  });
  if (running !== quantity) throw new Error('Inventory history could not be reconstructed.');
  return { quantity, removedQuantity, ledger };
}

export function getInvoiceDeletionEligibility(state: InvoiceDeletionState): InvoiceDeletionEligibility {
  if (state.status === 'processing' || state.processingStatus === 'processing') {
    return { eligible: false, reason: 'This document is currently being processed. Try again when processing is complete.' };
  }
  return { eligible: true, reason: null };
}

export function documentTypeLabel(type: InvoiceDocumentType): string {
  return ({
    INVOICE: 'invoice', ORDER_CONFIRMATION: 'order confirmation', PURCHASE_ORDER: 'purchase order',
    CREDIT_MEMO: 'credit memo', STATEMENT: 'statement', UNKNOWN: 'uploaded document',
  } as const)[type];
}

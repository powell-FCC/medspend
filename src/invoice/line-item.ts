export function calculateInvoiceLineTotal(quantity: number, unitPrice: number): number {
  if (!Number.isFinite(quantity) || !Number.isFinite(unitPrice) || quantity < 0 || unitPrice < 0) return 0;
  return Math.round((quantity * unitPrice + Number.EPSILON) * 100) / 100;
}


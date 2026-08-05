export type InventoryStatus = 'healthy' | 'low' | 'critical' | 'inactive';
export type AdjustmentReason = 'Invoice received' | 'Manual adjustment' | 'Damaged' | 'Expired' | 'Correction';

export interface InventoryItem {
  id: string; organizationId: string; name: string; description: string | null; sku: string | null;
  vendorName: string | null; category: string | null; manufacturer: string | null; quantity: number;
  unit: string; parLevel: number | null; active: boolean; createdAt: string; updatedAt: string;
}

export interface InventoryCategory { id: string; organizationId: string; name: string; createdAt: string }

export interface InventoryItemInput {
  id?: string; organizationId: string; name: string; description?: string | null; sku?: string | null;
  vendorName?: string | null; category?: string | null; manufacturer?: string | null;
  quantity: number; unit: string; parLevel?: number | null;
}

import type { InventoryStatus } from '@/types/inventory';

export function getInventoryStatus(quantity: number, parLevel: number | null, active = true): InventoryStatus {
  if (!active) return 'inactive';
  if (parLevel === null || parLevel <= 0 || quantity > parLevel) return 'healthy';
  if (quantity <= parLevel * 0.5) return 'critical';
  return 'low';
}

export const inventoryStatusLabel: Record<InventoryStatus, string> = {
  healthy: 'In stock', low: 'Low stock', critical: 'Critical', inactive: 'Archived',
};

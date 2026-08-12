import type { InventoryStatus } from '@/types/inventory';

export type InventoryIntelligenceStockStatus = 'healthy' | 'low' | 'critical' | 'out_of_stock' | 'no_par';

export function getInventoryStatus(quantity: number, parLevel: number | null, active = true): InventoryStatus {
  if (!active) return 'inactive';
  if (parLevel === null || parLevel <= 0 || quantity > parLevel) return 'healthy';
  if (quantity <= parLevel * 0.5) return 'critical';
  return 'low';
}

export function getInventoryIntelligenceStockStatus(
  quantity: number,
  parLevel: number | null,
): InventoryIntelligenceStockStatus {
  if (parLevel === null || parLevel <= 0) return 'no_par';
  if (quantity <= 0) return 'out_of_stock';
  return getInventoryStatus(quantity, parLevel) as Exclude<InventoryIntelligenceStockStatus, 'out_of_stock' | 'no_par'>;
}

export const inventoryStatusLabel: Record<InventoryStatus, string> = {
  healthy: 'In stock', low: 'Low stock', critical: 'Critical', inactive: 'Archived',
};

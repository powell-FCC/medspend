import { getInventoryIntelligenceStockStatus, type InventoryIntelligenceStockStatus } from './status.ts';

export type InventoryIntelligenceRole = 'owner' | 'admin' | 'staff';

export interface InventoryIntelligenceSourceItem {
  inventoryItemId: string;
  productId: string | null;
  inventoryName: string;
  inventoryCategory: string | null;
  quantity: number;
  unit: string;
  parLevel: number | null;
  inventoryLastPurchasePrice: number | null;
  inventoryLastPurchaseDate: string | null;
}

export interface InventoryIntelligenceProduct {
  id: string;
  name: string;
  category: string | null;
  preferredVendor: string | null;
}

export interface InventoryPurchaseObservation {
  productId: string;
  purchaseDate: string;
  unitPrice: number | null;
}

export interface InventoryDemandObservation {
  productId: string;
  quantity: number | null;
  requestId?: string;
}

export interface InventoryReceiptObservation {
  inventoryItemId: string;
  receivedAt: string;
}

export interface InventoryIntelligenceItem {
  inventoryItemId: string;
  productId: string | null;
  productName: string;
  category: string | null;
  quantity: number;
  unit: string;
  parLevel: number | null;
  stockStatus: InventoryIntelligenceStockStatus;
  preferredVendor: string | null;
  lastPurchasePrice: number | null;
  lastPurchaseDate: string | null;
  lastReceivedDate: string | null;
  openRequestCount: number;
  pendingRequestedQuantity: number;
  dataQuality: {
    linkedToProduct: boolean;
    hasParLevel: boolean;
    hasVendor: boolean;
    hasPurchaseHistory: boolean;
  };
}

export interface InventoryIntelligenceDashboard {
  summary: {
    totalItems: number;
    healthyItems: number;
    lowStockItems: number;
    criticalItems: number;
    outOfStockItems: number;
    unlinkedItems: number;
    missingParItems: number;
  };
  items: InventoryIntelligenceItem[];
}

export function canAccessInventoryIntelligence(role: InventoryIntelligenceRole): boolean {
  return role === 'owner' || role === 'admin';
}

export function buildInventoryIntelligenceDashboard(input: {
  inventoryItems: InventoryIntelligenceSourceItem[];
  products: InventoryIntelligenceProduct[];
  purchaseHistory: InventoryPurchaseObservation[];
  demand: InventoryDemandObservation[];
  receipts: InventoryReceiptObservation[];
}): InventoryIntelligenceDashboard {
  const products = new Map(input.products.map((product) => [product.id, product]));
  const purchases = new Map<string, InventoryPurchaseObservation>();
  for (const observation of input.purchaseHistory) {
    const current = purchases.get(observation.productId);
    if (!current || observation.purchaseDate > current.purchaseDate) purchases.set(observation.productId, observation);
  }
  const demand = new Map<string, { requestIds: Set<string>; quantity: number }>();
  for (const request of input.demand) {
    const current = demand.get(request.productId) ?? { requestIds: new Set<string>(), quantity: 0 };
    current.requestIds.add(request.requestId ?? `${request.productId}:${current.requestIds.size}`);
    current.quantity += request.quantity ?? 0;
    demand.set(request.productId, current);
  }
  const receipts = new Map<string, string>();
  for (const receipt of input.receipts) {
    const current = receipts.get(receipt.inventoryItemId);
    if (!current || receipt.receivedAt > current) receipts.set(receipt.inventoryItemId, receipt.receivedAt);
  }

  const items = input.inventoryItems.map((inventory): InventoryIntelligenceItem => {
    const product = inventory.productId ? products.get(inventory.productId) : undefined;
    const linkedToProduct = Boolean(product);
    const purchase = product ? purchases.get(product.id) : undefined;
    const openDemand = product ? demand.get(product.id) : undefined;
    return {
      inventoryItemId: inventory.inventoryItemId,
      productId: product?.id ?? inventory.productId,
      productName: product?.name ?? inventory.inventoryName,
      category: product?.category ?? inventory.inventoryCategory,
      quantity: inventory.quantity,
      unit: inventory.unit,
      parLevel: inventory.parLevel,
      stockStatus: getInventoryIntelligenceStockStatus(inventory.quantity, inventory.parLevel),
      preferredVendor: product?.preferredVendor ?? null,
      lastPurchasePrice: purchase?.unitPrice ?? inventory.inventoryLastPurchasePrice,
      lastPurchaseDate: purchase?.purchaseDate ?? inventory.inventoryLastPurchaseDate,
      lastReceivedDate: receipts.get(inventory.inventoryItemId) ?? null,
      openRequestCount: openDemand?.requestIds.size ?? 0,
      pendingRequestedQuantity: openDemand?.quantity ?? 0,
      dataQuality: {
        linkedToProduct,
        hasParLevel: inventory.parLevel !== null && inventory.parLevel > 0,
        hasVendor: Boolean(product?.preferredVendor),
        hasPurchaseHistory: Boolean(purchase),
      },
    };
  });

  return {
    summary: {
      totalItems: items.length,
      healthyItems: items.filter((item) => item.stockStatus === 'healthy').length,
      lowStockItems: items.filter((item) => item.stockStatus === 'low').length,
      criticalItems: items.filter((item) => item.stockStatus === 'critical').length,
      outOfStockItems: items.filter((item) => item.stockStatus === 'out_of_stock').length,
      unlinkedItems: items.filter((item) => !item.dataQuality.linkedToProduct).length,
      missingParItems: items.filter((item) => !item.dataQuality.hasParLevel).length,
    },
    items,
  };
}

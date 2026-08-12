import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  buildInventoryIntelligenceDashboard,
  canAccessInventoryIntelligence,
  type InventoryIntelligenceSourceItem,
} from '../src/inventory/intelligence.ts';

const linked: InventoryIntelligenceSourceItem = {
  inventoryItemId: 'inventory-1', productId: 'product-1', inventoryName: 'Legacy Tape',
  inventoryCategory: 'Legacy', quantity: 8, unit: 'roll', parLevel: 10,
  inventoryLastPurchasePrice: 8, inventoryLastPurchaseDate: '2026-01-01',
};

test('owner and admin roles can access intelligence while staff cannot', () => {
  assert.equal(canAccessInventoryIntelligence('owner'), true);
  assert.equal(canAccessInventoryIntelligence('admin'), true);
  assert.equal(canAccessInventoryIntelligence('staff'), false);
});

test('linked inventory uses canonical product data and invoice-derived purchase history', () => {
  const dashboard = buildInventoryIntelligenceDashboard({
    inventoryItems: [linked],
    products: [{ id: 'product-1', name: 'Athletic Tape', category: 'Athletic Tape', preferredVendor: 'Henry Schein' }],
    purchaseHistory: [{ productId: 'product-1', purchaseDate: '2026-08-01', unitPrice: 9.5 }],
    demand: [], receipts: [{ inventoryItemId: 'inventory-1', receivedAt: '2026-08-02T00:00:00Z' }],
  });
  assert.equal(dashboard.items[0].productName, 'Athletic Tape');
  assert.equal(dashboard.items[0].category, 'Athletic Tape');
  assert.equal(dashboard.items[0].preferredVendor, 'Henry Schein');
  assert.equal(dashboard.items[0].lastPurchasePrice, 9.5);
  assert.equal(dashboard.items[0].dataQuality.hasPurchaseHistory, true);
  assert.equal(dashboard.items[0].stockStatus, 'low');
});

test('unlinked inventory and missing par levels remain visible as data quality issues', () => {
  const dashboard = buildInventoryIntelligenceDashboard({
    inventoryItems: [{ ...linked, productId: null, parLevel: null, quantity: 0 }],
    products: [], purchaseHistory: [], demand: [], receipts: [],
  });
  assert.equal(dashboard.items.length, 1);
  assert.equal(dashboard.items[0].productName, 'Legacy Tape');
  assert.equal(dashboard.items[0].stockStatus, 'no_par');
  assert.deepEqual(dashboard.items[0].dataQuality, {
    linkedToProduct: false, hasParLevel: false, hasVendor: false, hasPurchaseHistory: false,
  });
  assert.equal(dashboard.summary.unlinkedItems, 1);
  assert.equal(dashboard.summary.missingParItems, 1);
});

test('open requests aggregate only supplied canonical demand observations', () => {
  const dashboard = buildInventoryIntelligenceDashboard({
    inventoryItems: [linked],
    products: [{ id: 'product-1', name: 'Tape', category: null, preferredVendor: null }],
    purchaseHistory: [], receipts: [],
    demand: [
      { productId: 'product-1', quantity: 2 },
      { productId: 'product-1', quantity: 3 },
      { productId: 'another-product', quantity: 100 },
    ],
  });
  assert.equal(dashboard.items[0].openRequestCount, 2);
  assert.equal(dashboard.items[0].pendingRequestedQuantity, 5);
});

test('multiple lines from one parent add demand without inflating operational request count', () => {
  const dashboard = buildInventoryIntelligenceDashboard({
    inventoryItems: [linked],
    products: [{ id: 'product-1', name: 'Tape', category: null, preferredVendor: null }],
    purchaseHistory: [], receipts: [],
    demand: [
      { requestId: 'request-1', productId: 'product-1', quantity: 2 },
      { requestId: 'request-1', productId: 'product-1', quantity: 3 },
    ],
  });
  assert.equal(dashboard.items[0].openRequestCount, 1);
  assert.equal(dashboard.items[0].pendingRequestedQuantity, 5);
});

test('server query is organization scoped, role protected, read-only, and excludes closed demand', async () => {
  const source = await readFile(new URL('../src/lib/inventory-intelligence.functions.ts', import.meta.url), 'utf8');
  assert.match(source, /canAccessInventoryIntelligence/);
  assert.match(source, /eq\('user_id', context\.userId\)/);
  assert.ok((source.match(/eq\('organization_id', data\.organizationId\)/g) ?? []).length >= 7);
  assert.match(source, /OPEN_REQUEST_STATUSES = \['submitted', 'under_review', 'approved', 'ordered', 'received'\]/);
  assert.doesNotMatch(source, /\.insert\(|\.update\(|\.delete\(|\.upsert\(|\.rpc\(/);
});

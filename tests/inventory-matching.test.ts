import assert from 'node:assert/strict';
import test from 'node:test';
import { inventoryMatchPriority } from '../src/inventory/matching.ts';

test('inventory matching prioritizes SKU regardless of vendor', () => {
  assert.equal(inventoryMatchPriority(
    { sku: 'ABC-123', vendorName: 'Vendor Co', name: 'Exam gloves' },
    { sku: ' abc-123 ', vendorName: 'Another vendor', name: 'Different item' },
  ), 1);
});

test('inventory matching falls back to vendor and name', () => {
  assert.equal(inventoryMatchPriority(
    { sku: null, vendorName: 'Vendor Co', name: 'Nitrile Exam Gloves' },
    { sku: '', vendorName: 'vendor co', name: ' nitrile exam gloves ' },
  ), 2);
});

test('inventory matching falls back to normalized name', () => {
  assert.equal(inventoryMatchPriority(
    { sku: null, vendorName: 'Vendor Co', name: 'Nitrile-Exam Gloves' },
    { sku: '', vendorName: 'Another Vendor', name: 'nitrile exam gloves' },
  ), 3);
});

test('inventory matching allows genuinely new items', () => {
  assert.equal(inventoryMatchPriority(
    { sku: 'ABC-123', vendorName: 'Vendor Co', name: 'Exam gloves' },
    { sku: 'XYZ-999', vendorName: 'Vendor Co', name: 'Surgical masks' },
  ), null);
});

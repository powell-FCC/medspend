import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../', import.meta.url);
const migration = await readFile(new URL('supabase/migrations/20260813130000_phase3a4_1_persistent_vendor_sku_matching.sql', root), 'utf8');
const server = await readFile(new URL('src/lib/invoice-processing.functions.ts', root), 'utf8');

test('saving invoice vendor reruns exact persisted vendor SKU matching', () => {
  assert.match(server, /saveInvoiceHeaderFn[\s\S]*rpc\('rematch_invoice_vendor_products'/);
  assert.match(migration, /item\.product_id IS NULL/);
  assert.match(migration, /mapping\.vendor_id = _invoice\.vendor_id/);
  assert.match(migration, /lower\(btrim\(mapping\.vendor_sku\)\) = lower\(btrim\(item\.sku\)\)/);
});

test('rematching is owner-only, organization scoped, and never creates products', () => {
  assert.match(migration, /has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]/);
  assert.match(migration, /item\.organization_id = _organization_id/g);
  assert.match(migration, /mapping\.organization_id = _organization_id/g);
  assert.doesNotMatch(migration, /INSERT INTO public\.(products|vendor_products)/);
});

test('vendor changes clear only unsafe mapping-derived links and preserve manual product-only links', () => {
  assert.match(migration, /item\.vendor_product_id = mapping\.id/);
  assert.match(migration, /mapping\.vendor_id <> _invoice\.vendor_id/);
  assert.doesNotMatch(migration, /WHERE item\.product_id IS NOT NULL/);
});

test('create-product path verifies and repairs persistent mapping without creating a second product', () => {
  assert.match(server, /create_product_from_invoice_item[\s\S]*confirm_invoice_item_product/);
  assert.match(server, /_remember_vendor_sku: true/);
});

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migrationUrl = new URL('../supabase/migrations/20260808120000_phase2c5_expand.sql', import.meta.url);
const sql = readFileSync(migrationUrl, 'utf8');

test('Phase 2C.5 expand migration creates the four canonical preparation tables', () => {
  for (const table of ['vendor_products', 'inventory_price_history', 'invoice_extraction_runs', 'invoice_extraction_candidates']) {
    assert.match(sql, new RegExp(`CREATE TABLE public\\.${table}\\b`));
    assert.match(sql, new RegExp(`ALTER TABLE public\\.${table} ENABLE ROW LEVEL SECURITY`));
  }
});

test('Phase 2C.5 expand migration adds nullable relationships and preparation fields', () => {
  assert.match(sql, /ALTER TABLE public\.inventory_items ADD COLUMN product_id uuid;/);
  for (const field of ['purchase_order_number', 'subtotal', 'tax_amount', 'shipping_amount', 'total_amount', 'currency_code', 'payment_terms', 'reviewed_by', 'reviewed_at', 'posted_at']) {
    assert.match(sql, new RegExp(`ADD COLUMN ${field}\\b`));
  }
  for (const field of ['product_id', 'vendor_product_id', 'line_number', 'manufacturer', 'package_size', 'review_status']) {
    assert.match(sql, new RegExp(`ADD COLUMN ${field}\\b`));
  }
  for (const field of ['source_type', 'source_invoice_id', 'source_invoice_item_id', 'idempotency_key']) {
    assert.match(sql, new RegExp(`ADD COLUMN ${field}\\b`));
  }
});

test('Phase 2C.5 expand migration is non-destructive and does not implement extraction', () => {
  assert.doesNotMatch(sql, /\bDROP\s+(?:TABLE|COLUMN)\b/i);
  assert.doesNotMatch(sql, /\bDELETE\s+FROM\b/i);
  assert.doesNotMatch(sql, /\bTRUNCATE\b/i);
  assert.doesNotMatch(sql, /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION/i);
  assert.match(sql, /Nothing writes these tables in this phase/);
});


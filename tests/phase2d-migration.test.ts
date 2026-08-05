import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const sql = readFileSync(new URL('../supabase/migrations/20260809120000_phase2d_manual_invoice_review.sql', import.meta.url), 'utf8');

test('Phase 2D posting is an owner-checked atomic database function', () => {
  assert.match(sql, /CREATE OR REPLACE FUNCTION public\.post_reviewed_invoice/);
  assert.match(sql, /has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]/);
  assert.match(sql, /FOR UPDATE/);
  assert.match(sql, /posted_at IS NOT NULL/);
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.post_reviewed_invoice/);
});

test('Phase 2D posting records all inventory effects and final statuses', () => {
  for (const table of ['vendor_products', 'inventory_items', 'inventory_adjustments', 'inventory_price_history']) {
    assert.match(sql, new RegExp(`(?:INSERT INTO|UPDATE) public\\.${table}`));
  }
  assert.match(sql, /source_invoice_item_id/);
  assert.match(sql, /processing_status = 'completed'/);
  assert.match(sql, /invoice_processing_jobs SET status = 'completed'/);
});

test('Phase 2D migration does not add extraction, destructive changes, or RLS changes', () => {
  assert.doesNotMatch(sql, /(?:invoice_extraction_runs|invoice_extraction_candidates|http_post|net\.http)/i);
  assert.doesNotMatch(sql, /\bDROP\s+(?:TABLE|COLUMN)\b/i);
  assert.doesNotMatch(sql, /\b(?:DELETE FROM|TRUNCATE)\b/i);
  assert.doesNotMatch(sql, /\b(?:CREATE POLICY|DROP POLICY|ENABLE ROW LEVEL SECURITY)\b/i);
});

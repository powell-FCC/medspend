import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (path: string) => readFile(new URL(path, import.meta.url), 'utf8');

test('structured draft seeding is atomic, organization-scoped, idempotent, and preserves edited or completed drafts', async () => {
  const sql = await read('../supabase/migrations/20260812120000_phase3a3_structured_invoice_extraction.sql');
  assert.match(sql, /FOR UPDATE/);
  assert.match(sql, /_job\.extraction_result IS NOT NULL THEN RETURN false/);
  assert.match(sql, /_invoice\.processing_status = 'completed' OR _invoice\.posted_at IS NOT NULL/);
  assert.match(sql, /_pristine := _invoice\.vendor_name IS NULL/);
  assert.match(sql, /NOT EXISTS \(SELECT 1 FROM public\.invoice_items WHERE invoice_id = _invoice\.id\)/);
  assert.match(sql, /organization_id = _organization_id/);
  assert.match(sql, /has_org_role\(_organization_id, auth\.uid\(\)/);
});

test('Phase 3A.3 keeps approval and inventory posting unchanged', async () => {
  const server = await read('../src/lib/invoice-processing.functions.ts');
  assert.equal((server.match(/rpc\('post_reviewed_invoice'/g) ?? []).length, 1);
  const migration = await read('../supabase/migrations/20260812120000_phase3a3_structured_invoice_extraction.sql');
  assert.doesNotMatch(migration, /post_reviewed_invoice|inventory_items|inventory_adjustments/);
});

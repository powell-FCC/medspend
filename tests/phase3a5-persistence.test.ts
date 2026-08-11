import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
const root = new URL("../", import.meta.url);
const migration = await readFile(
  new URL("supabase/migrations/20260813140000_phase3a5_document_identity.sql", root),
  "utf8",
);
const server = await readFile(new URL("src/lib/invoice-processing.functions.ts", root), "utf8");

test("document/order identity has dedicated non-overloaded invoice columns", () => {
  assert.match(migration, /ADD COLUMN document_type/);
  assert.match(migration, /ADD COLUMN order_number/);
  assert.match(migration, /ADD COLUMN order_date/);
});
test("vendor signatures are organization/vendor scoped, unique, RLS protected, and owner controlled", () => {
  assert.match(migration, /vendor_identity_signatures_vendor_org_fk/);
  assert.match(migration, /organization_id, signature_type, normalized_value/);
  assert.match(migration, /ENABLE ROW LEVEL SECURITY/);
  assert.match(migration, /vendor_identity_signatures_owner_all/);
  assert.match(migration, /has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]/);
});
test("automatic vendor identification invokes existing product rematching and preserves owner authority", () => {
  assert.match(server, /vendorMatch\.state === 'MATCHED'[\s\S]*rematch_invoice_vendor_products/);
  assert.match(server, /vendor_identity_reviewed/);
  assert.match(server, /remember_invoice_vendor_signatures/);
});
test("migration does not backfill or alter completed historical documents", () => {
  assert.doesNotMatch(migration, /UPDATE public\.invoices\s+SET document_type/);
  assert.match(migration, /processing_status <> 'completed' AND posted_at IS NULL/);
});

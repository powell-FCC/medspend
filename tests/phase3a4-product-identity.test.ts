import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const migration = await readFile(
  new URL("supabase/migrations/20260813120000_phase3a4_product_identity.sql", root),
  "utf8",
);
const server = await readFile(new URL("src/lib/invoice-processing.functions.ts", root), "utf8");
const page = await readFile(
  new URL("src/components/invoice-processing/InvoiceReviewPage.tsx", root),
  "utf8",
);

test("owner-only transactional functions scope every decision to the organization and draft invoice", () => {
  assert.match(migration, /has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]/);
  assert.match(
    migration,
    /organization_id = _organization_id AND source_file_id = _source_file_id FOR UPDATE/g,
  );
  assert.match(migration, /Completed invoices cannot be changed/g);
  assert.match(migration, /organization_id = _organization_id/g);
});

test("confirmation remembers or corrects a vendor mapping and unlink can forget it", () => {
  assert.match(migration, /UPDATE public\.vendor_products SET product_id = _product_id/);
  assert.match(migration, /INSERT INTO public\.vendor_products/);
  assert.match(migration, /IF _forget_mapping.*SET active = false/s);
});

test("new product creation is line-derived and idempotent for a linked line", () => {
  assert.match(migration, /IF _line\.product_id IS NOT NULL THEN/);
  assert.match(migration, /btrim\(_line\.description\)/);
  assert.match(migration, /This vendor SKU already maps to another product/);
});

test("approval has a server-side unresolved identity gate while posting RPC remains untouched", () => {
  assert.match(server, /is\('product_id', null\)/);
  assert.match(server, /Match or create a product for every invoice line before approval/);
  assert.equal((migration.match(/post_reviewed_invoice/g) ?? []).length, 0);
  assert.match(page, /must be matched to a product before approval/);
  assert.match(page, /unresolvedCount > 0/);
});

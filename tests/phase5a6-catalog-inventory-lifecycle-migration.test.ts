import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const migration = await readFile(
  new URL("supabase/migrations/20260831140000_phase5a6_catalog_inventory_stocking.sql", root),
  "utf8",
);
const inventoryExpansion = await readFile(
  new URL("supabase/migrations/20260808120000_phase2c5_expand.sql", root),
  "utf8",
);
const inventoryPosting = await readFile(
  new URL("supabase/migrations/20260809120000_phase2d_manual_invoice_review.sql", root),
  "utf8",
);
const verification = await readFile(
  new URL("supabase/verification/phase5a6_catalog_inventory_stocking.sql", root),
  "utf8",
);
const behavior = await readFile(
  new URL("supabase/tests/phase5a6_catalog_inventory_stocking_behavior.sql", root),
  "utf8",
);

const rpc = migration.match(
  /CREATE OR REPLACE FUNCTION public\.stock_catalog_vendor_product\([\s\S]*?\n\$\$;/,
)?.[0];

test("Phase 5A.6 relies on the deployed organization-product FK and unique index", () => {
  assert.match(
    inventoryExpansion,
    /CONSTRAINT inventory_items_product_org_fk[\s\S]*?FOREIGN KEY \(product_id, organization_id\)[\s\S]*?REFERENCES public\.products\(id, organization_id\) NOT VALID/,
  );
  assert.match(
    inventoryPosting,
    /CREATE UNIQUE INDEX inventory_items_org_product_uq[\s\S]*?\(organization_id, product_id\)[\s\S]*?WHERE product_id IS NOT NULL/,
  );
  assert.match(migration, /inventory_items_org_product_uq/);
  assert.match(migration, /index_definition\.indisunique/);
  assert.match(migration, /index_definition\.indisvalid/);
  assert.match(migration, /index_definition\.indisready/);
  assert.match(migration, /pg_catalog\.pg_get_indexdef/);
});

test("Phase 5A.6 migration adds only the narrow stocking RPC", () => {
  assert.ok(rpc);
  const outsideRpc = migration.replace(rpc, "");
  assert.equal(migration.match(/CREATE OR REPLACE FUNCTION/g)?.length, 1);
  assert.equal(migration.match(/\bDO \$\$/g)?.length, 1);
  assert.doesNotMatch(
    migration,
    /\b(?:CREATE|DROP) (?:TABLE|INDEX|TRIGGER|POLICY)\b|\bALTER TABLE\b/i,
  );
  assert.doesNotMatch(migration, /\b(?:GRANT|REVOKE)\b[\s\S]*?\bON TABLE\b/i);
  assert.doesNotMatch(outsideRpc, /\b(?:INSERT INTO|UPDATE|DELETE FROM) public\.[a-z_]+/i);
});

test("stocking RPC is owner-admin authorized and product-scoped for concurrency", () => {
  assert.ok(rpc);
  assert.match(rpc, /SECURITY DEFINER/);
  assert.match(rpc, /SET search_path = public/);
  assert.match(rpc, /public\.is_org_admin\(_organization_id, auth\.uid\(\)\)/);
  assert.match(rpc, /USING ERRCODE = '42501'/);
  assert.match(rpc, /pg_advisory_xact_lock/);
  assert.match(
    rpc,
    /'catalog-inventory:' \|\| _organization_id::text \|\| ':' \|\| _organization_product\.id::text/,
  );
  assert.ok(rpc.indexOf("public.is_org_admin") < rpc.indexOf("pg_advisory_xact_lock"));
});

test("stocking requires and validates the exact adopted organization identity chain", () => {
  assert.ok(rpc);
  assert.match(
    rpc,
    /FROM public\.vendor_products[\s\S]*?organization_id = _organization_id[\s\S]*?catalog_vendor_product_id = _catalog_vendor_product\.id/,
  );
  assert.match(rpc, /Adopt this catalog product before adding it to inventory/);
  assert.match(rpc, /FROM public\.vendors[\s\S]*?organization_id = _organization_id/);
  assert.match(rpc, /FROM public\.products[\s\S]*?organization_id = _organization_id/);
  assert.match(rpc, /_organization_vendor\.catalog_vendor_id IS DISTINCT FROM _catalog_vendor\.id/);
  assert.match(
    rpc,
    /_organization_product\.catalog_product_id IS DISTINCT FROM _catalog_product\.id/,
  );
  assert.match(rpc, /USING ERRCODE = '23514'/);
});

test("stocking creates only one zero-quantity inventory row linked to the existing product", () => {
  assert.ok(rpc);
  const mutationTargets = [
    ...rpc.matchAll(/\b(?:INSERT INTO|UPDATE|DELETE FROM) public\.([a-z_]+)/gi),
  ].map((match) => match[1]);
  assert.deepEqual([...new Set(mutationTargets)], ["inventory_items"]);
  assert.match(
    rpc,
    /INSERT INTO public\.inventory_items \([\s\S]*?organization_id,[\s\S]*?product_id,[\s\S]*?quantity,[\s\S]*?par_level,[\s\S]*?VALUES \([\s\S]*?_organization_id,[\s\S]*?_organization_product\.id,[\s\S]*?_inventory_unit,[\s\S]*?0,[\s\S]*?_par_level/,
  );
  assert.doesNotMatch(rpc, /INSERT INTO public\.inventory_adjustments/);
  assert.doesNotMatch(rpc, /INSERT INTO public\.inventory_price_history/);
  assert.doesNotMatch(rpc, /_catalog_vendor_product\.package_quantity/);
});

test("repeated or concurrent stocking reuses only the exact organization-product row", () => {
  assert.ok(rpc);
  assert.match(
    rpc,
    /FROM public\.inventory_items[\s\S]*?organization_id = _organization_id[\s\S]*?product_id = _organization_product\.id[\s\S]*?FOR UPDATE/,
  );
  assert.match(rpc, /IF FOUND THEN[\s\S]*?'inventoryCreated', false[\s\S]*?'alreadyStocked', true/);
  assert.match(rpc, /WHEN unique_violation THEN/);
  assert.match(rpc, /IF NOT FOUND THEN[\s\S]*?RAISE;/);
  assert.match(rpc, /'inventoryCreated', _inventory_created/);
  assert.match(rpc, /'alreadyStocked', NOT _inventory_created/);
});

test("package, quantity, par, and discontinued rules remain conservative", () => {
  assert.ok(rpc);
  assert.match(
    rpc,
    /WHEN _catalog_vendor_product\.package_status = 'verified'[\s\S]*?_catalog_vendor_product\.package_unit[\s\S]*?ELSE _requested_unit/,
  );
  assert.match(rpc, /explicit inventory unit is required for source-only or unknown packages/);
  assert.match(rpc, /_par_level IS NOT NULL AND _par_level < 0/);
  assert.match(rpc, /_catalog_vendor_product\.discontinued/);
  assert.match(rpc, /Inactive or discontinued catalog products cannot create new active inventory/);
  assert.ok(
    rpc.indexOf("'alreadyStocked', true") < rpc.indexOf("IF _catalog_vendor_product.discontinued"),
  );
});

test("stocking RPC exposes only authenticated execution", () => {
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.stock_catalog_vendor_product\(uuid, uuid, text, numeric\) FROM PUBLIC;/,
  );
  assert.match(
    migration,
    /REVOKE EXECUTE ON FUNCTION public\.stock_catalog_vendor_product\(uuid, uuid, text, numeric\) FROM anon;/,
  );
  assert.match(
    migration,
    /GRANT EXECUTE ON FUNCTION public\.stock_catalog_vendor_product\(uuid, uuid, text, numeric\) TO authenticated;/,
  );
});

test("Phase 5A.6 deployment verification is one strict read-only PASS-FAIL query", () => {
  const executable = verification.replace(/^\s*--.*$/gm, "").trim();
  const structure = executable.replace(/'(?:''|[^'])*'/gs, "''");
  assert.match(executable, /^WITH\b/);
  assert.equal(structure.match(/;/g)?.length, 1);
  assert.match(executable, /CASE WHEN pg_catalog\.bool_and\(passed\) THEN 'PASS' ELSE 'FAIL' END/);
  assert.doesNotMatch(
    structure,
    /^\s*(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP|GRANT|REVOKE|CALL|DO)\b/im,
  );
  assert.match(
    verification,
    /to_regprocedure\([\s\S]*?'public\.stock_catalog_vendor_product\(uuid,uuid,text,numeric\)'/,
  );
  assert.match(
    verification,
    /has_function_privilege\('authenticated', rpc\.oid, 'EXECUTE'\)[\s\S]*?has_function_privilege\('anon', rpc\.oid, 'EXECUTE'\)[\s\S]*?has_function_privilege\('public', rpc\.oid, 'EXECUTE'\)/,
  );
});

test("rollback-only behavior covers authorization, lifecycle, isolation, and immutability", () => {
  assert.match(behavior, /^\s*--[\s\S]*?\bBEGIN;/);
  assert.doesNotMatch(behavior, /\bCOMMIT\b/i);
  assert.equal(behavior.match(/\bROLLBACK;/gi)?.length, 1);
  assert.match(behavior, /Staff stocking unexpectedly succeeded/);
  assert.match(behavior, /Not-adopted catalog product unexpectedly stocked/);
  assert.match(behavior, /Repeated stocking was not idempotent/);
  assert.match(behavior, /Cross-organization stocking unexpectedly succeeded/);
  assert.match(behavior, /Source-only package stocked without an explicit unit/);
  assert.match(behavior, /Unknown package stocked without an explicit unit/);
  assert.match(behavior, /Discontinued catalog product unexpectedly created active inventory/);
  assert.match(behavior, /quantity <> 0/);
  assert.match(behavior, /inventory_adjustments/);
  assert.match(behavior, /inventory_price_history/);
  assert.match(behavior, /Stocking created or changed organization catalog identity counts/);
  assert.match(behavior, /Phase 5A\.6 stocking mutated global catalog rows/);
  assert.match(behavior, /Phase 5A\.6 rollback-only test left persistent fixture rows/);
});

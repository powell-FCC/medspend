import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const migration = await readFile(
  new URL("supabase/migrations/20260827120000_phase5a5_catalog_adoption.sql", root),
  "utf8",
);
const privilegeCorrection = await readFile(
  new URL(
    "supabase/migrations/20260831120000_phase5a5_rpc_privilege_hardening.sql",
    root,
  ),
  "utf8",
);
const verification = await readFile(
  new URL("supabase/verification/phase5a5_catalog_adoption.sql", root),
  "utf8",
);
const behavior = await readFile(
  new URL("supabase/tests/phase5a5_catalog_adoption_behavior.sql", root),
  "utf8",
);

const rpc = migration.match(
  /CREATE OR REPLACE FUNCTION public\.adopt_catalog_vendor_product\([\s\S]*?\n\$\$;/,
)?.[0];

test("Phase 5A.5 preflights and uniquely constrains every organization catalog link", () => {
  assert.match(
    migration,
    /GROUP BY organization_id, catalog_vendor_id[\s\S]*?HAVING count\(\*\) > 1/,
  );
  assert.match(
    migration,
    /GROUP BY organization_id, catalog_product_id[\s\S]*?HAVING count\(\*\) > 1/,
  );
  assert.match(
    migration,
    /GROUP BY organization_id, catalog_vendor_product_id[\s\S]*?HAVING count\(\*\) > 1/,
  );
  assert.match(
    migration,
    /CREATE UNIQUE INDEX vendors_org_catalog_vendor_uq[\s\S]*?\(organization_id, catalog_vendor_id\)[\s\S]*?WHERE catalog_vendor_id IS NOT NULL/,
  );
  assert.match(
    migration,
    /CREATE UNIQUE INDEX products_org_catalog_product_uq[\s\S]*?\(organization_id, catalog_product_id\)[\s\S]*?WHERE catalog_product_id IS NOT NULL/,
  );
  assert.match(
    migration,
    /CREATE UNIQUE INDEX vendor_products_org_catalog_vendor_product_uq[\s\S]*?\(organization_id, catalog_vendor_product_id\)[\s\S]*?WHERE catalog_vendor_product_id IS NOT NULL/,
  );
});

test("Phase 5A.5 rejects mismatched vendor-product parent links", () => {
  assert.match(
    migration,
    /organization_vendor\.catalog_vendor_id IS DISTINCT FROM catalog_vendor_product\.catalog_vendor_id/,
  );
  assert.match(
    migration,
    /organization_product\.catalog_product_id IS DISTINCT FROM catalog_vendor_product\.catalog_product_id/,
  );
  assert.match(migration, /CREATE TRIGGER vendor_products_validate_catalog_link/);
  assert.match(migration, /CREATE TRIGGER vendors_validate_catalog_link_change/);
  assert.match(migration, /CREATE TRIGGER products_validate_catalog_link_change/);
  assert.match(migration, /CREATE TRIGGER catalog_vendor_products_validate_parent_link_change/);
  assert.equal(migration.match(/Cannot enforce catalog adoption consistency:/g)?.length, 2);
  assert.ok(
    migration.lastIndexOf("Cannot enforce catalog adoption consistency:") >
      migration.indexOf("CREATE TRIGGER catalog_vendor_products_validate_parent_link_change"),
  );
});

test("Phase 5A.5 adoption RPC is owner-admin scoped and concurrency serialized", () => {
  assert.ok(rpc);
  assert.match(rpc, /SECURITY DEFINER/);
  assert.match(rpc, /SET search_path = public/);
  assert.match(rpc, /public\.is_org_admin\(_organization_id, auth\.uid\(\)\)/);
  assert.match(rpc, /USING ERRCODE = '42501'/);
  assert.match(rpc, /pg_advisory_xact_lock/);
  assert.match(rpc, /'catalog-adoption:' \|\| _organization_id::text/);
  assert.ok(rpc.indexOf("public.is_org_admin") < rpc.indexOf("pg_advisory_xact_lock"));
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.adopt_catalog_vendor_product\(uuid, uuid\) FROM PUBLIC;/,
  );
  assert.match(
    migration,
    /GRANT EXECUTE ON FUNCTION public\.adopt_catalog_vendor_product\(uuid, uuid\) TO authenticated;/,
  );
});

test("Phase 5A.5 RPC privilege correction contains only the exact intended ACL changes", () => {
  assert.equal(
    privilegeCorrection.trim(),
    [
      "REVOKE EXECUTE ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) FROM anon;",
      "REVOKE EXECUTE ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) FROM PUBLIC;",
      "GRANT EXECUTE ON FUNCTION public.adopt_catalog_vendor_product(uuid, uuid) TO authenticated;",
    ].join("\n"),
  );
});

test("Phase 5A.5 adoption is idempotent and reuses exact organization identities", () => {
  assert.ok(rpc);
  assert.match(
    rpc,
    /catalog_vendor_product_id = _catalog_vendor_product\.id[\s\S]*?_already_adopted := FOUND/,
  );
  assert.match(rpc, /'alreadyAdopted', true/);
  assert.match(rpc, /catalog_vendor_id = _catalog_vendor\.id[\s\S]*?FOR UPDATE/);
  assert.match(
    rpc,
    /lower\(btrim\(vendor_sku\)\) = lower\(btrim\(_catalog_vendor_product\.vendor_sku\)\)/,
  );
  assert.match(
    rpc,
    /Multiple organization vendor products use exact vendor SKU[\s\S]*?manual reconciliation is required/,
  );
  assert.match(rpc, /catalog_product_id = _catalog_product\.id[\s\S]*?FOR UPDATE/);
});

test("Phase 5A.5 writes only organization catalog tables and never inventory or global catalog", () => {
  assert.ok(rpc);
  assert.match(rpc, /INSERT INTO public\.vendors/);
  assert.match(rpc, /INSERT INTO public\.products/);
  assert.match(rpc, /INSERT INTO public\.vendor_products/);
  assert.doesNotMatch(rpc, /\b(?:INSERT INTO|UPDATE|DELETE FROM) public\.catalog_/i);
  assert.doesNotMatch(rpc, /\b(?:INSERT INTO|UPDATE|DELETE FROM) public\.inventory/i);

  const mutationTargets = [
    ...rpc.matchAll(/\b(?:INSERT INTO|UPDATE|DELETE FROM) public\.([a-z_]+)/gi),
  ].map((match) => match[1]);
  assert.deepEqual([...new Set(mutationTargets)].sort(), [
    "products",
    "vendor_products",
    "vendors",
  ]);
});

test("Phase 5A.5 adopts every package status but trusts units only when verified", () => {
  assert.ok(rpc);
  assert.match(
    rpc,
    /WHEN _catalog_vendor_product\.package_status = 'verified'[\s\S]*?THEN _catalog_vendor_product\.package_unit[\s\S]*?ELSE NULL/,
  );
  assert.doesNotMatch(rpc, /package_status\s+(?:NOT\s+)?IN\s*\(/i);
  assert.doesNotMatch(rpc, /package_status\s*<>/i);
  assert.match(rpc, /_catalog_vendor_product\.package_description/);
});

test("Phase 5A.5 preserves local operational fields when linking existing rows", () => {
  assert.ok(rpc);
  const updates = [...rpc.matchAll(/UPDATE public\.([a-z_]+)\s+SET\s+([\s\S]*?)\s+WHERE/g)].map(
    (match) => ({ table: match[1], assignments: match[2].trim() }),
  );
  assert.deepEqual(updates, [
    { table: "vendors", assignments: "catalog_vendor_id = _catalog_vendor.id" },
    { table: "products", assignments: "catalog_product_id = _catalog_product.id" },
    {
      table: "vendor_products",
      assignments: "catalog_vendor_product_id = _catalog_vendor_product.id",
    },
  ]);
});

test("Phase 5A.5 migration itself performs no adoption or inventory mutation", () => {
  const beforeRpc = migration.slice(
    0,
    migration.indexOf("CREATE OR REPLACE FUNCTION public.adopt_catalog_vendor_product"),
  );
  assert.doesNotMatch(
    beforeRpc,
    /\bINSERT INTO public\.(?:vendors|products|vendor_products|inventory)/i,
  );
  assert.doesNotMatch(
    beforeRpc,
    /\bUPDATE public\.(?:vendors|products|vendor_products|inventory)/i,
  );
  assert.doesNotMatch(
    beforeRpc,
    /\bDELETE FROM public\.(?:vendors|products|vendor_products|inventory)/i,
  );
});

test("Phase 5A.5 migration changes only its intended schema and function privilege surface", () => {
  assert.doesNotMatch(
    migration,
    /\b(?:CREATE|DROP) POLICY\b|\bALTER TABLE\b|\bCREATE TABLE\b|\bDROP TABLE\b/i,
  );
  assert.doesNotMatch(migration, /\b(?:GRANT|REVOKE)\b[\s\S]*?\bON TABLE\b/i);
  assert.equal(migration.match(/CREATE UNIQUE INDEX/g)?.length, 3);
  assert.equal(migration.match(/CREATE OR REPLACE FUNCTION/g)?.length, 3);
  assert.equal(migration.match(/CREATE TRIGGER/g)?.length, 4);
  assert.equal(migration.match(/REVOKE ALL ON FUNCTION/g)?.length, 3);
  assert.equal(migration.match(/GRANT EXECUTE ON FUNCTION/g)?.length, 1);
});

test("Phase 5A.5 deployment verification is one read-only PASS-FAIL query", () => {
  const executable = verification.replace(/^\s*--.*$/gm, "").trim();
  const structure = executable.replace(/'(?:''|[^'])*'/gs, "''");
  assert.match(executable, /^WITH\b/);
  assert.equal(structure.match(/;/g)?.length, 1);
  assert.match(executable, /CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END/);
  assert.doesNotMatch(
    structure,
    /^\s*(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP|GRANT|REVOKE|CALL|DO)\b/im,
  );

  for (const check of [
    "rpc_exists_with_exact_signature",
    "rpc_security_definer_intended",
    "rpc_search_path_hardened",
    "security_definer_schema_not_client_writable",
    "rpc_owner_admin_authorization_precedes_lock",
    "rpc_organization_scoped",
    "rpc_advisory_lock_is_organization_scoped",
    "rpc_exact_idempotent_reuse",
    "rpc_mutation_allowlist_exact",
    "rpc_never_touches_inventory",
    "rpc_global_catalog_is_read_only",
    "authenticated_rpc_execute_only",
    "phase5a5_behavioral_fixture_rows_absent",
    "organization_catalog_tables_keep_admin_only_writes",
    "authenticated_global_catalog_privileges_remain_read_only",
    "phase5a5_named_object_footprint_exact",
  ]) {
    assert.match(verification, new RegExp(`'${check}'`));
  }
});

test("Phase 5A.5 deployment verification checks exact indexes and trigger targets", () => {
  for (const objectName of [
    "vendors_org_catalog_vendor_uq",
    "products_org_catalog_product_uq",
    "vendor_products_org_catalog_vendor_product_uq",
    "vendor_products_validate_catalog_link",
    "vendors_validate_catalog_link_change",
    "products_validate_catalog_link_change",
    "catalog_vendor_products_validate_parent_link_change",
  ]) {
    assert.match(verification, new RegExp(objectName));
  }
  assert.match(verification, /pg_get_indexdef/);
  assert.match(verification, /pg_get_triggerdef/);
  assert.match(verification, /organization_catalog_policy_set_unchanged/);
  assert.match(verification, /global_catalog_policy_set_unchanged/);
  assert.match(verification, /array_agg\(policyname::text ORDER BY policyname::text\)/);
  assert.doesNotMatch(verification, /array_agg\(policyname ORDER BY policyname\)/);
  for (const catalogNameCast of [
    "relname::text",
    "proname::text",
    "nspname::text",
    "attname::text",
    "tgname::text",
    "policyname::text",
    "schemaname::text",
    "tablename::text",
  ]) {
    assert.match(verification, new RegExp(catalogNameCast.replace("::", "\\:\\:")));
  }
});

test("Phase 5A.5 RPC privilege verification reports each effective role predicate", () => {
  assert.match(
    verification,
    /procedure\.oid = pg_catalog\.to_regprocedure\(\s*'public\.adopt_catalog_vendor_product\(uuid,uuid\)'\s*\)/,
  );
  assert.match(
    verification,
    /rpc_execute_privileges AS \([\s\S]*?has_function_privilege\('authenticated', rpc\.oid, 'EXECUTE'\)[\s\S]*?has_function_privilege\('anon', rpc\.oid, 'EXECUTE'\)[\s\S]*?has_function_privilege\('public', rpc\.oid, 'EXECUTE'\)/,
  );
  assert.match(
    verification,
    /authenticated_can_execute[\s\S]*?AND NOT anon_can_execute[\s\S]*?AND NOT public_can_execute/,
  );
  assert.match(verification, /'authenticated=%s; anon=%s; PUBLIC=%s'/);
  assert.doesNotMatch(verification, /'authenticated has EXECUTE; anon and PUBLIC do not'/);
});

test("Phase 5A.5 behavioral SQL is SQL-Editor compatible and rollback-only", () => {
  assert.match(behavior, /^\s*--[\s\S]*?\bBEGIN;/);
  assert.doesNotMatch(behavior, /^\s*\\/m);
  assert.doesNotMatch(behavior, /\bCOMMIT\b/i);
  assert.doesNotMatch(behavior, /\bCREATE\s+(?:TEMP|TEMPORARY)\b/i);
  assert.doesNotMatch(behavior, /phase5a5_global_(?:count_)?snapshot/);
  assert.equal(behavior.match(/\bROLLBACK;/gi)?.length, 1);

  const rollbackAt = behavior.search(/\bROLLBACK;/i);
  const postRollback = behavior.slice(rollbackAt + "ROLLBACK;".length);
  assert.match(postRollback, /phase5a5_no_persistence/);
  assert.doesNotMatch(
    postRollback,
    /^\s*(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP|GRANT|REVOKE|CALL)\b/im,
  );
});

test("Phase 5A.5 behavioral SQL covers adoption, denial, immutability, and cleanup", () => {
  assert.match(behavior, /first_result := public\.adopt_catalog_vendor_product/);
  assert.match(behavior, /second_result := public\.adopt_catalog_vendor_product/);
  assert.match(behavior, /Repeated adoption was not idempotent/);
  assert.match(behavior, /package_status[\s\S]*?'verified'/);
  assert.match(behavior, /'source_only'/);
  assert.match(behavior, /'unknown'/);
  assert.match(behavior, /'TEST-DISCONTINUED'[\s\S]*?true,[\s\S]*?'verified'/);
  assert.match(behavior, /Conflicting local vendor-SKU identity was silently relinked/);
  assert.match(behavior, /Staff adoption unexpectedly succeeded/);
  assert.match(behavior, /Staff direct organization catalog write unexpectedly succeeded/);
  assert.match(behavior, /Cross-organization adoption unexpectedly succeeded/);
  assert.match(behavior, /Catalog adoption created an inventory item/);
  assert.match(behavior, /_global_rows_before jsonb/);
  assert.match(behavior, /_global_rows_after jsonb/);
  assert.match(behavior, /_global_counts_before jsonb/);
  assert.match(behavior, /_global_counts_after jsonb/);
  assert.match(behavior, /_global_rows_after IS DISTINCT FROM _global_rows_before/);
  assert.match(behavior, /_global_counts_after IS DISTINCT FROM _global_counts_before/);
  assert.match(behavior, /Phase 5A\.5 rollback-only test left persistent fixture rows/);
});

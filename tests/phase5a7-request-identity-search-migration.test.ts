import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const migration = await readFile(
  new URL("supabase/migrations/20260901120000_phase5a7_request_identity_and_search.sql", root),
  "utf8",
);
const verification = await readFile(
  new URL("supabase/verification/phase5a7_request_identity_and_search.sql", root),
  "utf8",
);
const behavior = await readFile(
  new URL("supabase/tests/phase5a7_request_identity_and_search_behavior.sql", root),
  "utf8",
);
const server = await readFile(new URL("src/lib/supply-requests.functions.ts", root), "utf8");
const validation = await readFile(new URL("src/supply-requests/validation.ts", root), "utf8");
const generatedTypes = await readFile(new URL("src/integrations/supabase/types.ts", root), "utf8");
const staffRoute = await readFile(
  new URL("src/routes/_authenticated/staff/request.tsx", root),
  "utf8",
);

const submissionRpc = migration.match(
  /CREATE OR REPLACE FUNCTION public\.submit_supply_request\([\s\S]*?\n\$\$;/,
)?.[0];
const searchRpc = migration.match(
  /CREATE OR REPLACE FUNCTION public\.search_supply_request_products\([\s\S]*?\n\$\$;/,
)?.[0];

function stripSqlComments(sql: string) {
  return sql.replace(/^\s*--.*$/gm, "");
}

function splitTopLevelCsv(input: string) {
  const values: string[] = [];
  let start = 0;
  let depth = 0;
  let quoted = false;
  for (let index = 0; index < input.length; index += 1) {
    const character = input[index];
    if (quoted) {
      if (character === "'" && input[index + 1] === "'") {
        index += 1;
      } else if (character === "'") {
        quoted = false;
      }
      continue;
    }
    if (character === "'") quoted = true;
    else if (character === "(") depth += 1;
    else if (character === ")") depth -= 1;
    else if (character === "," && depth === 0) {
      values.push(input.slice(start, index).trim());
      start = index + 1;
    }
  }
  values.push(input.slice(start).trim());
  return values;
}

function fixtureInsertArity(table: string) {
  const escapedTable = table.replace(".", "\\.");
  const match = behavior.match(
    new RegExp(`INSERT INTO ${escapedTable} \\(\\s*([\\s\\S]*?)\\s*\\)\\s*VALUES\\s*([\\s\\S]*?);`),
  );
  assert.ok(match, `Missing fixture INSERT for ${table}`);
  const columnCount = splitTopLevelCsv(match[1]).length;
  const rowArities: number[] = [];
  const rows = match[2];
  let rowStart = -1;
  let depth = 0;
  let quoted = false;
  for (let index = 0; index < rows.length; index += 1) {
    const character = rows[index];
    if (quoted) {
      if (character === "'" && rows[index + 1] === "'") {
        index += 1;
      } else if (character === "'") {
        quoted = false;
      }
      continue;
    }
    if (character === "'") quoted = true;
    else if (character === "(") {
      if (depth === 0) rowStart = index + 1;
      depth += 1;
    } else if (character === ")") {
      depth -= 1;
      if (depth === 0 && rowStart >= 0) {
        rowArities.push(splitTopLevelCsv(rows.slice(rowStart, index)).length);
        rowStart = -1;
      }
    }
  }
  return { columnCount, rowArities };
}

test("Phase 5A.7 adds only nullable request identity columns and restrictive keys", () => {
  assert.match(
    migration,
    /ALTER TABLE public\.supply_request_items\s+ADD COLUMN inventory_item_id uuid,\s+ADD COLUMN vendor_product_id uuid,\s+ADD COLUMN catalog_vendor_product_id uuid;/,
  );
  assert.match(
    migration,
    /CREATE UNIQUE INDEX inventory_items_id_org_uq\s+ON public\.inventory_items \(id, organization_id\);/,
  );
  assert.match(
    migration,
    /CONSTRAINT supply_request_items_inventory_org_fk\s+FOREIGN KEY \(inventory_item_id, organization_id\)\s+REFERENCES public\.inventory_items\(id, organization_id\) ON DELETE RESTRICT/,
  );
  assert.match(
    migration,
    /CONSTRAINT supply_request_items_vendor_product_org_fk\s+FOREIGN KEY \(vendor_product_id, organization_id\)\s+REFERENCES public\.vendor_products\(id, organization_id\) ON DELETE RESTRICT/,
  );
  assert.match(
    migration,
    /CONSTRAINT supply_request_items_catalog_vendor_product_fk\s+FOREIGN KEY \(catalog_vendor_product_id\)\s+REFERENCES public\.catalog_vendor_products\(id\) ON DELETE RESTRICT/,
  );
  assert.equal(migration.match(/\bADD COLUMN\b/g)?.length, 3);
  assert.equal(migration.match(/\bADD CONSTRAINT\b/g)?.length, 4);
  assert.equal(migration.match(/\bDROP CONSTRAINT\b/g)?.length, 1);
  assert.match(migration, /to_regclass\('public\.inventory_items_id_org_uq'\) IS NOT NULL/);
  assert.match(migration, /procedure\.proname = 'search_supply_request_products'/);
  assert.doesNotMatch(migration, /\bDROP (?:TABLE|COLUMN)\b|\bTRUNCATE\b/i);
  assert.doesNotMatch(migration, /ALTER TABLE public\.supply_requests\b/i);
  assert.doesNotMatch(migration, /Phase 5A\.8|Phase 5B|Phase 5C|Phase 5D|notifications/i);
});

test("Phase 5A.7 identity check is custom XOR one-or-more structured identities", () => {
  assert.match(
    migration,
    /DROP CONSTRAINT supply_request_items_identity_check,\s+ADD CONSTRAINT supply_request_items_identity_check CHECK/,
  );
  assert.match(
    migration,
    /nullif\(btrim\(free_text_item\), ''\) IS NOT NULL[\s\S]*?product_id IS NULL[\s\S]*?inventory_item_id IS NULL[\s\S]*?vendor_product_id IS NULL[\s\S]*?catalog_vendor_product_id IS NULL/,
  );
  assert.match(
    migration,
    /free_text_item IS NULL[\s\S]*?product_id IS NOT NULL[\s\S]*?OR inventory_item_id IS NOT NULL[\s\S]*?OR vendor_product_id IS NOT NULL[\s\S]*?OR catalog_vendor_product_id IS NOT NULL/,
  );
  assert.doesNotMatch(migration, /product_id IS NOT NULL\s+AND inventory_item_id IS NULL/);
});

test("Phase 5A.7 migration performs no backfill or lifecycle/catalog/inventory writes", () => {
  assert.ok(submissionRpc);
  assert.ok(searchRpc);
  const outsideFunctions = stripSqlComments(
    migration.replace(submissionRpc, "").replace(searchRpc, ""),
  );
  assert.doesNotMatch(outsideFunctions, /\b(?:INSERT INTO|UPDATE|DELETE FROM)\s+public\.[a-z_]+/i);
  assert.doesNotMatch(outsideFunctions, /\badopt_catalog_vendor_product\s*\(/i);
  assert.doesNotMatch(outsideFunctions, /\bstock_catalog_vendor_product\s*\(/i);
  assert.equal(migration.match(/^CREATE OR REPLACE FUNCTION/gm)?.length, 2);
  assert.equal(migration.match(/^CREATE UNIQUE INDEX/gm)?.length, 1);
  assert.equal(migration.match(/^CREATE INDEX/gm)?.length, 3);
  assert.equal(migration.match(/^CREATE (?:TABLE|TRIGGER|POLICY)/gm)?.length ?? 0, 0);
});

test("submission keeps its signature and validates every exact identity relationship", () => {
  assert.ok(submissionRpc);
  assert.match(submissionRpc, /SECURITY DEFINER/);
  assert.match(submissionRpc, /SET search_path = public/);
  assert.match(submissionRpc, /organization_memberships[\s\S]*?active = true/);
  for (const key of [
    "inventoryItemId",
    "vendorProductId",
    "productId",
    "catalogVendorProductId",
    "freeTextItem",
  ]) {
    assert.match(submissionRpc, new RegExp(key));
  }
  assert.match(
    submissionRpc,
    /_product_id := _inventory\.product_id[\s\S]*?_product_id := _vendor_product\.product_id[\s\S]*?_catalog_vendor_product_id := _vendor_product\.catalog_vendor_product_id/,
  );
  assert.match(submissionRpc, /inventory\.product_id IS NULL/);
  assert.match(submissionRpc, /organization_id = _organization_id/);
  assert.match(submissionRpc, /vendor_product\.active = true/);
  assert.match(submissionRpc, /staff_requestable = true/);
  assert.match(submissionRpc, /catalog_vendor_product\.active = true/);
  assert.match(submissionRpc, /catalog_vendor_product\.discontinued = false/);
  assert.match(submissionRpc, /unproven global catalog identity/);

  const mutationTargets = [
    ...submissionRpc.matchAll(/\b(?:INSERT INTO|UPDATE|DELETE FROM)\s+public\.([a-z_]+)/gi),
  ].map((match) => match[1]);
  assert.deepEqual([...new Set(mutationTargets)].sort(), [
    "supply_request_items",
    "supply_requests",
  ]);
  assert.doesNotMatch(submissionRpc, /\b(?:adopt|stock)_catalog_vendor_product\s*\(/i);
});

test("submission and search RPC ACLs are authenticated-only and exact", () => {
  for (const signature of [
    "public\\.submit_supply_request\\(\\s*uuid,\\s*public\\.supply_request_type,\\s*uuid,\\s*uuid,\\s*text,\\s*jsonb\\s*\\)",
    "public\\.search_supply_request_products\\(uuid, text, integer\\)",
  ]) {
    assert.match(migration, new RegExp(`REVOKE ALL ON FUNCTION ${signature} FROM PUBLIC;`));
    assert.match(migration, new RegExp(`REVOKE EXECUTE ON FUNCTION ${signature} FROM anon;`));
    assert.match(
      migration,
      new RegExp(`GRANT EXECUTE ON FUNCTION ${signature}\\s+TO authenticated;`),
    );
  }
});

test("unified search is bounded, read-only, staff-safe, and set-based", () => {
  assert.ok(searchRpc);
  assert.match(searchRpc, /_limit integer DEFAULT 20/);
  assert.match(searchRpc, /LANGUAGE plpgsql\s+STABLE\s+SECURITY DEFINER/);
  assert.match(searchRpc, /SET search_path = public/);
  assert.match(searchRpc, /organization_memberships[\s\S]*?membership\.active = true/);
  assert.ok(searchRpc.indexOf("organization_memberships") < searchRpc.indexOf("RETURN QUERY"));
  assert.match(searchRpc, /length\(_raw_query\) > 120/);
  assert.match(searchRpc, /LEAST\(GREATEST\(COALESCE\(_limit, 20\), 1\), 50\)/);
  assert.match(searchRpc, /LIMIT _bounded_limit/);
  assert.match(searchRpc, /global_candidates AS/);
  assert.match(searchRpc, /local_vendor_candidates AS/);
  assert.match(searchRpc, /local_product_candidates AS/);
  assert.match(searchRpc, /unlinked_inventory_candidates AS/);
  assert.doesNotMatch(searchRpc, /\b(?:INSERT INTO|UPDATE|DELETE FROM|TRUNCATE)\b/i);

  for (const safeField of [
    "result_key text",
    "identity_source text",
    "product_name text",
    "manufacturer text",
    "vendor_name text",
    "vendor_sku text",
    "package_display text",
    "package_status text",
    "inventory_item_id uuid",
    "product_id uuid",
    "vendor_product_id uuid",
    "catalog_vendor_product_id uuid",
  ]) {
    assert.match(searchRpc, new RegExp(safeField.replace("_", "_")));
  }
  assert.doesNotMatch(
    searchRpc,
    /catalog_(?:source_records|verification_overrides|import_batches)|source_uri|checksum|provenance|notes/,
  );
});

test("search ranking, identity-only dedupe, and package trust remain conservative", () => {
  assert.ok(searchRpc);
  assert.match(searchRpc, /candidate\.organization_sku = _normalized_sku THEN 0/);
  assert.match(searchRpc, /candidate\.global_sku = _normalized_sku THEN 1/);
  assert.match(searchRpc, /candidate\.primary_name = _normalized_text[\s\S]*?THEN 2/);
  assert.match(searchRpc, /manufacturer_search[\s\S]*?vendor_search[\s\S]*?THEN 4/);
  assert.match(searchRpc, /description_search[\s\S]*?THEN 5/);
  assert.match(searchRpc, /PARTITION BY scored\.identity_key/);
  assert.match(searchRpc, /deduplicated\.identity_rank = 1/);
  assert.match(searchRpc, /'organization-product:' \|\|/);
  assert.match(searchRpc, /'catalog-vendor-product:' \|\|/);
  assert.doesNotMatch(searchRpc, /vendor_sku_match_key/);
  assert.match(
    searchRpc,
    /WHEN 'verified' THEN concat_ws\([\s\S]*?package_quantity::text[\s\S]*?package_unit/,
  );
  assert.match(searchRpc, /WHEN 'source_only' THEN COALESCE\([\s\S]*?package_description/);
  assert.match(searchRpc, /ELSE 'Unknown'/);
  assert.doesNotMatch(searchRpc, /package_quantity::integer/);
});

test("backend plumbing preserves new IDs without implementing the search UI", () => {
  for (const property of ["inventoryItemId", "vendorProductId", "catalogVendorProductId"]) {
    assert.match(validation, new RegExp(`${property}: z\\.string\\(\\)\\.uuid\\(\\)`));
    assert.match(server, new RegExp(property));
  }
  assert.match(server, /from\("catalog_vendor_products"\)/);
  assert.match(server, /from\("inventory_items"\)/);
  assert.match(server, /export const searchSupplyRequestProductsFn/);
  assert.match(server, /unifiedSupplyRequestSearchResultSchema\.array\(\)\.parse/);
  assert.match(server, /rpc\(\s*"search_supply_request_products"/);
  assert.doesNotMatch(staffRoute, /searchSupplyRequestProductsFn/);
});

test("generated database types expose the added line columns and search RPC", () => {
  const requestItems = generatedTypes.match(
    /supply_request_items: \{[\s\S]*?\n\s+supply_request_updates:/,
  )?.[0];
  assert.ok(requestItems);
  for (const column of ["inventory_item_id", "vendor_product_id", "catalog_vendor_product_id"]) {
    assert.match(requestItems, new RegExp(`${column}: string \\| null`));
  }
  assert.match(generatedTypes, /search_supply_request_products: \{/);
  assert.match(generatedTypes, /_limit\?: number/);
  assert.match(generatedTypes, /result_key: string/);
  assert.match(generatedTypes, /catalog_vendor_product_id: string/);
});

test("deployment verification is one strict read-only PASS-FAIL query", () => {
  const executable = stripSqlComments(verification).trim();
  const structure = executable.replace(/'(?:''|[^'])*'/gs, "''");
  assert.match(executable, /^WITH\b/);
  assert.equal(structure.match(/;/g)?.length, 1);
  assert.match(executable, /CASE WHEN pg_catalog\.bool_and\(passed\) THEN 'PASS' ELSE 'FAIL' END/);
  assert.doesNotMatch(
    structure,
    /^\s*(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP|GRANT|REVOKE|CALL|DO)\b/im,
  );
  for (const check of [
    "request_identity_columns_exact",
    "identity_check_custom_xor_structured",
    "inventory_fk_organization_scoped_restrictive",
    "vendor_product_fk_organization_scoped_restrictive",
    "catalog_vendor_product_fk_global_restrictive",
    "submission_supports_all_identity_inputs_and_legacy_inputs",
    "submission_mutation_allowlist_request_tables_only",
    "search_exact_signature_stable_and_hardened",
    "search_staff_safe_return_allowlist",
    "search_auth_membership_before_candidates",
    "search_bounded_read_only_mutation_surface",
    "search_package_trust_semantics",
    "search_deterministic_ranking_and_identity_dedupe",
    "search_acl_authenticated_only",
  ]) {
    assert.match(verification, new RegExp(`'${check}'`));
  }
});

test("behavioral SQL is rollback-only and covers the required safety matrix", () => {
  assert.match(behavior, /^\s*--[\s\S]*?\bBEGIN;/);
  assert.doesNotMatch(behavior, /\bCOMMIT\b/i);
  assert.equal(behavior.match(/\bROLLBACK;/gi)?.length, 1);
  const rollbackAt = behavior.search(/\bROLLBACK;/i);
  const afterRollback = behavior.slice(rollbackAt + "ROLLBACK;".length);
  assert.match(afterRollback, /phase5a7_no_persistence/);
  assert.doesNotMatch(
    afterRollback,
    /^\s*(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP|GRANT|REVOKE|CALL)\b/im,
  );
  for (const scenario of [
    "Staff could not search own organization",
    "Owner could not search request products",
    "Admin could not search request products",
    "Nonmember search unexpectedly succeeded",
    "Cross-organization search unexpectedly succeeded",
    "Anon search unexpectedly succeeded",
    "Inventory-backed exact-SKU result is incorrect",
    "Adopted unstocked source-only result is incorrect",
    "Global-only Accucold identity is incorrect",
    "Unlinked local and global identities were merged by text",
    "128-5852 and 128-5853 fixture identities were incorrectly deduplicated",
    "Inactive/discontinued 364-0444 appeared",
    "Existing product-only request compatibility failed",
    "Existing free-text request compatibility failed",
    "Global-only request identity was not preserved exactly",
    "Adopted request identity derivation failed",
    "Inventory request identity was not preserved exactly",
    "Conflicting client identity IDs unexpectedly succeeded",
    "Cross-organization local identity unexpectedly succeeded",
    "Free text plus structured identity unexpectedly succeeded",
    "Empty request-line identity unexpectedly succeeded",
    "submission mutated global catalog rows",
    "auto-adopted or created/changed organization inventory",
    "changed a historical request line",
    "rollback-only test left persistent fixture rows",
  ]) {
    assert.match(behavior, new RegExp(scenario.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  }
});

test("every behavioral fixture VALUES row matches its INSERT column arity", () => {
  for (const table of [
    "auth.users",
    "public.organizations",
    "public.teams",
    "public.locations",
    "public.organization_memberships",
    "public.catalog_vendors",
    "public.catalog_products",
    "public.catalog_vendor_products",
    "public.vendors",
    "public.products",
    "public.vendor_products",
    "public.inventory_items",
    "public.supply_requests",
    "public.supply_request_items",
  ]) {
    const { columnCount, rowArities } = fixtureInsertArity(table);
    assert.ok(rowArities.length > 0, `No VALUES rows found for ${table}`);
    assert.deepEqual(
      rowArities,
      rowArities.map(() => columnCount),
      `${table} has a VALUES row with the wrong arity`,
    );
  }
});

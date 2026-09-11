import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const migration = await readFile(
  new URL("supabase/migrations/20260911120000_phase5a8b_catalog_specification_search.sql", root),
  "utf8",
);
const behavior = await readFile(
  new URL("supabase/tests/phase5a8b_catalog_specification_search_behavior.sql", root),
  "utf8",
);
const catalogFunctions = await readFile(new URL("src/lib/catalog.functions.ts", root), "utf8");
const catalogTypes = await readFile(new URL("src/catalog-admin/catalog-admin.ts", root), "utf8");
const catalogPage = await readFile(
  new URL("src/components/catalog/CatalogAdminPage.tsx", root),
  "utf8",
);

const effectiveSpecificationFunction = migration.match(
  /CREATE OR REPLACE FUNCTION public\.get_catalog_vendor_product_effective_specifications\([\s\S]*?\n\$\$;/,
)?.[0];
const requestSpecificationFunction = migration.match(
  /CREATE OR REPLACE FUNCTION public\.get_supply_request_product_specifications\([\s\S]*?\n\$\$;/,
)?.[0];
const searchFunction = migration.match(
  /CREATE OR REPLACE FUNCTION public\.search_supply_request_products\([\s\S]*?\n\$\$;/,
)?.[0];
const adminDetailFunction = migration.match(
  /CREATE OR REPLACE FUNCTION public\.get_catalog_vendor_product_admin_detail\([\s\S]*?\n\$\$;/,
)?.[0];

test("effective specifications prefer one structured variant and narrowly recover APS blocks", () => {
  assert.ok(effectiveSpecificationFunction);
  assert.match(
    effectiveSpecificationFunction,
    /count\(DISTINCT source_context\.structured_specification\)/,
  );
  assert.match(effectiveSpecificationFunction, /distinct_specification_count = 1/);
  assert.match(effectiveSpecificationFunction, /distinct_specification_count = 0/);
  assert.match(effectiveSpecificationFunction, /raw_data -> 'fields' ->> 'Raw Product Block'/);
  assert.match(
    effectiveSpecificationFunction,
    /'\(' \|\| source_context\.normalized_vendor_sku \|\| '\)'/,
  );
  assert.match(effectiveSpecificationFunction, /pg_catalog\.replace[\s\S]*?= 1/);
  assert.match(effectiveSpecificationFunction, /\^#\[\[:alnum:\]\]/);
  assert.match(effectiveSpecificationFunction, /catalog_product\.verification_status = 'verified'/);
  assert.match(
    effectiveSpecificationFunction,
    /catalog_vendor_product\.verification_status = 'verified'/,
  );
  assert.doesNotMatch(effectiveSpecificationFunction, /verification_overrides|evidence/);
  assert.doesNotMatch(
    effectiveSpecificationFunction,
    /\b(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER)\b/i,
  );
});

test("the staff specification RPC keeps its signature, bounds, and membership guard", () => {
  assert.ok(requestSpecificationFunction);
  assert.match(
    requestSpecificationFunction,
    /_organization_id uuid,\s*_catalog_vendor_product_ids uuid\[\]/,
  );
  assert.match(requestSpecificationFunction, /membership\.active = true/);
  assert.match(
    requestSpecificationFunction,
    /cardinality\(_catalog_vendor_product_ids\), 0\) > 50/,
  );
  assert.match(requestSpecificationFunction, /get_catalog_vendor_product_effective_specifications/);
  assert.match(
    migration,
    /GRANT EXECUTE ON FUNCTION public\.get_supply_request_product_specifications\(uuid, uuid\[\]\) TO authenticated/,
  );
  assert.match(
    migration,
    /REVOKE EXECUTE ON FUNCTION public\.get_catalog_vendor_product_effective_specifications\(uuid\[\]\) FROM authenticated/,
  );
});

test("search applies AND tokens across effective specifications and metadata before limiting", () => {
  assert.ok(searchFunction);
  assert.match(searchFunction, /_query text,\s*_limit integer DEFAULT 20/);
  assert.match(searchFunction, /length\(_raw_query\) > 120/);
  assert.match(searchFunction, /LEAST\(GREATEST\(COALESCE\(_limit, 20\), 1\), 50\)/);
  assert.match(searchFunction, /effective_specifications AS[\s\S]*?global_candidates AS/);
  assert.match(searchFunction, /effective_specification\.specification[\s\S]*?AS search_text/);
  assert.match(searchFunction, /FROM pg_catalog\.unnest\(_tokens\) token/);
  assert.match(searchFunction, /pg_catalog\.strpos\(candidate\.search_text, token\) = 0/);
  assert.ok(
    searchFunction.indexOf("effective_specifications AS") <
      searchFunction.indexOf("LIMIT _bounded_limit"),
  );
  assert.match(searchFunction, /candidate\.organization_sku = _normalized_sku THEN 0/);
  assert.match(searchFunction, /candidate\.global_sku = _normalized_sku THEN 1/);
  assert.match(searchFunction, /catalog_vendor_product\.active = true/);
  assert.match(searchFunction, /catalog_vendor_product\.discontinued = false/);
  assert.doesNotMatch(searchFunction, /similarity\(|levenshtein|fuzzy/i);
  assert.doesNotMatch(searchFunction, /\b(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER)\b/i);
});

test("search-only normalization supports conservative mm and inch equivalence", () => {
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.normalize_catalog_search_text/);
  assert.match(migration, /\(mm\|millimeters\?\|millimetres\?\)\\y/);
  assert.match(migration, /\(inches\|inch\|in\)\\y/);
  assert.match(migration, /\[\"“”″\]\+/);
  assert.doesNotMatch(
    migration,
    /CREATE OR REPLACE FUNCTION public\.normalize_catalog_(?:text|sku)\(/,
  );
});

test("admin detail exposes the shared effective specification without raw evidence parsing in React", () => {
  assert.ok(adminDetailFunction);
  assert.match(
    adminDetailFunction,
    /'effectiveSpecification', effective_specification\.specification/,
  );
  assert.match(adminDetailFunction, /get_catalog_vendor_product_effective_specifications/);
  assert.match(
    catalogFunctions,
    /effectiveSpecification: z\.string\(\)\.trim\(\)\.min\(1\)\.nullable\(\)/,
  );
  assert.match(catalogTypes, /effectiveSpecification: string \| null/);
  assert.match(catalogPage, /\["Specification", detail\.effectiveSpecification\]/);
  assert.doesNotMatch(catalogPage, /Raw Product Block|raw_data|rawData|regexp_match/);
});

test("rollback-only behavior coverage includes recovery, ranking, access, and non-mutation", () => {
  assert.match(behavior, /^--[\s\S]*?\bBEGIN;/);
  assert.equal(behavior.match(/\bROLLBACK;/g)?.length, 1);
  assert.doesNotMatch(behavior, /\bCOMMIT\b/i);
  for (const expected of [
    "0.25 x 30 mm, Brown Tip",
    "0.30 x 30 mm, Gold Tip",
    "0.30 x 75 mm, Black Tip",
    "aps 30",
    "needle 50mm",
    "30mm",
    "30 mm",
    "brown tip",
    "box 100",
    "Exact vendor SKU did not outrank metadata decoy",
    "Exact adopted SKU ranking or linked identity collapse regressed",
    "Conflicting, unrelated, or malformed blank variants were not safely omitted",
    "Cross-organization specification lookup unexpectedly succeeded",
    "Inactive cross-organization member unexpectedly searched",
    "Distinct APS SKUs were merged or duplicated",
    "Token-order-independent search failed",
    "Staff unexpectedly accessed catalog admin detail",
    "Read-only retrieval mutated catalog state",
    "PHASE5A8B-DO-NOT-LEAK",
  ]) {
    assert.match(behavior, new RegExp(expected.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  }
  assert.match(behavior, /phase5a8b_catalog_specification_search_no_persistence/);
});

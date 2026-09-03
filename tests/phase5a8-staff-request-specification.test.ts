import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const migration = await readFile(
  new URL(
    "supabase/migrations/20260903150000_phase5a8_staff_request_specifications.sql",
    root,
  ),
  "utf8",
);
const searchMigration = await readFile(
  new URL("supabase/migrations/20260901120000_phase5a7_request_identity_and_search.sql", root),
  "utf8",
);
const transform = await readFile(
  new URL("scripts/catalog/henry-schein/transform.py", root),
  "utf8",
);
const server = await readFile(new URL("src/lib/supply-requests.functions.ts", root), "utf8");
const route = await readFile(
  new URL("src/routes/_authenticated/staff/request.tsx", root),
  "utf8",
);
const cart = await readFile(
  new URL("src/supply-requests/staff-request-cart.ts", root),
  "utf8",
);
const generatedTypes = await readFile(
  new URL("src/integrations/supabase/types.ts", root),
  "utf8",
);
const behavior = await readFile(
  new URL("supabase/tests/phase5a8_staff_request_specifications_behavior.sql", root),
  "utf8",
);

const specificationRpc = migration.match(
  /CREATE OR REPLACE FUNCTION public\.get_supply_request_product_specifications\([\s\S]*?\n\$\$;/,
)?.[0];

test("specifications come only from verified, unambiguous source variants", () => {
  assert.ok(specificationRpc);
  assert.match(specificationRpc, /source_record\.raw_variant/);
  assert.match(
    specificationRpc,
    /source_record\.matched_catalog_vendor_product_id = catalog_vendor_product\.id/,
  );
  assert.match(specificationRpc, /source_record\.resolution_status IN \('matched', 'verified_match'\)/);
  assert.match(specificationRpc, /catalog_product\.verification_status = 'verified'/);
  assert.match(specificationRpc, /catalog_vendor_product\.verification_status = 'verified'/);
  assert.match(
    specificationRpc,
    /HAVING count\(DISTINCT btrim\(source_record\.raw_variant\)\) = 1/,
  );
  assert.doesNotMatch(specificationRpc, /raw_vendor_sku_match_key|normalized_raw_vendor_sku/);
  assert.doesNotMatch(specificationRpc, /\b(?:INSERT|UPDATE|DELETE|TRUNCATE|ALTER)\b/i);
});

test("the source-backed canonical description already supports exact size searching", () => {
  assert.match(
    transform,
    /description = text_or_none\(master\.get\("Variant Examples"\)\)/,
  );
  assert.match(
    searchMigration,
    /concat_ws\(' ', adoption\.description, catalog_product\.description\)[\s\S]*?AS description_search/,
  );
  assert.match(
    searchMigration,
    /pg_catalog\.strpos\(candidate\.description_search, _normalized_text\) > 0 THEN 5/,
  );
});

test("specification lookup is bounded and active-organization-member only", () => {
  assert.ok(specificationRpc);
  assert.match(specificationRpc, /auth\.uid\(\) IS NULL/);
  assert.match(
    specificationRpc,
    /organization_memberships[\s\S]*?membership\.organization_id = _organization_id[\s\S]*?membership\.active = true/,
  );
  assert.ok(specificationRpc.indexOf("organization_memberships") < specificationRpc.indexOf("RETURN QUERY"));
  assert.match(specificationRpc, /cardinality\(_catalog_vendor_product_ids\), 0\) > 50/);
  assert.match(specificationRpc, /catalog_vendor_product\.active = true/);
  assert.match(specificationRpc, /catalog_vendor_product\.discontinued = false/);
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.get_supply_request_product_specifications\(uuid, uuid\[\]\)[\s\S]*?FROM PUBLIC;/,
  );
  assert.match(
    migration,
    /GRANT EXECUTE ON FUNCTION public\.get_supply_request_product_specifications\(uuid, uuid\[\]\)[\s\S]*?TO authenticated;/,
  );
});

test("the unified result gains display metadata without changing structured identity", () => {
  assert.match(server, /specification: string \| null/);
  assert.match(server, /"get_supply_request_product_specifications"/);
  assert.match(server, /specificationsByCatalogVendorProductId/);
  for (const identity of [
    "inventoryItemId: row.inventory_item_id",
    "productId: row.product_id",
    "vendorProductId: row.vendor_product_id",
    "catalogVendorProductId: row.catalog_vendor_product_id",
  ]) {
    assert.match(server, new RegExp(identity));
  }
  assert.match(cart, /specification: selection\.specification/);
  assert.match(cart, /freeTextItem: item\.freeTextItem/);
  assert.match(generatedTypes, /get_supply_request_product_specifications: \{/);
  assert.match(generatedTypes, /catalog_vendor_product_id: string/);
  assert.match(generatedTypes, /specification: string/);
});

test("the route renders name, then specification, then compact vendor metadata", () => {
  const resultBlock = route.match(
    /products\.data\.map\(\(product\) => \([\s\S]*?<ProductDetails product=\{product\} \/>[\s\S]*?\)\)}/,
  )?.[0];
  assert.ok(resultBlock);
  assert.ok(resultBlock.indexOf("product.productName") < resultBlock.indexOf("ProductDetails"));

  const detailsBlock = route.slice(
    route.indexOf("function ProductDetails"),
    route.indexOf("function RequestPage"),
  );
  assert.ok(detailsBlock.length > 0);
  assert.match(detailsBlock, /getStaffRequestProductDisplayLines\(product\)/);
  assert.match(detailsBlock, /line\.kind === "specification"/);
  assert.match(detailsBlock, /text-sm font-medium/);
  assert.match(detailsBlock, /text-xs/);
  assert.doesNotMatch(route, /source_record|sourceRecord|catalog implementation|package trust/i);
});

test("database behavior coverage is rollback-only and verifies safe omission and size search", () => {
  assert.match(behavior, /^--[\s\S]*?\bBEGIN;/);
  assert.equal(behavior.match(/\bROLLBACK;/g)?.length, 1);
  assert.doesNotMatch(behavior, /\bCOMMIT\b/i);
  assert.match(behavior, /search_supply_request_products\(_organization_id, '2 x 5 yd rolls'/);
  assert.match(behavior, /Source-backed specification was not returned exactly/);
  assert.match(behavior, /Missing or conflicting source variants were not omitted/);
  assert.match(behavior, /Cross-organization specification lookup unexpectedly succeeded/);
  assert.match(behavior, /phase5a8_specification_no_persistence/);
});

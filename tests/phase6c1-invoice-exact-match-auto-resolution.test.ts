import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import test from "node:test";
import { matchInvoiceProduct } from "../src/product-identity/matcher.ts";
import {
  AUTOMATIC_MATCH_LABEL,
  describeInvoiceLineReview,
  isAutomaticMatchSource,
  presentInvoiceLineMatch,
  toInvoiceLineMatchSource,
} from "../src/invoice/line-match.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const migrationName = "20261010120000_phase6c1_invoice_exact_match_auto_resolution.sql";
const migration = read(`../supabase/migrations/${migrationName}`);
const migrationCode = migration.replace(/--.*$/gm, "");
const behavior = read(
  "../supabase/tests/phase6c1_invoice_exact_match_auto_resolution_behavior.sql",
);
const mutationCheck = read("../supabase/tests/phase6c1_mutation_check.sh");
const server = read("../src/lib/invoice-processing.functions.ts");
const table = read("../src/components/invoice-processing/ReviewItemsTable.tsx");
const page = read("../src/components/invoice-processing/InvoiceReviewPage.tsx");
const types = read("../src/integrations/supabase/types.ts");

const between = (source: string, start: string, end: string) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end}`);
  return source.slice(from, to);
};

const finder = between(
  migrationCode,
  "CREATE FUNCTION public.find_invoice_line_exact_identity",
  "REVOKE ALL ON FUNCTION public.find_invoice_line_exact_identity",
);
const applier = between(
  migrationCode,
  "CREATE FUNCTION public.apply_invoice_exact_product_identities",
  "REVOKE ALL ON FUNCTION public.apply_invoice_exact_product_identities",
);
const resolver = between(
  migrationCode,
  "CREATE FUNCTION public.resolve_invoice_exact_product_identities",
  "REVOKE ALL ON FUNCTION public.resolve_invoice_exact_product_identities",
);
const rematch = between(
  migrationCode,
  "CREATE OR REPLACE FUNCTION public.rematch_invoice_vendor_products",
  "CREATE OR REPLACE FUNCTION public.confirm_invoice_item_product",
);
const confirm = between(
  migrationCode,
  "CREATE OR REPLACE FUNCTION public.confirm_invoice_item_product",
  "CREATE OR REPLACE FUNCTION public.unlink_invoice_item_product",
);
const unlink = between(
  migrationCode,
  "CREATE OR REPLACE FUNCTION public.unlink_invoice_item_product",
  "CREATE OR REPLACE FUNCTION public.create_product_from_invoice_item",
);
const create = between(
  migrationCode,
  "CREATE OR REPLACE FUNCTION public.create_product_from_invoice_item",
  "REVOKE ALL ON FUNCTION public.rematch_invoice_vendor_products",
);
const guard = between(
  migrationCode,
  "CREATE FUNCTION public.guard_invoice_item_match_provenance",
  "CREATE TRIGGER invoice_items_match_provenance_guard",
);

const org = "11111111-1111-4111-8111-111111111111";
const henrySchein = "22222222-2222-4222-8222-222222222222";
const medline = "33333333-3333-4333-8333-333333333333";
const gloves = {
  organizationId: org,
  id: "44444444-4444-4444-8444-444444444444",
  name: "Ammex Black PF Nitrile Gloves Medium",
  manufacturer: "Ammex",
  internalItemCode: "3980143",
};
const glovesMapping = {
  organizationId: org,
  id: "55555555-5555-4555-8555-555555555555",
  vendorId: henrySchein,
  productId: gloves.id,
  vendorSku: "398-0143",
};

test("a linked line is settled and says who decided it", () => {
  const unresolved = {
    state: "UNRESOLVED" as const,
    productId: null,
    vendorProductId: null,
    reasons: [],
  };
  for (const source of [
    "org_vendor_sku",
    "org_vendor_sku_match_key",
    "catalog_vendor_sku",
    "catalog_vendor_sku_match_key",
  ]) {
    const presented = presentInvoiceLineMatch(
      { productId: gloves.id, matchSource: source },
      unresolved,
    );
    assert.equal(presented.state, "CONFIRMED");
    assert.equal(presented.productId, gloves.id);
    assert.deepEqual(presented.reasons, [`AUTOMATIC_${source.toUpperCase()}`]);
  }
  for (const source of ["manual", null, "unknown"]) {
    assert.deepEqual(
      presentInvoiceLineMatch({ productId: gloves.id, matchSource: source }, unresolved).reasons,
      ["OWNER_CONFIRMED"],
    );
  }
});

test("browser-side exact evidence on an unlinked line is only a suggestion", () => {
  // The legacy matcher treats an internal item code as exact regardless of vendor and
  // strips separators; neither may make an authoritative identity any more.
  const line = { sku: "3980143", description: "Something else entirely", productId: null };
  const crossVendor = matchInvoiceProduct(line, org, medline, [gloves], [glovesMapping]);
  assert.equal(crossVendor.state, "EXACT");
  const presented = presentInvoiceLineMatch({ productId: null, matchSource: null }, crossVendor);
  assert.equal(presented.state, "SUGGESTED");
  assert.ok(presented.reasons.includes("OWNER_CONFIRMATION_REQUIRED"));

  const remembered = matchInvoiceProduct(
    { sku: "398 0143", description: "Gloves" },
    org,
    henrySchein,
    [{ ...gloves, internalItemCode: null }],
    [glovesMapping],
  );
  assert.equal(remembered.state, "EXACT");
  assert.equal(
    presentInvoiceLineMatch({ productId: null, matchSource: null }, remembered).state,
    "SUGGESTED",
  );
});

test("description, manufacturer, and package similarity stay suggestions or unresolved", () => {
  const descriptionOnly = matchInvoiceProduct(
    { sku: "", description: "Ammex Black PF Nitrile Gloves Medium", manufacturer: "Ammex" },
    org,
    henrySchein,
    [{ ...gloves, internalItemCode: null }],
    [],
  );
  assert.equal(descriptionOnly.state, "SUGGESTED");
  assert.equal(
    presentInvoiceLineMatch({ productId: null, matchSource: null }, descriptionOnly).state,
    "SUGGESTED",
  );
  const cleared = presentInvoiceLineMatch(
    { productId: null, matchSource: "manual_cleared" },
    descriptionOnly,
  );
  assert.equal(cleared.state, "SUGGESTED");
});

test("provenance values are a closed set and the copy is restrained", () => {
  assert.equal(AUTOMATIC_MATCH_LABEL, "Matched automatically by vendor SKU");
  assert.equal(isAutomaticMatchSource("manual"), false);
  assert.equal(isAutomaticMatchSource("catalog_vendor_sku_match_key"), true);
  assert.equal(toInvoiceLineMatchSource("manual_cleared"), "manual_cleared");
  assert.equal(toInvoiceLineMatchSource("fuzzy_description"), null);
  assert.equal(toInvoiceLineMatchSource(null), null);
});

test("the review subtitle is exception oriented", () => {
  const items = [
    { productId: "a", matchSource: "catalog_vendor_sku_match_key" },
    { productId: "b", matchSource: "org_vendor_sku" },
    { productId: "c", matchSource: "manual" },
    { productId: null, matchSource: null },
  ];
  assert.equal(
    describeInvoiceLineReview(items, false),
    "4 items · 2 matched automatically by vendor SKU · 1 needs review",
  );
  assert.equal(
    describeInvoiceLineReview(items.slice(0, 3), false),
    "3 items · 2 matched automatically by vendor SKU · all matched",
  );
  assert.equal(
    describeInvoiceLineReview(
      [
        { productId: null, matchSource: null },
        { productId: null, matchSource: "manual_cleared" },
      ],
      false,
    ),
    "2 items · 2 need review",
  );
  assert.equal(
    describeInvoiceLineReview(items.slice(0, 1), true),
    "1 item · 1 matched automatically by vendor SKU",
  );
});

test("migration is new, ordered after Phase 6C, transactional, and guarded", () => {
  const migrations = readdirSync(new URL("../supabase/migrations/", import.meta.url)).sort();
  assert.equal(migrations.at(-1), migrationName);
  assert.ok(
    migrations.indexOf(migrationName) >
      migrations.indexOf("20261009120000_phase6c_staff_request_forgiveness.sql"),
  );
  assert.match(migrationCode, /^\s*BEGIN;/m);
  assert.match(migrationCode, /COMMIT;\s*$/);
  assert.match(migrationCode, /Phase 6C\.1 has already been applied/);
  assert.match(
    migrationCode,
    /to_regprocedure\('public\.adopt_catalog_vendor_product\(uuid, uuid\)'\)/,
  );
});

test("identity decisions are vendor scoped and use only the existing SKU normalizers", () => {
  assert.match(
    finder,
    /mapping\.organization_id = _organization_id\s+AND mapping\.vendor_id = _vendor_id/,
  );
  assert.match(finder, /listing\.catalog_vendor_id = _catalog_vendor_id/);
  assert.match(finder, /public\.normalize_catalog_sku\(_sku\)/);
  assert.match(finder, /public\.normalize_catalog_sku_match_key\(_sku\)/);
  assert.match(finder, /_separator_free := _strict = _key;/);
  assert.match(finder, /IF _count = 0 AND _separator_free THEN/);
  assert.doesNotMatch(migrationCode, /FUNCTION public\.normalize_/);
  assert.doesNotMatch(migrationCode, /(UPDATE|INSERT INTO|DELETE FROM) public\.catalog_/);
  // No descriptive evidence participates in identity.
  assert.doesNotMatch(
    finder,
    /description|manufacturer|package|unit_of_measure|normalized_name|similar|\bI?LIKE\b|levenshtein|trgm/i,
  );
});

test("ambiguity, deactivation, verification, and vendor links block automation", () => {
  assert.match(finder, /'ambiguous_organization_mapping'/);
  assert.match(finder, /'ambiguous_catalog_listing'/);
  assert.match(finder, /IF NOT _mapping\.active THEN/);
  assert.match(finder, /'organization_mapping_conflict'/);
  assert.match(finder, /_listing\.verification_status <> 'verified'/);
  assert.match(finder, /catalog_product\.verification_status = 'verified'/);
  assert.match(finder, /_listing\.discontinued/);
  assert.match(finder, /IF _catalog_vendor_id IS NULL THEN[\s\S]*'vendor_not_linked_to_catalog'/);
  assert.doesNotMatch(migrationCode, /UPDATE public\.vendors/);
});

test("resolution touches only undecided lines and reuses the existing adoption RPC", () => {
  assert.match(
    applier,
    /AND product_id IS NULL\s+AND product_match_source IS NULL[\s\S]*FOR UPDATE/,
  );
  assert.match(
    applier,
    /WHERE id = _line\.id AND product_id IS NULL AND product_match_source IS NULL/,
  );
  assert.match(
    applier,
    /public\.adopt_catalog_vendor_product\(_organization_id, _decision\.catalog_vendor_product_id\)/,
  );
  assert.match(applier, /IS DISTINCT FROM _invoice\.vendor_id/);
  assert.doesNotMatch(applier, /INSERT INTO/);
  assert.doesNotMatch(applier, /UPDATE public\.invoices/);
  assert.match(applier, /'skipped', 'completed'/);
  assert.match(resolver, /SECURITY DEFINER/);
  assert.match(resolver, /has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]/);
  assert.match(resolver, /source_file_id = _source_file_id\s+FOR UPDATE/);
  assert.match(rematch, /product_match_source = NULL/);
  assert.match(
    rematch,
    /public\.apply_invoice_exact_product_identities\(_organization_id, _invoice\.id\)/,
  );
  assert.doesNotMatch(
    rematch,
    /lower\(btrim\(mapping\.vendor_sku\)\) = lower\(btrim\(item\.sku\)\)/,
  );
});

test("human decisions record provenance and API writes cannot forge machine provenance", () => {
  assert.match(confirm, /product_match_source = 'manual'/);
  assert.match(create, /product_match_source = 'manual'/);
  assert.match(unlink, /product_match_source = 'manual_cleared'/);
  assert.match(guard, /current_user IN \('authenticated', 'anon'\)/);
  assert.match(guard, /THEN NULL ELSE 'manual' END/);
  assert.match(guard, /NEW\.product_match_source := OLD\.product_match_source/);
  assert.match(migrationCode, /invoice_items_product_match_source_consistent/);
});

test("private helpers are not API callable and the RPC is owner-gated", () => {
  for (const helper of [
    "find_invoice_line_exact_identity(uuid, uuid, text)",
    "apply_invoice_exact_product_identities(uuid, uuid)",
    "guard_invoice_item_match_provenance()",
  ]) {
    assert.ok(
      migrationCode.includes(
        `REVOKE ALL ON FUNCTION public.${helper} FROM PUBLIC, anon, authenticated;`,
      ),
      helper,
    );
    assert.ok(!migrationCode.includes(`GRANT EXECUTE ON FUNCTION public.${helper}`), helper);
  }
  assert.match(
    migrationCode,
    /REVOKE ALL ON FUNCTION public\.resolve_invoice_exact_product_identities\(uuid, uuid\) FROM PUBLIC, anon;/,
  );
  assert.match(
    migrationCode,
    /GRANT EXECUTE ON FUNCTION public\.resolve_invoice_exact_product_identities\(uuid, uuid\) TO authenticated;/,
  );
  assert.doesNotMatch(migrationCode, /service_role/);
});

test("no stocking, posting, request, commitment, purchasing, or price-intelligence change", () => {
  assert.doesNotMatch(
    migrationCode,
    /inventory_items|inventory_adjustments|inventory_price_history/,
  );
  assert.doesNotMatch(
    migrationCode,
    /post_reviewed_invoice|supply_request|commitment|purchase_order|price_intelligence/i,
  );
  assert.doesNotMatch(
    migrationCode,
    /processing_status = 'completed',|posted_at = now\(\)|review_status = 'approved'/,
  );
});

test("the server delegates identity to the database and reads lines after resolution", () => {
  const review = between(
    server,
    "export const getInvoiceReviewFn",
    "export const saveInvoiceHeaderFn",
  );
  const resolveAt = review.indexOf("rpc('resolve_invoice_exact_product_identities'");
  const itemsAt = review.indexOf(".from('invoice_items')");
  assert.ok(resolveAt > 0 && itemsAt > resolveAt, "items must be read after resolution");
  assert.match(review, /!completed && invoice\.vendor_id && !identitiesResolved/);
  assert.match(
    review,
    /vendorMatch\.state === 'MATCHED'[\s\S]*rematch_invoice_vendor_products[\s\S]*identitiesResolved = true/,
  );
  assert.doesNotMatch(review, /automaticLinks/);
  assert.doesNotMatch(review, /\.update\(\{\s*product_id: match\.productId/);
  assert.doesNotMatch(review, /match\.state === 'EXACT' \? match\.productId/);
  assert.match(review, /productId: item\.product_id,/);
  assert.match(review, /product_match_source/);
  assert.match(review, /presentInvoiceLineMatch\(/);
  // Approval remains an explicit human action behind the unchanged gate.
  assert.match(server, /Match or create a product for every invoice line before approval/);
  assert.equal((server.match(/rpc\('post_reviewed_invoice'/g) ?? []).length, 1);
  assert.doesNotMatch(review, /post_reviewed_invoice/);
});

test("an identity-unchanged edit keeps the line link and its mapping", () => {
  const save = between(
    server,
    "export const saveInvoiceItemFn",
    "export const deleteInvoiceItemFn",
  );
  assert.match(save, /product_id,vendor_product_id'\)/);
  assert.match(save, /payload\.vendor_product_id = existing\.vendor_product_id;/);
});

test("the review UI marks automatic matches and keeps the approval gate", () => {
  assert.match(
    table,
    /isAutomaticMatchSource\(item\.matchSource\) && <p[^>]*>\{AUTOMATIC_MATCH_LABEL\}/,
  );
  assert.match(page, /describeInvoiceLineReview\(data\.items, completed\)/);
  assert.match(page, /unresolvedCount > 0/);
  assert.match(types, /product_match_source: string \| null/);
  assert.match(types, /resolve_invoice_exact_product_identities: \{/);
});

test("behavior and mutation suites cover the Henry Schein case and critical guards", () => {
  for (const sku of ["3980143", "1127149", "1507581", "1200685"])
    assert.ok(behavior.includes(`'${sku}'`), sku);
  for (const canonical of ["398-0143", "112-7149", "150-7581", "120-0685"])
    assert.ok(behavior.includes(`'${canonical}'`), canonical);
  assert.match(behavior, /^BEGIN;/m);
  assert.match(behavior, /ROLLBACK;\s*$/);
  assert.match(behavior, /SELECT 18 AS checks_passed, 0 AS checks_failed;/);
  for (const mutant of [
    "organization tier ignores the vendor",
    "catalog tier ignores the vendor",
    "organization ambiguity accepted",
    "catalog ambiguity accepted",
    "manual decisions revisited",
    "API can forge provenance",
    "separator key used for SKUs with separators",
  ])
    assert.ok(mutationCheck.includes(mutant), mutant);
  assert.ok(
    existsSync(new URL("../docs/phase6c1-invoice-exact-match-auto-resolution.md", import.meta.url)),
  );
});

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import test from "node:test";
import {
  MIN_CATALOG_SEARCH_LENGTH,
  catalogSearchTerm,
  describeCatalogUnavailable,
  searchOrganizationProducts,
  toInvoiceCatalogSearch,
} from "../src/invoice/catalog-match.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const migrationName = "20261012120000_beta_invoice_manual_catalog_matching.sql";
const migration = read(`../supabase/migrations/${migrationName}`);
const migrationCode = migration.replace(/--.*$/gm, "");
const behavior = read("../supabase/tests/beta_invoice_manual_catalog_matching_behavior.sql");
const mutationCheck = read("../supabase/tests/beta_invoice_manual_catalog_mutation_check.sh");
const server = read("../src/lib/invoice-processing.functions.ts");
const dialog = read("../src/components/invoice-processing/ProductMatchDialog.tsx");
const page = read("../src/components/invoice-processing/InvoiceReviewPage.tsx");
const headerForm = read("../src/components/invoice-processing/InvoiceHeaderForm.tsx");
const types = read("../src/integrations/supabase/types.ts");

const between = (source: string, start: string, end: string) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end}`);
  return source.slice(from, to);
};
const search = between(
  migrationCode,
  "CREATE FUNCTION public.search_invoice_line_catalog_listings",
  "REVOKE ALL ON FUNCTION public.search_invoice_line_catalog_listings",
);
const match = between(
  migrationCode,
  "CREATE FUNCTION public.match_invoice_item_to_catalog_listing",
  "REVOKE ALL ON FUNCTION public.match_invoice_item_to_catalog_listing",
);

const product = (overrides: Record<string, unknown>) => ({
  id: "p",
  name: "",
  description: "",
  manufacturer: "",
  internalItemCode: "",
  vendorItemNumber: "",
  vendorSkus: [] as string[],
  unitOfMeasure: "",
  packSize: "",
  ...overrides,
});
const products = [
  product({
    id: "wrap",
    name: "Ready Wrap Plastic Wrap",
    vendorItemNumber: "324-0025",
    vendorSkus: ["324-0025"],
  }),
  product({
    id: "strips",
    name: "Steri-Strip Skin Closures",
    manufacturer: "3M",
    vendorSkus: ["777-6538"],
  }),
  product({ id: "hydro", name: 'Hydrofilm Transparent Dre 4x6"', vendorSkus: ["1439386"] }),
  product({
    id: "tape",
    name: "Athletic Tape",
    internalItemCode: "TAPE-01",
    description: "white porous",
  }),
];

test("an unresolved line can search the organization's own products", () => {
  const ids = (query: string) =>
    searchOrganizationProducts(products, query).map((found) => found.id);
  assert.deepEqual(ids(""), ["wrap", "strips", "hydro", "tape"]);
  assert.deepEqual(ids("  steri "), ["strips"]);
  assert.deepEqual(ids("3m"), ["strips"]);
  assert.deepEqual(ids("porous"), ["tape"]);
  assert.deepEqual(ids("nothing like this"), []);
  // A product created from an earlier invoice line is found by the vendor SKU it remembered.
  assert.deepEqual(ids("1439386"), ["hydro"]);
  // Separators are ignored for codes, in both directions, and only for codes.
  assert.deepEqual(ids("3240025"), ["wrap"]);
  assert.deepEqual(ids("324-0025"), ["wrap"]);
  assert.deepEqual(ids("tape01"), ["tape"]);
  assert.deepEqual(ids("7776"), ["strips"]);
  assert.deepEqual(ids("--"), []);
  assert.equal(searchOrganizationProducts(products, "", 2).length, 2);
});

test("the catalog is searched for the line's own SKU until the reviewer types", () => {
  assert.equal(catalogSearchTerm("", " 1439386 "), "1439386");
  assert.equal(catalogSearchTerm("  hydrofilm ", "1439386"), "hydrofilm");
  assert.equal(catalogSearchTerm("", ""), "");
  assert.equal(MIN_CATALOG_SEARCH_LENGTH, 2);
  assert.match(search, /IF length\(_text\) < 2 THEN/);
});

test("catalog search results are shaped defensively and keep their source", () => {
  const parsed = toInvoiceCatalogSearch({
    available: true,
    reason: null,
    catalogVendorName: "Henry Schein",
    results: [
      {
        catalogVendorProductId: "a",
        vendorSku: "324-0025",
        name: "Ready Wrap",
        manufacturer: null,
        packageDescription: "6Rl/Ca",
        verified: true,
        organizationProductId: "org-product",
      },
      {
        catalogVendorProductId: "b",
        vendorSku: "777-0001",
        name: "Pending",
        verified: false,
        organizationProductId: null,
      },
      { vendorSku: "no-id" },
      "junk",
    ],
  });
  assert.deepEqual(parsed, {
    available: true,
    reason: null,
    catalogVendorName: "Henry Schein",
    results: [
      {
        catalogVendorProductId: "a",
        vendorSku: "324-0025",
        name: "Ready Wrap",
        manufacturer: "",
        packageDescription: "6Rl/Ca",
        verified: true,
        organizationProductId: "org-product",
      },
      {
        catalogVendorProductId: "b",
        vendorSku: "777-0001",
        name: "Pending",
        manufacturer: "",
        packageDescription: "",
        verified: false,
        organizationProductId: null,
      },
    ],
  });
  for (const junk of [null, undefined, "x", 4, []]) {
    assert.deepEqual(toInvoiceCatalogSearch(junk), {
      available: false,
      reason: null,
      catalogVendorName: "",
      results: [],
    });
  }
  assert.equal(
    toInvoiceCatalogSearch({ available: false, reason: "vendor_not_linked_to_catalog" }).reason,
    "vendor_not_linked_to_catalog",
  );
  assert.equal(toInvoiceCatalogSearch({ available: false, reason: "made_up" }).reason, null);
});

test("an unlinked vendor is explained, never silently linked", () => {
  assert.match(
    describeCatalogUnavailable("vendor_not_linked_to_catalog", "Local Supply"),
    /Local Supply is not linked to a catalog vendor/,
  );
  assert.match(describeCatalogUnavailable("no_vendor", ""), /Select an existing vendor/);
  assert.match(
    describeCatalogUnavailable("catalog_vendor_inactive", "Henry Schein"),
    /not available/,
  );
  // Neither function reads or writes a vendor link by name.
  for (const body of [search, match]) {
    assert.doesNotMatch(body, /normalized_name\s*=\s*_?catalog_vendor/i);
    assert.doesNotMatch(body, /UPDATE\s+public\.vendors/i);
    assert.doesNotMatch(body, /SET\s+catalog_vendor_id/i);
  }
});

test("the migration is additive: two new functions and nothing else", () => {
  assert.match(migrationCode, /^\s*BEGIN;/m);
  assert.match(migrationCode, /COMMIT;\s*$/);
  assert.equal(migrationCode.match(/CREATE FUNCTION /g)?.length, 2);
  for (const forbidden of [
    /CREATE OR REPLACE/i,
    /ALTER TABLE/i,
    /CREATE TABLE/i,
    /CREATE (UNIQUE )?INDEX/i,
    /CREATE TRIGGER/i,
    /DROP /i,
    /CREATE POLICY/i,
    /TRUNCATE/i,
  ]) {
    assert.doesNotMatch(migrationCode, forbidden);
  }
  // It runs after Phase 6C.1 and refuses to run before it or twice.
  const order = readdirSync(new URL("../supabase/migrations/", import.meta.url)).sort();
  assert.ok(
    order.indexOf(migrationName) >
      order.indexOf("20261010120000_phase6c1_invoice_exact_match_auto_resolution.sql"),
  );
  assert.match(migrationCode, /resolve_invoice_exact_product_identities\(uuid, uuid\)'\) IS NULL/);
  assert.match(migrationCode, /already been applied/);
});

test("both functions are owner-only definer functions closed to anon", () => {
  for (const body of [search, match]) {
    assert.match(body, /SECURITY DEFINER\s+SET search_path = public/);
    assert.match(
      body,
      /IF NOT public\.has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]::public\.org_role\[\]\) THEN\s+RAISE EXCEPTION 'Forbidden: owner access required'/,
    );
    assert.match(
      body,
      /FROM public\.invoices\s+WHERE organization_id = _organization_id AND source_file_id = _source_file_id/,
    );
  }
  for (const signature of [
    "search_invoice_line_catalog_listings(uuid, uuid, text, integer)",
    "match_invoice_item_to_catalog_listing(uuid, uuid, uuid, uuid, uuid)",
  ]) {
    assert.ok(
      migrationCode.includes(`REVOKE ALL ON FUNCTION public.${signature} FROM PUBLIC, anon;`),
    );
    assert.ok(
      migrationCode.includes(`GRANT EXECUTE ON FUNCTION public.${signature} TO authenticated;`),
    );
  }
});

test("search is read-only and scoped to the invoice vendor's linked catalog vendor", () => {
  assert.match(search, /\bSTABLE\b/);
  assert.doesNotMatch(search, /\b(INSERT|UPDATE|DELETE)\b/);
  assert.doesNotMatch(search, /FOR UPDATE/);
  // The catalog vendor comes from the invoice's vendor row; it is not a parameter.
  assert.doesNotMatch(search.slice(0, search.indexOf("RETURNS jsonb")), /catalog_vendor/);
  assert.match(
    search,
    /WHERE vendor\.id = _invoice\.vendor_id AND vendor\.organization_id = _organization_id AND vendor\.active/,
  );
  assert.match(search, /WHERE listing\.catalog_vendor_id = _catalog_vendor_id/);
  assert.match(
    search,
    /IF _catalog_vendor_id IS NULL THEN\s+RETURN jsonb_build_object\('available', false, 'reason', 'vendor_not_linked_to_catalog'/,
  );
  // The existing normalizers; no new SKU normalization.
  assert.match(search, /public\.normalize_catalog_sku\(_text\)/);
  assert.match(search, /public\.normalize_catalog_sku_match_key\(_text\)/);
  assert.match(search, /listing\.vendor_sku_match_key = _key/);
  assert.doesNotMatch(migrationCode, /regexp_replace/);
  assert.match(search, /LIMIT least\(greatest\(coalesce\(_limit, 20\), 1\), 50\)/);
});

test("matching reuses adoption and confirmation and never touches inventory or posting", () => {
  assert.match(match, /public\.adopt_catalog_vendor_product\(_organization_id, _listing\.id\)/);
  assert.match(
    match,
    /public\.confirm_invoice_item_product\(\s*_organization_id, _source_file_id, _invoice_item_id, _product_id, true\)/,
  );
  assert.match(match, /_listing\.catalog_vendor_id IS DISTINCT FROM _vendor\.catalog_vendor_id/);
  assert.match(match, /IF _line\.product_id IS DISTINCT FROM _expected_product_id THEN/);
  assert.match(match, /product_match_source = 'manual', product_match_decided_at = now\(\)/);
  // The invoice lock is taken before anything else is read or written.
  assert.ok(match.indexOf("FOR UPDATE") < match.indexOf("adopt_catalog_vendor_product"));
  assert.ok(
    match.indexOf("_expected_product_id THEN") <
      match.indexOf("public.adopt_catalog_vendor_product("),
  );
  // The expected product has no default: a caller must say what it believes the match is.
  assert.match(match, /_expected_product_id uuid\s*\)/);
  for (const forbidden of [
    /inventory_/i,
    /post_reviewed_invoice/i,
    /stock_catalog/i,
    /supply_request/i,
    /price_history/i,
    /processing_status\s*=/i,
  ]) {
    assert.doesNotMatch(
      migrationCode.replace(/_invoice\.processing_status = 'completed'/g, ""),
      forbidden,
    );
  }
  // Only invoice_items is written directly.
  assert.deepEqual(
    [...match.matchAll(/\b(?:INSERT INTO|UPDATE|DELETE FROM)\s+(public\.\w+)/g)].map(
      (found) => found[1],
    ),
    ["public.invoice_items"],
  );
});

test("server functions call the RPCs as the signed-in owner and pass the shown match", () => {
  const searchFn = between(
    server,
    "export const searchInvoiceCatalogFn",
    "export const matchInvoiceItemToCatalogFn",
  );
  const matchFn = between(
    server,
    "export const matchInvoiceItemToCatalogFn",
    "export const unlinkInvoiceItemProductFn",
  );
  for (const body of [searchFn, matchFn]) {
    assert.match(body, /requireSupabaseAuth/);
    assert.match(
      body,
      /await assertOwner\(context\.supabase, context\.userId, data\.organizationId\)/,
    );
    assert.doesNotMatch(body, /service_role|supabaseAdmin/i);
    // The browser never names a vendor or catalog vendor.
    assert.doesNotMatch(body, /vendorId|catalogVendorId/);
  }
  assert.match(searchFn, /rpc\('search_invoice_line_catalog_listings'/);
  assert.match(searchFn, /toInvoiceCatalogSearch\(result\)/);
  assert.match(matchFn, /requireDraftInvoice/);
  assert.match(matchFn, /rpc\('match_invoice_item_to_catalog_listing'/);
  assert.match(matchFn, /_expected_product_id: data\.expectedProductId/);
  assert.match(matchFn, /expectedProductId: uuid\.nullable\(\)/);
  assert.match(page, /expectedProductId: matching\.productId/);
  // No catalog adoption or stocking is called directly from invoice review.
  assert.doesNotMatch(server, /rpc\('adopt_catalog_vendor_product'/);
  assert.doesNotMatch(server, /stock_catalog_vendor_product/);
  for (const rpc of [
    "match_invoice_item_to_catalog_listing",
    "search_invoice_line_catalog_listings",
  ]) {
    assert.ok(types.includes(`${rpc}: {`), `types.ts is missing ${rpc}`);
  }
  assert.match(types, /_expected_product_id: string \| null/);
  // Review still exposes each product's remembered SKUs for the invoice vendor only.
  assert.match(
    server,
    /mapping\.product_id === product\.id && mapping\.vendor_id === invoice\.vendor_id/,
  );
});

test("the dialog separates the organization's products from the vendor catalog", () => {
  assert.match(dialog, /Your products/);
  assert.match(dialog, /`\$\{catalogName\} catalog`/);
  assert.ok(
    dialog.indexOf('aria-label="Your products"') < dialog.indexOf("aria-label={catalogHeading}"),
    "organization products come first",
  );
  assert.match(dialog, /"Already in your products" : "Catalog"/);
  assert.match(dialog, /Not verified/);
  assert.match(dialog, /"Add to your products and match"/);
  assert.match(dialog, /No stock is added/);
  assert.match(dialog, /will be remembered for future/);
  assert.match(dialog, /describeCatalogUnavailable\(catalog\.data\.reason, vendorName\)/);
  // A catalog result is chosen explicitly and goes through the catalog path, not the product path.
  assert.match(
    dialog,
    /chosen\.source === "catalog" \? onConfirmCatalog\(chosen\.id\) : onConfirm\(chosen\.id\)/,
  );
  // A catalog selection that is no longer on screen cannot be confirmed.
  assert.match(
    dialog,
    /const chosen = selected\?\.source === "catalog" && !selectedListing \? null : selected;/,
  );
  assert.match(dialog, /disabled=\{busy \|\| !chosen\}/);
  assert.match(dialog, /enabled: open && Boolean\(item\) && catalogSearch\.itemId === itemId/);
  assert.doesNotMatch(dialog, /onConfirmCatalog\(listing/);
  // A failed catalog search leaves the rest of the dialog usable, and errors are shown.
  assert.match(dialog, /catalog\.isError/);
  assert.match(dialog, /role="alert"/);
});

test("creating a product from a line is a separate, confirmed step", () => {
  // The button only opens the confirmation; onCreate runs from the confirmation alone.
  assert.equal(dialog.match(/run\(onCreate\)/g)?.length, 1);
  const confirmation = between(dialog, "{confirmingCreate ? (\n          <DialogFooter>", ") : (");
  assert.match(confirmation, /run\(onCreate\)/);
  assert.match(confirmation, /Create product/);
  assert.match(dialog, /setConfirmingCreate\(true\)/);
  assert.match(dialog, /Create a new product from this line\?/);
  assert.match(dialog, /Only what this line says is copied; nothing else is filled in\./);
  assert.match(dialog, /\{item\.manufacturer \|\| "Not set"\}/);
  assert.match(dialog, /\{item\.category \|\| "Not set"\}/);
  assert.match(dialog, /disabled=\{busy \|\| !hasVendor \|\| Boolean\(item\.productId\)\}/);
});

test("a calculated total is labelled as calculated on the review form", () => {
  assert.match(headerForm, /header\.derivedTotals\.includes\('subtotal'\)/);
  assert.match(headerForm, /header\.derivedTotals\.includes\('total'\)/);
  assert.match(headerForm, /'Calculated · review suggested'/);
  assert.match(headerForm, /const low = Boolean\(calculated\) \|\|/);
  assert.match(server, /derivedTotals: derivedTotalFields\(extraction\)/);
});

test("the behavior suite and mutation check cover every guard", () => {
  assert.match(behavior, /^BEGIN;/m);
  assert.match(behavior, /ROLLBACK;\s*$/);
  assert.doesNotMatch(behavior, /^COMMIT;/m);
  assert.match(behavior, /SELECT 15 AS checks_passed, 0 AS checks_failed;/);
  for (let check = 1; check <= 15; check += 1)
    assert.match(
      behavior,
      new RegExp(`-- Checks? (?:\\d+-)?${check}\\b|Checks \\d+-${check} failed`),
      `check ${check}`,
    );
  for (const mutant of [
    "search ignores the invoice vendor",
    "search reaches the catalog for an unlinked vendor",
    "search is no longer separator-insensitive",
    "search offers rejected listings",
    "owner checks removed",
    "match accepts another vendor's listing",
    "match works for an unlinked vendor",
    "match overwrites an existing match silently",
    "match changes completed invoices",
    "match duplicates a separator-variant mapping",
    "match forgets manual provenance",
    "match reaches a line on another invoice",
  ]) {
    assert.ok(mutationCheck.includes(`"${mutant}|`), `missing mutant: ${mutant}`);
  }
  // Every mutation target still exists in the migration.
  const entries = mutationCheck
    .slice(mutationCheck.indexOf("mutants=("), mutationCheck.indexOf("\n)\n"))
    .split('\n  "')
    .slice(1);
  assert.equal(entries.length, 17);
  for (const entry of entries) {
    const parts = entry.replace(/"\s*$/, "").split("|").slice(1);
    for (let index = 0; index < parts.length; index += 2)
      assert.ok(migration.includes(parts[index]), `stale mutation target: ${parts[index]}`);
  }
});

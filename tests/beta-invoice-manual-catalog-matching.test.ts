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
const actions = read("../src/invoice/review-actions.ts");
const phase6c1 = read(
  "../supabase/migrations/20261010120000_phase6c1_invoice_exact_match_auto_resolution.sql",
).replace(/--.*$/gm, "");

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
const confirm = between(
  migrationCode,
  "CREATE OR REPLACE FUNCTION public.confirm_invoice_item_product",
  "REVOKE ALL ON FUNCTION public.confirm_invoice_item_product",
);
const confirm6c1 = between(
  phase6c1,
  "CREATE OR REPLACE FUNCTION public.confirm_invoice_item_product",
  "CREATE OR REPLACE FUNCTION public.unlink_invoice_item_product",
);
const withdraw = between(
  migrationCode,
  "CREATE FUNCTION public.invalidate_derived_invoice_totals",
  "REVOKE ALL ON FUNCTION public.invalidate_derived_invoice_totals",
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

test("the migration adds three functions and one trigger and redefines only the manual confirmation", () => {
  assert.match(migrationCode, /^\s*BEGIN;/m);
  assert.match(migrationCode, /COMMIT;\s*$/);
  assert.deepEqual(
    [...migrationCode.matchAll(/CREATE FUNCTION public\.(\w+)/g)].map((found) => found[1]),
    [
      "search_invoice_line_catalog_listings",
      "match_invoice_item_to_catalog_listing",
      "invalidate_derived_invoice_totals",
    ],
  );
  assert.deepEqual(
    [...migrationCode.matchAll(/CREATE OR REPLACE FUNCTION public\.(\w+)/g)].map(
      (found) => found[1],
    ),
    ["confirm_invoice_item_product"],
  );
  assert.deepEqual(
    [...migrationCode.matchAll(/CREATE TRIGGER (\w+)\s+([A-Z ]+) ON public\.(\w+)/g)].map((found) =>
      found.slice(1),
    ),
    [
      [
        "invoice_items_invalidate_derived_totals",
        "AFTER INSERT OR UPDATE OR DELETE",
        "invoice_items",
      ],
    ],
  );
  for (const forbidden of [
    /ALTER TABLE/i,
    /CREATE TABLE/i,
    /CREATE (UNIQUE )?INDEX/i,
    /DROP /i,
    /CREATE POLICY/i,
    /TRUNCATE/i,
    /ALTER FUNCTION/i,
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

test("the redefined confirmation is Phase 6C.1's, except for how it remembers the vendor SKU", () => {
  const upTo = (source: string, marker: string) => {
    const at = source.indexOf(marker);
    assert.ok(at > 0, `missing ${marker}`);
    return source.slice(0, at);
  };
  const from = (source: string, start: string, end: string) =>
    between(source, start, end).replace(/\s+/g, " ");
  // Same signature, security, and search path.
  assert.equal(upTo(confirm, "DECLARE"), upTo(confirm6c1, "DECLARE"));
  // Same authorization, invoice lock, completed-invoice refusal, product check, and line lock.
  assert.equal(
    from(confirm, "BEGIN\n  IF NOT public.has_org_role", "IF _remember_vendor_sku AND"),
    from(confirm6c1, "BEGIN\n  IF NOT public.has_org_role", "IF _remember_vendor_sku AND"),
  );
  // Same write to the line, with manual provenance.
  const lineWrite =
    "UPDATE public.invoice_items SET product_id = _product_id, vendor_product_id = _vendor_product_id, review_status = 'pending_review', product_match_source = 'manual', product_match_decided_at = now() WHERE id = _line.id;";
  assert.ok(confirm.replace(/\s+/g, " ").includes(lineWrite));
  assert.ok(confirm6c1.replace(/\s+/g, " ").includes(lineWrite));
  // Same lookup of the mapping for the invoice vendor and exact SKU, and the same insert.
  for (const shared of [
    "WHERE organization_id = _organization_id AND vendor_id = _invoice.vendor_id AND lower(btrim(vendor_sku)) = lower(btrim(_line.sku)) ORDER BY active DESC, created_at LIMIT 1 FOR UPDATE;",
    "INSERT INTO public.vendor_products (organization_id, vendor_id, product_id, vendor_sku, package_size, unit_of_measure) VALUES (_organization_id, _invoice.vendor_id, _product_id, btrim(_line.sku), nullif(btrim(_line.package_size), ''), nullif(btrim(_line.unit_of_measure), ''))",
    "IF _invoice.vendor_id IS NULL THEN RAISE EXCEPTION 'Select an existing vendor before remembering a vendor SKU'; END IF;",
  ]) {
    assert.ok(confirm.replace(/\s+/g, " ").includes(shared), shared);
    assert.ok(confirm6c1.replace(/\s+/g, " ").includes(shared), shared);
  }
  // The change: a mapping is repointed only if it is not from the catalog, and a
  // separator variant of a catalog-adopted SKU is never inserted.
  assert.match(
    confirm,
    /IF _mapping\.product_id = _product_id OR _mapping\.catalog_vendor_product_id IS NULL THEN\s+UPDATE public\.vendor_products SET product_id = _product_id,/,
  );
  assert.match(confirm, /ELSE\s+_preserved_vendor_product_id := _mapping\.id;/);
  assert.match(confirm, /IF _adopted_count = 0 THEN\s+INSERT INTO public\.vendor_products/);
  assert.match(
    confirm,
    /catalog_vendor_product_id IS NOT NULL\s+AND _key <> '' AND public\.normalize_catalog_sku_match_key\(vendor_sku\) = _key/,
  );
  // Every mapping it reads or writes is for this organization and the invoice's vendor.
  assert.equal(confirm.match(/FROM public\.vendor_products/g)?.length, 3);
  assert.equal(
    confirm.match(
      /FROM public\.vendor_products\s+WHERE organization_id = _organization_id AND vendor_id = _invoice\.vendor_id/g,
    )?.length,
    3,
  );
  assert.deepEqual(
    [...confirm.matchAll(/\b(?:INSERT INTO|UPDATE|DELETE FROM)\s+(public\.\w+)/g)].map(
      (found) => found[1],
    ),
    ["public.vendor_products", "public.vendor_products", "public.invoice_items"],
  );
  assert.doesNotMatch(confirm, /inventory|post_reviewed_invoice|catalog_vendor_id/);
  assert.ok(
    migrationCode.includes(
      "REVOKE ALL ON FUNCTION public.confirm_invoice_item_product(uuid, uuid, uuid, uuid, boolean) FROM PUBLIC, anon;",
    ),
  );
  assert.ok(
    migrationCode.includes(
      "GRANT EXECUTE ON FUNCTION public.confirm_invoice_item_product(uuid, uuid, uuid, uuid, boolean) TO authenticated;",
    ),
  );
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
  // The invoice lock is taken before anything else is read or written.
  assert.ok(match.indexOf("FOR UPDATE") < match.indexOf("adopt_catalog_vendor_product"));
  assert.ok(
    match.indexOf("_expected_product_id THEN") <
      match.indexOf("public.adopt_catalog_vendor_product("),
  );
  // The expected product has no default: a caller must say what it believes the match is.
  assert.match(match, /_expected_product_id uuid\s*\)/);
  // A conflict inside adoption is reported as a controlled error, with adoption rolled back.
  assert.match(
    match,
    /BEGIN\s+_adoption := public\.adopt_catalog_vendor_product\(_organization_id, _listing\.id\);\s+EXCEPTION WHEN unique_violation OR check_violation OR foreign_key_violation THEN/,
  );
  assert.match(
    match,
    /RAISE EXCEPTION 'This catalog item conflicts with a product or vendor SKU mapping/,
  );
  // The function writes nothing itself: adoption and confirmation own every write, so the
  // vendor SKU mapping rules exist in one place.
  assert.deepEqual(
    [...match.matchAll(/\b(?:INSERT INTO|UPDATE|DELETE FROM)\s+(public\.\w+)/g)].map(
      (found) => found[1],
    ),
    [],
  );
  assert.doesNotMatch(match, /normalize_catalog_sku_match_key|product_match_source/);
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
});

test("a calculated total is withdrawn by the database when an owner changes a line", () => {
  // Runs as the caller, like the Phase 6C.1 provenance guard, and only for API roles.
  assert.doesNotMatch(withdraw, /SECURITY DEFINER/);
  assert.match(withdraw, /RETURNS trigger/);
  assert.match(
    withdraw,
    /BEGIN\s+IF current_user NOT IN \('authenticated', 'anon'\) THEN RETURN NULL; END IF;/,
  );
  // Added, removed, moved, or re-priced lines; nothing else.
  assert.match(withdraw, /IF TG_OP = 'INSERT' THEN\s+_invoice_ids := ARRAY\[NEW\.invoice_id\];/);
  assert.match(withdraw, /ELSIF TG_OP = 'DELETE' THEN\s+_invoice_ids := ARRAY\[OLD\.invoice_id\];/);
  assert.match(
    withdraw,
    /NEW\.quantity IS DISTINCT FROM OLD\.quantity\s+OR NEW\.unit_price IS DISTINCT FROM OLD\.unit_price\s+OR NEW\.total_price IS DISTINCT FROM OLD\.total_price THEN/,
  );
  assert.match(withdraw, /ELSE\s+RETURN NULL;\s+END IF;/);
  // Only amounts whose stored source is Derived, and never on a completed invoice.
  assert.match(withdraw, /#>> '\{header,subtotal,source\}' = 'Derived'/);
  assert.match(withdraw, /#>> '\{header,total,source\}' = 'Derived'/);
  assert.match(
    withdraw,
    /_invoice\.posted_at IS NOT NULL OR _invoice\.processing_status = 'completed'/,
  );
  assert.match(withdraw, /CONTINUE WHEN NOT \(_subtotal OR _total\);/);
  assert.match(
    withdraw,
    /'\{"value": null, "confidence": 0, "source": "Derived", "reviewed": false\}'/,
  );
  assert.deepEqual(
    [...withdraw.matchAll(/\b(?:INSERT INTO|UPDATE|DELETE FROM)\s+(public\.\w+)/g)].map(
      (found) => found[1],
    ),
    ["public.invoice_processing_jobs", "public.invoices"],
  );
  // It withdraws; it never calculates. The calculation exists once, in TypeScript.
  assert.doesNotMatch(withdraw, /\bsum\(|total_price \+|\+ *tax|invoice_items\b/i);
  assert.ok(
    migrationCode.includes(
      "REVOKE ALL ON FUNCTION public.invalidate_derived_invoice_totals() FROM PUBLIC, anon, authenticated;",
    ),
  );
});

test("server functions hand the request's client to the review actions, which call the RPCs", () => {
  // The handlers are one line each: validated input, the request's client, the user id.
  for (const [fn, schema, action] of [
    ["searchInvoiceCatalogFn", "catalogSearchInput", "searchInvoiceCatalog"],
    ["matchInvoiceItemToCatalogFn", "catalogMatchInput", "matchInvoiceItemToCatalog"],
    ["confirmInvoiceItemProductFn", "confirmMatchInput", "confirmInvoiceItemProduct"],
    ["saveInvoiceItemFn", "itemInput", "saveInvoiceItem"],
    ["deleteInvoiceItemFn", "itemKeyInput", "deleteInvoiceItem"],
  ]) {
    const handler = server.slice(server.indexOf(`export const ${fn} = `)).split("\n\n")[0];
    assert.match(
      handler,
      new RegExp(`inputValidator\\(\\(value: unknown\\) => ${schema}\\.parse\\(value\\)\\)`),
      fn,
    );
    assert.match(handler, /\.middleware\(\[requireSupabaseAuth\]\)/, fn);
    assert.match(
      handler,
      new RegExp(`=> ${action}\\(context\\.supabase, context\\.userId, data\\)\\);`),
      fn,
    );
    assert.doesNotMatch(handler, /service_role|supabaseAdmin/i, fn);
  }
  const body = (name: string, next: string) =>
    between(actions, `export async function ${name}`, next);
  const searchAction = body(
    "searchInvoiceCatalog",
    "export async function matchInvoiceItemToCatalog",
  );
  const matchAction = actions.slice(
    actions.indexOf("export async function matchInvoiceItemToCatalog"),
  );
  const confirmAction = body(
    "confirmInvoiceItemProduct",
    "export async function searchInvoiceCatalog",
  );
  for (const action of [searchAction, matchAction, confirmAction]) {
    assert.match(action, /await assertOwner\(db, userId, data\.organizationId\);/);
    // The browser never names a vendor or catalog vendor.
    assert.doesNotMatch(action, /vendorId|catalogVendorId/);
    // Database errors are translated; none is rethrown with its own text.
    assert.match(action, /if \(error\) throw toInvoiceReviewError\(error, "/);
    assert.doesNotMatch(action, /new Error\(error\.message\)/);
  }
  assert.match(searchAction, /db\.rpc\("search_invoice_line_catalog_listings"/);
  assert.match(searchAction, /toInvoiceCatalogSearch\(result\)/);
  assert.match(matchAction, /requireDraftInvoice/);
  assert.match(matchAction, /db\.rpc\("match_invoice_item_to_catalog_listing"/);
  assert.match(matchAction, /_expected_product_id: data\.expectedProductId/);
  assert.match(confirmAction, /db\.rpc\("confirm_invoice_item_product"/);
  assert.match(actions, /expectedProductId: uuid\.nullable\(\)/);
  assert.match(page, /expectedProductId: matching\.productId/);
  // No framework, alias, or service-role dependency: the integration tests import this file.
  assert.doesNotMatch(actions, /from "@\/|@tanstack|service_role|supabaseAdmin|process\.env/);
  // No catalog adoption or stocking is called directly from invoice review.
  for (const source of [server, actions]) {
    assert.doesNotMatch(source, /rpc\(['"]adopt_catalog_vendor_product['"]/);
    assert.doesNotMatch(source, /stock_catalog_vendor_product/);
  }
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
  // Every match-dialog RPC still made from the server functions file is translated too.
  const dialogRpcs = server.slice(server.indexOf("export const unlinkInvoiceItemProductFn"));
  assert.equal(dialogRpcs.match(/throw toInvoiceReviewError\(/g)?.length, 3);
  assert.doesNotMatch(dialogRpcs, /new Error\((?:error|mappingError)\.message\)/);
  // Approval translates database errors the same way.
  assert.match(
    server,
    /if \(error\) throw toInvoiceReviewError\(error, 'Could not approve this invoice\.'\);/,
  );
});

test("calculated totals are refreshed after every line or header change", () => {
  const save = between(
    actions,
    "export async function saveInvoiceItem",
    "export async function deleteInvoiceItem",
  );
  const remove = between(
    actions,
    "export async function deleteInvoiceItem",
    "// Shapes a confirm/match RPC result.",
  );
  // After the update, after the insert, and after the delete; always after the write.
  assert.equal(
    save.match(
      /await refreshDerivedInvoiceTotals\(db, data\.organizationId, data\.sourceFileId\);/g,
    )?.length,
    2,
  );
  assert.ok(save.indexOf(".update(payload)") < save.indexOf("await refreshDerivedInvoiceTotals("));
  assert.ok(save.lastIndexOf(".insert({") < save.lastIndexOf("await refreshDerivedInvoiceTotals("));
  assert.ok(remove.indexOf(".delete()") < remove.indexOf("await refreshDerivedInvoiceTotals("));
  const header = between(
    server,
    "export const saveInvoiceHeaderFn",
    "export const saveInvoiceItemFn",
  );
  assert.match(
    header,
    /await refreshDerivedInvoiceTotals\(context\.supabase, data\.organizationId, data\.sourceFileId, \{\s+subtotal: data\.subtotal \?\? null,\s+total: data\.invoiceTotal \?\? null,\s+\}\);/,
  );
  assert.ok(header.indexOf(".update({") < header.indexOf("await refreshDerivedInvoiceTotals("));
  // The refresh writes only what the recalculation returns, and only for a draft.
  const refresh = between(
    actions,
    "export async function refreshDerivedInvoiceTotals",
    "export async function saveInvoiceItem",
  );
  assert.match(refresh, /if \(!stored \|\| !derivedTotalKeys\(stored\)\.length\) return false;/);
  assert.match(refresh, /const refresh = recalculateDerivedTotals\(/);
  assert.match(refresh, /if \("subtotal" in refresh\.amounts\)/);
  assert.match(refresh, /if \("total" in refresh\.amounts\)/);
  assert.match(
    refresh,
    /processing_status === "completed" \|\| invoice\.posted_at\) return false;/,
  );
});

test("the reviewer is told when a catalog SKU mapping is kept", () => {
  assert.match(
    dialog,
    /item\.skuFromCatalog && Boolean\(item\.sku\) && chosenProductId !== item\.productId/,
  );
  assert.match(
    dialog,
    /matches this line on this invoice only; the SKU stays mapped to its catalog product\./,
  );
  assert.match(
    page,
    /match\.preservedMapping\s+\? `Matched on this invoice only\. Vendor SKU \$\{match\.preservedMapping\.vendorSku\} stays mapped to its catalog product/,
  );
  assert.equal(page.match(/noteMatch\(\s+await (?:matchCatalog|confirmProduct)\(/g)?.length, 2);
  assert.match(
    server,
    /skuFromCatalog: \(mappingsResult\.data \?\? \[\]\)\.some\(\(mapping\) => mapping\.id === item\.vendor_product_id && mapping\.catalog_vendor_product_id !== null\)/,
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

test("the behavior suites and mutation check cover every guard", () => {
  const suites: Array<[string, number]> = [
    ["beta_invoice_manual_catalog_matching_behavior.sql", 15],
    ["beta_invoice_rematch_behavior.sql", 10],
    ["beta_invoice_derived_totals_behavior.sql", 10],
  ];
  for (const [name, checks] of suites) {
    const suite = read(`../supabase/tests/${name}`);
    assert.match(suite, /^BEGIN;/m, name);
    assert.match(suite, /ROLLBACK;\s*$/, name);
    assert.doesNotMatch(suite, /^COMMIT;/m, name);
    assert.ok(suite.includes(`SELECT ${checks} AS checks_passed, 0 AS checks_failed;`), name);
    for (let check = 1; check <= checks; check += 1) {
      assert.match(
        suite,
        new RegExp(
          `-- Checks? (?:\\d+ and |\\d+-)?${check}\\b|Checks \\d+-${check} failed|Check ${check} `,
        ),
        `${name} check ${check}`,
      );
    }
    assert.ok(mutationCheck.includes(`/supabase/tests/${name}"`), `mutation check runs ${name}`);
  }
  assert.equal(
    behavior,
    read("../supabase/tests/beta_invoice_manual_catalog_matching_behavior.sql"),
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
    "match reaches a line on another invoice",
    "confirm repoints a catalog-adopted mapping",
    "confirm shadows a catalog-adopted mapping with a separator variant",
    "confirm links a line to an adopted mapping for another product",
    "confirm never reuses the adopted mapping",
    "confirm forgets manual provenance",
    "adoption conflicts leak as constraint errors",
    "calculated totals survive API line changes",
    "database functions withdraw calculated totals too",
    "printed totals are withdrawn",
    "printed subtotals are withdrawn",
    "a removed line keeps a calculated total",
    "an added line keeps a calculated total",
    "completed invoices lose calculated totals",
  ]) {
    assert.ok(mutationCheck.includes(`"${mutant}|`), `missing mutant: ${mutant}`);
  }
  // Every mutation target still exists in the migration.
  const list = mutationCheck.slice(mutationCheck.indexOf("mutants=("));
  const entries = list.slice(0, list.indexOf("\n)\n")).split('\n  "').slice(1);
  assert.equal(entries.length, 36);
  for (const entry of entries) {
    const parts = entry.replace(/"\s*$/, "").replace(/\\"/g, '"').split("|").slice(1);
    for (let index = 0; index < parts.length; index += 2) {
      assert.ok(migration.includes(parts[index]), `stale mutation target: ${parts[index]}`);
    }
  }
});

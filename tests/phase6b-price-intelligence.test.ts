import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  sameSkuChangeText,
  formatUsd,
} from "../src/price-intelligence/vendor-intelligence.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const migration = read("../supabase/migrations/20260921120000_phase6b_price_intelligence.sql");
const behavior = read("../supabase/tests/phase6b_price_intelligence_behavior.sql");
const server = read("../src/lib/price-intelligence.functions.ts");
// Phase 6B.1 replaced the 6B catalog panel with the shared product vendor history.
const panel = read("../src/components/price-intelligence/PriceIntelligenceSections.tsx");
const history = read("../src/components/price-intelligence/ProductVendorHistory.tsx");
const catalogPage = read("../src/components/catalog/CatalogAdminPage.tsx");
const staffShell = read("../src/components/app/StaffAppShell.tsx");
const staffRequest = read("../src/routes/_authenticated/staff/request.tsx");
const staffRequests = read("../src/routes/_authenticated/staff/requests.tsx");
const generatedTypes = read("../src/integrations/supabase/types.ts");
const docs = read("../docs/phase6b-price-intelligence.md");


test("6B reuses authoritative inventory price history instead of creating a second ledger", () => {
  assert.match(migration, /FROM public\.inventory_price_history history/);
  assert.doesNotMatch(migration, /CREATE TABLE/);
  assert.match(migration, /JOIN public\.invoices invoice/);
  assert.match(migration, /invoice\.posted_at IS NOT NULL/);
});

test("price intelligence RPC is exact-product and organization scoped", () => {
  assert.match(migration, /history\.organization_id = _organization_id/);
  assert.match(migration, /history\.product_id = _product_id/);
  assert.match(
    migration,
    /product\.id = _product_id[\s\S]*product\.organization_id = _organization_id/,
  );
  assert.doesNotMatch(migration, /similarity\(|levenshtein|normalized_name\s*=|manufacturer\s*=/i);
});

test("owner and admin access is database-enforced with exact function ACLs", () => {
  assert.match(migration, /is_org_admin\(_organization_id, auth\.uid\(\)\)/);
  assert.match(migration, /SECURITY DEFINER[\s\S]*SET search_path = public/);
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.get_product_price_intelligence\(uuid, uuid\)[\s\S]*FROM PUBLIC, anon/,
  );
  assert.match(
    migration,
    /GRANT EXECUTE ON FUNCTION public\.get_product_price_intelligence\(uuid, uuid\)[\s\S]*TO authenticated/,
  );
  assert.match(behavior, /Owners have the same explicit RPC access as admins/);
});

test("staff, nonmembers, and cross-organization administrators are denied", () => {
  for (const marker of [
    "Staff price intelligence access unexpectedly succeeded",
    "Nonmember price intelligence access unexpectedly succeeded",
    "Cross-organization price intelligence access unexpectedly succeeded",
  ]) {
    assert.match(behavior, new RegExp(marker));
  }
  assert.equal(
    (behavior.match(/EXCEPTION WHEN insufficient_privilege THEN NULL/g) ?? []).length,
    3,
  );
});

test("only posted observations with usable explicit USD prices enter historical metrics", () => {
  const valid = migration.slice(
    migration.indexOf("valid AS MATERIALIZED"),
    migration.indexOf("summary AS"),
  );
  assert.match(valid, /currency_code = 'USD'/);
  assert.match(valid, /purchase_price IS NOT NULL/);
  assert.match(migration, /invoice\.posted_at IS NOT NULL/);
  assert.match(behavior, /\('EUR'::text, true, 777::numeric\)/);
  assert.match(behavior, /\('USD'::text, false, 999::numeric\)/);
  assert.match(behavior, /includedUsdObservationCount.*25/s);
});

test("latest and previous prices use deterministic server-side ordering", () => {
  assert.match(migration, /ORDER BY purchase_date DESC, created_at DESC, id DESC/);
  assert.match(migration, /product_position = 1/);
  assert.match(migration, /product_position = 2/);
  assert.match(behavior, /recentPurchases,0,purchasePrice.*25/s);
  assert.match(behavior, /recentPurchases,19,purchasePrice.*6/s);
});

test("absolute, percent, range, and observation metrics are database-computed", () => {
  assert.match(migration, /summary\.latest_price - summary\.previous_price/);
  assert.match(migration, /\/ summary\.previous_price\) \* 100/);
  assert.match(migration, /min\(purchase_price\) AS historical_low/);
  assert.match(migration, /max\(purchase_price\) AS historical_high/);
  assert.match(migration, /count\(\*\)::integer AS observation_count/);
  for (const expected of [
    "latestPrice.*25",
    // Phase 6B.1: the previous price is the same vendor, SKU and unit (23), never 24.
    "previousPrice.*23",
    "historicalLow.*1",
    "historicalHigh.*25",
    "observationCount.*25",
  ]) {
    assert.match(behavior, new RegExp(expected, "s"));
  }
});

test("zero or missing previous price never produces an invalid percentage", () => {
  assert.match(
    migration,
    /summary\.previous_price IS NULL[\s\S]*summary\.previous_price = 0 THEN NULL/,
  );
  assert.match(behavior, /summary,previousPrice.*<> 0[\s\S]*summary,percentChange.*'null'::jsonb/);
  assert.equal(sameSkuChangeText(null, null), null);
  assert.equal(sameSkuChangeText(5, null), "Price increased +$5.00");
});

test("neutral display formatting reports increases and decreases without procurement advice", () => {
  assert.equal(formatUsd(42.5), "$42.50");
  assert.equal(sameSkuChangeText(3.5, 8.974358974), "Price increased +$3.50 (+9.0%)");
  assert.equal(sameSkuChangeText(-4.2, -8.4), "Price decreased −$4.20 (−8.4%)");
  assert.doesNotMatch(panel, /bad price|overpriced|great deal|should switch|wasting money/i);
});

test("vendor history groups only observations already scoped to the exact canonical product", () => {
  assert.match(migration, /PARTITION BY vendor_id/);
  assert.match(migration, /GROUP BY vendor_id/);
  assert.match(behavior, /Vendor A'[\s\S]*observationCount'\)::integer = 13/);
  assert.match(behavior, /Vendor B'[\s\S]*observationCount'\)::integer = 12/);
  assert.match(behavior, /Exact product scoping or zero-baseline behavior is incorrect/);
});

test("package mismatch remains raw evidence and never creates normalized unit economics", () => {
  const rpcBody = migration.slice(migration.indexOf("AS $$"), migration.indexOf("$$;"));
  assert.match(behavior, /'case of 12'/);
  assert.match(behavior, /'6 rolls'/);
  assert.match(migration, /'packageEvidenceStatus', 'unverified'/);
  assert.match(migration, /'status', 'not_verified'/);
  assert.match(migration, /'normalizedUnitEconomicsAvailable', false/);
  assert.doesNotMatch(rpcBody, /package_quantity|normalized_unit_(?:cost|price)|cheaper|savings/i);
  assert.match(panel, /Prices[\s\S]*are not compared/);
});

test("currency exclusions are explicit and no FX logic exists", () => {
  assert.match(migration, /excludedUnknownCurrencyCount/);
  assert.match(migration, /excludedNonUsdCount/);
  assert.match(panel, /non-USD/);
  assert.doesNotMatch(migration + server, /exchange_rate|fx_rate|convert_currency/i);
});

test("history and vendor results are bounded with deterministic limits", () => {
  assert.match(migration, /LIMIT 20/);
  assert.match(migration, /LIMIT 12/);
  assert.match(migration, /'historyLimit', 20/);
  assert.match(migration, /'vendorLimit', 12/);
  assert.match(behavior, /jsonb_array_length\(_result -> 'recentPurchases'\) <> 20/);
});

test("the access index matches exact-product deterministic retrieval", () => {
  assert.match(
    migration,
    /ON public\.inventory_price_history \(\s*organization_id, product_id, purchase_date DESC, created_at DESC, id DESC\s*\)/,
  );
});

test("every displayed purchase carries invoice and line provenance", () => {
  for (const field of [
    "observationId",
    "invoiceId",
    "invoiceItemId",
    "invoiceNumber",
    "postedAt",
    "provenanceType",
  ]) {
    assert.match(migration, new RegExp(`'${field}'`));
  }
  assert.match(migration, /'posted_invoice_purchase_history'/);
  assert.match(panel, /sourceLabel\(o\.documentType, o\.dateBasis\)/);
});

test("catalog detail loads price intelligence only from an adopted organization product", () => {
  assert.match(catalogPage, /organizationProductId=\{row\?\.organizationProductId \?\? null\}/);
  assert.match(catalogPage, /<ProductVendorHistory/);
  assert.match(catalogPage, /organizationProductId \?/);
  assert.match(
    catalogPage,
    /Adopt this catalog identity before organization purchase history can be shown/,
  );
  assert.match(history, /getProductVendorHistoryFn/);
});

test("server wrapper requires authentication and delegates all financial calculation to the RPC", () => {
  assert.match(server, /middleware\(\[requireSupabaseAuth\]\)/);
  // Phase 6B.1: the wrappers delegate to src/price-intelligence/data.ts, which calls the RPCs.
  assert.match(server, /getProductVendorHistory\(/);
  assert.doesNotMatch(server, /inventory_price_history|absoluteChange\s*=|percentChange\s*=/);
});

test("staff UX has no price-intelligence imports or rendering", () => {
  for (const source of [staffShell, staffRequest, staffRequests]) {
    assert.doesNotMatch(
      source,
      /price-intelligence|ProductPriceIntelligence|ProductVendorHistory|getProductPriceIntelligence/i,
    );
  }
});

test("no request-to-invoice heuristic or purchasing mutation is introduced", () => {
  assert.doesNotMatch(
    migration,
    /supply_request|purchase_order|inventory_adjustments|UPDATE public\.inventory|INSERT INTO public\.inventory/i,
  );
  assert.doesNotMatch(server, /service_role|\.insert\(|\.update\(|\.delete\(/);
});

test("generated Supabase types include the new RPC", () => {
  assert.match(generatedTypes, /get_product_price_intelligence/);
  assert.match(generatedTypes, /Args: \{ _organization_id: string; _product_id: string \}/);
  assert.match(generatedTypes, /Returns: Json/);
});

test("documentation records source, identity, package, currency, authorization, and non-goals", () => {
  for (const heading of [
    "Source of truth",
    "Canonical identity rules",
    "Package comparison rules",
    "Currency rules",
    "Historical metrics",
    "Provenance",
    "Insufficient-data behavior",
    "Authorization",
    "Performance bounds",
    "Explicit non-goals",
  ]) {
    assert.match(docs, new RegExp(`## ${heading}`));
  }
});

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import test from "node:test";
import { toCatalogMatchConflict } from "../src/invoice/catalog-match.ts";
import { InvoiceReviewError, toInvoiceReviewError } from "../src/invoice/review-actions.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const migrationName = "20261124120000_hotfix_catalog_adoption_name_twin.sql";
const migration = read(`../supabase/migrations/${migrationName}`);
const actions = read("../src/invoice/review-actions.ts");
const server = read("../src/lib/invoice-processing.functions.ts");
const page = read("../src/components/invoice-processing/InvoiceReviewPage.tsx");
const dialog = read("../src/components/invoice-processing/ProductMatchDialog.tsx");

const PREFIX =
  "This catalog item conflicts with a product or vendor SKU mapping your organization already has, so it cannot be added automatically. ";
const PRODUCT = "3ce1d7e2-6304-4ff9-a80d-8bf38cca7e06";

test("the hotfix only redefines the two functions and changes no schema or data", () => {
  const migrations = readdirSync(new URL("../supabase/migrations/", import.meta.url)).sort();
  assert.ok(
    migrations.indexOf(migrationName) >
      migrations.indexOf("20261123120000_phase6b1_multi_vendor_intelligence.sql"),
  );
  const created = [...migration.matchAll(/CREATE OR REPLACE FUNCTION public\.(\w+)\(/g)].map(
    (match) => match[1],
  );
  assert.deepEqual(created, [
    "adopt_catalog_vendor_product",
    "match_invoice_item_to_catalog_listing",
  ]);
  // Outside the two function bodies there is nothing but the preflight and grants.
  const outside = migration.replace(/--.*$/gm, "").replace(/AS \$\$[\s\S]*?\n\$\$;/g, "");
  assert.doesNotMatch(outside, /\b(ALTER|CREATE TABLE|CREATE (UNIQUE )?INDEX|DROP|TRIGGER)\b/);
  assert.doesNotMatch(outside, /\b(INSERT INTO|UPDATE|DELETE FROM)\b/);
  assert.doesNotMatch(migration, /CREATE TEMP/i);
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.adopt_catalog_vendor_product\(uuid, uuid\) FROM PUBLIC, anon;/,
  );
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.match_invoice_item_to_catalog_listing\(uuid, uuid, uuid, uuid, uuid\) FROM PUBLIC, anon;/,
  );
});

test("a same-named product linked to another catalog product yields a SKU-qualified name", () => {
  assert.match(migration, /IF _name_twin\.catalog_product_id IS NULL THEN\s+RAISE EXCEPTION/);
  assert.match(
    migration,
    /_product_name := _catalog_product\.name \|\| ' \(' \|\| _catalog_vendor_product\.vendor_sku \|\| '\)';/,
  );
  assert.match(migration, /public\.normalize_catalog_text\(_product_name\)/);
  // The vendor SKU rules are unchanged: an exact SKU candidate is still reused or refused
  // before any name is considered.
  assert.ok(
    migration.indexOf("IF _candidate_count > 1 THEN") <
      migration.indexOf("_name_twin.catalog_product_id"),
  );
});

test("match refusals keep the original sentence first and add a JSON hint", () => {
  assert.match(
    migration,
    /RAISE EXCEPTION '%', 'This catalog item conflicts with a product or vendor SKU mapping your organization already has, so it cannot be added automatically\. ' \|\| _explanation/,
  );
  assert.match(migration, /'canMatchExisting', _can_match_existing/);
  // Reuse is only ever offered for the line's own SKU through an active mapping.
  assert.match(
    migration,
    /AND public\.normalize_catalog_sku_match_key\(_line\.sku\) = public\.normalize_catalog_sku_match_key\(_listing\.vendor_sku\);/,
  );
  assert.match(migration, /AND _conflict_vendor_product\.active\n/);
});

test("a refusal hint becomes a named conflict", () => {
  const conflict = toCatalogMatchConflict(
    `${PREFIX}Vendor SKU 398-0145 is already mapped to "Ammex Large".`,
    JSON.stringify({
      conflictType: "sku_mapped_to_other_product",
      productId: PRODUCT,
      productName: "Ammex Large",
      vendorProductId: null,
      vendorSku: "398-0145",
      canMatchExisting: true,
    }),
  );
  assert.deepEqual(conflict, {
    conflictType: "sku_mapped_to_other_product",
    message: `${PREFIX}Vendor SKU 398-0145 is already mapped to "Ammex Large".`,
    productId: PRODUCT,
    productName: "Ammex Large",
    vendorSku: "398-0145",
    canMatchExisting: true,
  });
});

test("an unreadable or partial hint never offers a product", () => {
  const message = `${PREFIX}Choose the existing product under Your products.`;
  for (const hint of [null, "", "not json", "[1]", JSON.stringify({ canMatchExisting: true })]) {
    const conflict = toCatalogMatchConflict(message, hint);
    assert.equal(conflict?.conflictType, "unknown");
    assert.equal(conflict?.canMatchExisting, false);
    assert.equal(conflict?.message, message);
  }
  const noName = toCatalogMatchConflict(
    message,
    JSON.stringify({ conflictType: "name_twin_local", productId: PRODUCT, canMatchExisting: true }),
  );
  assert.equal(noName?.canMatchExisting, false);
  const badId = toCatalogMatchConflict(
    message,
    JSON.stringify({
      conflictType: "made_up",
      productId: "x",
      productName: "P",
      canMatchExisting: true,
    }),
  );
  assert.deepEqual(
    [badId?.conflictType, badId?.productId, badId?.canMatchExisting],
    ["unknown", null, false],
  );
  // Other database refusals are not catalog conflicts.
  assert.equal(toCatalogMatchConflict("Invoice line not found", "{}"), null);
});

test("only a P0001 catalog refusal carries a conflict", () => {
  const refusal = toInvoiceReviewError(
    {
      code: "P0001",
      message: `${PREFIX}Your products already has "Flexi-Wrap".`,
      hint: JSON.stringify({
        conflictType: "name_twin_local",
        productId: PRODUCT,
        productName: "Flexi-Wrap",
      }),
    },
    "fallback",
  );
  assert.ok(refusal instanceof InvoiceReviewError);
  assert.equal(refusal.code, "rejected");
  assert.equal(refusal.catalogConflict?.conflictType, "name_twin_local");
  assert.equal(refusal.catalogConflict?.canMatchExisting, false);
  const raw = toInvoiceReviewError(
    { code: "23505", message: "duplicate key", hint: "{}" },
    "fallback",
  );
  assert.equal(raw.code, "conflict");
  assert.equal(raw.catalogConflict, null);
});

test("the server returns a refusal to the dialog instead of throwing it", () => {
  const outcome = actions.slice(
    actions.indexOf("export async function matchInvoiceItemToCatalogOutcome"),
  );
  assert.match(
    outcome,
    /return \{ status: "matched", match: await matchInvoiceItemToCatalog\(db, userId, data\) \};/,
  );
  assert.match(outcome, /cause instanceof InvoiceReviewError && cause\.catalogConflict/);
  assert.match(outcome, /throw cause;/);
  assert.match(
    server,
    /=> matchInvoiceItemToCatalogOutcome\(context\.supabase, context\.userId, data\)\);/,
  );
  assert.match(page, /if \(outcome\.status === "conflict"\) return outcome\.conflict;/);
  assert.match(dialog, /conflict\.canMatchExisting && conflict\.productId/);
  assert.match(dialog, /run\(\(\) => onConfirm\(productId\)\)/);
  assert.match(dialog, /Match to \{conflict\.productName\}/);
});

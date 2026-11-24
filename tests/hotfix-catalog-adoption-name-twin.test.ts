import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import test from "node:test";
import {
  catalogConflictMatchAction,
  toCatalogMatchConflict,
} from "../src/invoice/catalog-match.ts";
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
  // Reuse is only ever offered for the line's own SKU through an active mapping, to the
  // product that IS the selected catalog identity (or unlinked with nobody else holding it).
  assert.match(
    migration,
    /AND public\.normalize_catalog_sku_match_key\(_line\.sku\) = public\.normalize_catalog_sku_match_key\(_listing\.vendor_sku\)\n\s+AND \(\n\s+_conflict_product\.catalog_product_id = _listing\.catalog_product_id\n\s+OR \(\n\s+_conflict_product\.catalog_product_id IS NULL/,
  );
  assert.match(migration, /AND _conflict_vendor_product\.active\n/);
});

test("a SKU mapped to a different catalog item is named and never offered", () => {
  const explanation = migration.slice(
    migration.indexOf("_explanation := CASE"),
    migration.indexOf("RAISE EXCEPTION '%'"),
  );
  // "Match this line" appears only in the branch guarded by _can_match_existing.
  assert.equal(explanation.match(/Match this line/g)?.length, 1);
  assert.match(
    explanation,
    /AND _conflict_product\.id IS NOT NULL AND _can_match_existing THEN\s+format\('Vendor SKU %s is already mapped to "%s", which is this catalog item\. Match this line to "%s"\.'/,
  );
  assert.match(
    explanation,
    /which is linked to a different catalog item\. Correct that mapping in Catalog first\./,
  );
  // An unlinked SKU product cannot take a catalog item another product already holds.
  assert.match(
    migration,
    /'conflictType', 'catalog_product_adopted_elsewhere', 'productId', _organization_product\.id/,
  );
});

test("only the server's explicit canMatchExisting produces a Match action", () => {
  const conflict = (hint: Record<string, unknown>) =>
    toCatalogMatchConflict(`${PREFIX}x`, JSON.stringify(hint));
  const safe = conflict({
    conflictType: "sku_mapped_to_other_listing",
    productId: PRODUCT,
    productName: "Ready Wrap",
    canMatchExisting: true,
  });
  assert.deepEqual(catalogConflictMatchAction(safe), {
    productId: PRODUCT,
    label: "Match to Ready Wrap",
  });
  // A cross-catalog contradiction, a name-only twin, a held catalog item: the database says
  // false, so nothing is offered even with a product id and name present.
  for (const conflictType of [
    "sku_mapped_to_other_product",
    "name_twin_local",
    "name_twin_taken",
    "catalog_product_adopted_elsewhere",
  ]) {
    const refused = conflict({
      conflictType,
      productId: PRODUCT,
      productName: "Ammex Large",
      canMatchExisting: false,
    });
    assert.equal(catalogConflictMatchAction(refused), null, conflictType);
  }
  // Anything short of an explicit boolean true, or a malformed payload, offers nothing.
  for (const value of ["true", 1, null, undefined]) {
    assert.equal(
      catalogConflictMatchAction(
        conflict({ productId: PRODUCT, productName: "P", canMatchExisting: value }),
      ),
      null,
    );
  }
  assert.equal(catalogConflictMatchAction(toCatalogMatchConflict(`${PREFIX}x`, "{oops")), null);
  assert.equal(catalogConflictMatchAction(null), null);
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
  // The dialog renders the button only from the gate, and the button runs the ordinary
  // product confirmation. It never reads canMatchExisting or the product itself.
  assert.match(dialog, /const conflictMatch = catalogConflictMatchAction\(conflict\);/);
  assert.match(dialog, /\{conflictMatch && \(/);
  assert.match(dialog, /onClick=\{\(\) => run\(\(\) => onConfirm\(conflictMatch\.productId\)\)\}/);
  assert.doesNotMatch(dialog, /canMatchExisting|conflict\.productId|conflict\.productName/);
});

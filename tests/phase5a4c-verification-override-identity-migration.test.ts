import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const migration = await readFile(
  new URL(
    "supabase/migrations/20260825120000_phase5a4c_verification_override_identity.sql",
    root,
  ),
  "utf8",
);
const verification = await readFile(
  new URL("supabase/verification/phase5a4c_verification_override_identity.sql", root),
  "utf8",
);
const behavior = await readFile(
  new URL("supabase/tests/phase5a4c_verification_override_identity_behavior.sql", root),
  "utf8",
);

test("Phase 5A.4C changes only the named identity constraint", () => {
  assert.equal(
    migration.match(/ALTER TABLE public\.catalog_verification_overrides/g)?.length,
    1,
  );
  assert.equal(
    migration.match(/DROP CONSTRAINT catalog_verification_overrides_identity_present/g)?.length,
    1,
  );
  assert.equal(
    migration.match(/ADD CONSTRAINT catalog_verification_overrides_identity_present/g)?.length,
    1,
  );
  assert.doesNotMatch(
    migration,
    /\b(?:INSERT|UPDATE|DELETE|TRUNCATE|CREATE POLICY|DROP POLICY|GRANT|REVOKE|CREATE TRIGGER|DROP TRIGGER)\b/i,
  );
});

test("Phase 5A.4C identity check contains exactly the four approved paths", () => {
  const check = migration.match(
    /ADD CONSTRAINT catalog_verification_overrides_identity_present CHECK \(([\s\S]*?)\n  \);/,
  );
  assert.ok(check);
  assert.deepEqual(
    [...check[1].matchAll(/([a-z_]+) IS NOT NULL/g)].map((match) => match[1]),
    [
      "source_record_id",
      "normalized_source_vendor_sku",
      "normalized_verified_vendor_sku",
      "catalog_vendor_product_id",
    ],
  );
});

test("Phase 5A.4C catalog verification snippet is read-only and checks schema invariants", () => {
  assert.doesNotMatch(
    verification,
    /\b(?:ALTER|CREATE|DROP|INSERT|UPDATE|DELETE|TRUNCATE|GRANT|REVOKE)\b/i,
  );
  assert.match(verification, /constraint_exists_once/);
  assert.match(verification, /constraint_contains_all_four_identity_paths/);
  assert.match(verification, /conceptual_identity_truth_table_passes/);
  assert.match(verification, /other_constraint_set_unchanged/);
  assert.match(verification, /other_constraint_definitions_for_audit/);
});

test("Phase 5A.4C behavioral SQL is rollback-only and checks both identity outcomes", () => {
  assert.match(behavior, /BEGIN;[\s\S]*INSERT INTO public\.catalog_vendors/);
  assert.match(
    behavior,
    /normalized_verified_vendor_sku = '128-5851'/,
  );
  assert.match(
    behavior,
    /failed_constraint <> 'catalog_verification_overrides_identity_present'/,
  );
  assert.match(behavior, /ROLLBACK;[\s\S]*rollback-only test left persistent rows/);
  assert.doesNotMatch(behavior, /\bCOMMIT\b/i);
});

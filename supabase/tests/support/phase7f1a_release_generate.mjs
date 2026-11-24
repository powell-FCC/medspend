#!/usr/bin/env node
// Generates supabase/release/phase7f1a/precheck.sql and postcheck.sql from fingerprint.sql and
// two disposable databases. Never reads .env files or talks to a hosted project.
//
//   --pre  <port>  Postgres on 127.0.0.1 with every migration before 7F.1A (main be439a0).
//   --post <port>  The same with 20261125120000_phase7f1a_core_catalog_foundation.sql applied.
//   --check        Do not write; exit 1 if the committed files differ from what would be written.
//
// Both files are an assertion DO block followed by the exact fingerprint SELECT. The DO block
// compares every structural fingerprint row (functions, overloads, setting, tables, policies,
// grants, indexes, constraints, triggers, counts) with the reviewed value read from those
// databases, and fails on any missing, extra or different row. Data rows (hashes, catalog
// shape, catalog scope) are not asserted: they are compared precheck -> postcheck by hand.
// Before writing, the generator proves that pre -> post changes exactly the documented objects.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const release = join(root, "supabase/release/phase7f1a");
const args = process.argv.slice(2);
const option = (name) => {
  const index = args.indexOf(name);
  if (index < 0 || !args[index + 1]) throw new Error(`missing ${name} <port>`);
  return args[index + 1];
};
const prePort = option("--pre");
const postPort = option("--post");
const checkOnly = args.includes("--check");

const STRUCTURAL = [
  "function",
  "overloads",
  "setting",
  "table",
  "policies",
  "grants",
  "index",
  "constraint",
  "trigger",
  "count",
];
const CHANGED_FUNCTIONS = ["supply_request_product_search", "supply_request_product_identities"];
const ALTERED_TABLES = ["catalog_products", "catalog_vendor_products", "catalog_import_batches"];
const NEW_TABLES = [
  "catalog_brands",
  "catalog_bundle_components",
  "catalog_certification_types",
  "catalog_concept_synonyms",
  "catalog_concepts",
  "catalog_product_certifications",
  "catalog_product_concepts",
  "catalog_product_families",
];
const NEW_INDEXES_ON_EXISTING = [
  "catalog_products_brand_mpn_idx",
  "catalog_products_family_idx",
  "catalog_products_gtin_idx",
  "catalog_products_id_kind_uq",
  "catalog_vendor_products_last_seen_batch_idx",
];
const NEW_CONSTRAINTS_ON_EXISTING = [
  "catalog_import_batches.catalog_import_batches_source_type_check",
  "catalog_products.catalog_products_attributes_object",
  "catalog_products.catalog_products_brand_id_fkey",
  "catalog_products.catalog_products_family_id_fkey",
  "catalog_products.catalog_products_gtin_format",
  "catalog_products.catalog_products_mpn_requires_brand",
  "catalog_products.catalog_products_normalized_mpn_format",
  "catalog_products.catalog_products_product_kind_check",
  "catalog_products.catalog_products_purchase_restriction_check",
  "catalog_vendor_products.catalog_vendor_products_availability_observed",
  "catalog_vendor_products.catalog_vendor_products_availability_status_check",
  "catalog_vendor_products.catalog_vendor_products_last_seen_batch_fk",
  "catalog_vendor_products.catalog_vendor_products_last_seen_consistent",
  "catalog_vendor_products.catalog_vendor_products_listing_url_format",
];
const READ_ONLY_GRANTS = "authenticated=SELECT;service_role=DELETE,INSERT,SELECT,UPDATE";

const fingerprintFile = readFileSync(join(release, "fingerprint.sql"), "utf8");
const select = fingerprintFile.slice(fingerprintFile.indexOf("SELECT section, key, value FROM ("));

function fingerprintRows(port) {
  const out = execFileSync(
    "psql",
    [
      "-X",
      "-q",
      "-v",
      "ON_ERROR_STOP=1",
      "-U",
      "postgres",
      "-d",
      "postgres",
      "-At",
      "-F",
      "\t",
      "-c",
      select,
    ],
    {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
      env: {
        ...process.env,
        PGPASSWORD: "postgres",
        PGHOST: "127.0.0.1",
        PGPORT: port,
        PGOPTIONS: "-c client_min_messages=warning -c default_transaction_read_only=on",
      },
    },
  );
  const rows = new Map();
  for (const line of out.split("\n").filter(Boolean)) {
    const [section, key, value] = line.split("\t");
    rows.set(`${section}\t${key}`, value);
  }
  return rows;
}
const pre = fingerprintRows(prePort);
const post = fingerprintRows(postPort);
const structural = (rows) =>
  [...rows.entries()]
    .filter(([k]) => STRUCTURAL.includes(k.split("\t")[0]))
    .filter(([, v]) => v !== "absent")
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));

// Prove pre -> post changes exactly the documented objects.
const expectedChange = (section, key) => {
  if (section === "function") return CHANGED_FUNCTIONS.includes(key);
  if (section === "table") return ALTERED_TABLES.includes(key) || NEW_TABLES.includes(key);
  if (section === "policies" || section === "grants") return NEW_TABLES.includes(key);
  if (section === "index")
    return NEW_INDEXES_ON_EXISTING.includes(key) || NEW_TABLES.some((t) => key.startsWith(`${t}_`));
  if (section === "constraint" || section === "trigger")
    return (
      NEW_CONSTRAINTS_ON_EXISTING.includes(key) || NEW_TABLES.some((t) => key.startsWith(`${t}.`))
    );
  if (section === "count") return key !== "public functions";
  return false;
};
const problems = [];
for (const key of new Set([...pre.keys(), ...post.keys()])) {
  const [section, name] = key.split("\t");
  if (!STRUCTURAL.includes(section)) continue;
  const before = pre.get(key) ?? "absent";
  const after = post.get(key) ?? "absent";
  if (before !== after && !expectedChange(section, name))
    problems.push(`unexpected change ${section} ${name}: ${before} -> ${after}`);
  if (before === after && section === "function" && CHANGED_FUNCTIONS.includes(name))
    problems.push(`${name} did not change`);
}
for (const name of CHANGED_FUNCTIONS)
  if (
    !post
      .get(`function\t${name}`)
      ?.endsWith("secdef=true authenticated=false anon=false service_role=true public=false")
  )
    problems.push(`${name} access changed: ${post.get(`function\t${name}`)}`);
for (const name of NEW_TABLES) {
  if (pre.get(`table\t${name}`) !== "absent") problems.push(`${name} exists before the migration`);
  if (!post.get(`table\t${name}`)?.endsWith("rls=true")) problems.push(`${name} has no RLS`);
  if (post.get(`grants\t${name}`) !== READ_ONLY_GRANTS)
    problems.push(`${name} grants: ${post.get(`grants\t${name}`)}`);
  if (post.get(`policies\t${name}`) !== `${name}_authenticated_select:SELECT:authenticated`)
    problems.push(`${name} policies: ${post.get(`policies\t${name}`)}`);
}
for (const name of [...NEW_INDEXES_ON_EXISTING])
  if (!post.has(`index\t${name}`)) problems.push(`index ${name} missing`);
for (const name of NEW_CONSTRAINTS_ON_EXISTING)
  if (!post.has(`constraint\t${name}`)) problems.push(`constraint ${name} missing`);
// Data rows: identical (the migration writes only the one reference certification type).
for (const key of new Set([...pre.keys(), ...post.keys()])) {
  const [section, name] = key.split("\t");
  if (section === "rows" && pre.get(key) !== post.get(key)) problems.push(`rows ${name} changed`);
}
if (problems.length) {
  console.error(problems.join("\n"));
  process.exit(1);
}

const counts = (rows) =>
  Object.fromEntries(
    ["functions", "tables", "indexes", "policies", "triggers"].map((kind) => [
      kind,
      rows.get(`count\tpublic ${kind}`),
    ]),
  );
const preCounts = counts(pre);
const postCounts = counts(post);
const quote = (text) => text.replaceAll("'", "''");
const expectedValues = (rows) =>
  structural(rows)
    .map(([key, value], i, all) => {
      const [section, name] = key.split("\t");
      return `      ('${quote(section)}', '${quote(name)}', '${quote(value)}')${i < all.length - 1 ? "," : ""}`;
    })
    .join("\n");
const structuralSelect = select
  .replace(/\nORDER BY ord, section, key;\s*$/, "")
  .replace(/^SELECT section, key, value FROM \(/, "SELECT section, key, value FROM (");
const assertion = (
  rows,
  stage,
) => `  -- Every structural fingerprint row exactly as reviewed: nothing missing, extra or different.
  FOR _mismatch IN
    WITH expected(section, key, value) AS (VALUES
${expectedValues(rows)}
    ),
    actual AS (
      SELECT * FROM (
${structuralSelect
  .split("\n")
  .map((line) => `        ${line}`)
  .join("\n")}
      ) current_state
      WHERE section IN (${STRUCTURAL.map((s) => `'${s}'`).join(", ")}) AND value <> 'absent'
    )
    SELECT coalesce(e.section, a.section) || ' ' || coalesce(e.key, a.key) || ': expected '
      || coalesce(e.value, '(none)') || ', found ' || coalesce(a.value, '(none)')
    FROM expected e FULL JOIN actual a ON a.section = e.section AND a.key = e.key
    WHERE e.value IS DISTINCT FROM a.value
    ORDER BY 1
  LOOP
    RAISE EXCEPTION '${stage}: differs from the reviewed state: %', _mismatch;
  END LOOP;`;

const precheck = `-- Phase 7F.1A production PRECHECK. Run BEFORE 20261125120000_phase7f1a_core_catalog_foundation.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users can run the same file:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase7f1a/precheck.sql > phase7f1a_pre.txt
--
-- Success: the result grid shows the fingerprint rows. Download them as CSV (phase7f1a_pre.csv).
-- STOP: any error.
--
-- Pins production at main be439a0 (Catalog Adoption Name-Twin Hotfix): the search, discovery,
-- catalog, adoption, invoice-matching, request, Price Intelligence and role functions; every
-- catalog table and the identity, invoice, price and request tables (columns, RLS, policies,
-- grants, indexes, constraints, triggers); PostgreSQL 15+. Counts: functions ${preCounts.functions},
-- tables ${preCounts.tables}, indexes ${preCounts.indexes}, policies ${preCounts.policies}, triggers ${preCounts.triggers}.
-- Generated by supabase/tests/support/phase7f1a_release_generate.mjs; do not edit by hand.

DO $phase7f1a_precheck$
DECLARE
  _mismatch text;
BEGIN
  IF to_regclass('public.catalog_brands') IS NOT NULL OR to_regclass('public.catalog_concepts') IS NOT NULL
     OR to_regclass('public.catalog_product_certifications') IS NOT NULL THEN
    RAISE EXCEPTION 'precheck: Phase 7F.1A objects already exist';
  END IF;
  IF NOT has_schema_privilege(current_user, 'public', 'CREATE')
     OR NOT pg_has_role(current_user, (SELECT relowner FROM pg_class WHERE oid = 'public.catalog_products'::regclass), 'USAGE') THEN
    RAISE EXCEPTION 'precheck: % cannot alter the catalog tables', current_user;
  END IF;

${assertion(pre, "precheck")}
END
$phase7f1a_precheck$;

${select}`;

const postcheck = `-- Phase 7F.1A production POSTCHECK. Run AFTER 20261125120000_phase7f1a_core_catalog_foundation.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase7f1a/postcheck.sql > phase7f1a_post.txt
--
-- Success: the result grid shows the fingerprint rows. Download them as CSV (phase7f1a_post.csv)
-- and compare with the precheck (README.md lists the only lines that may differ).
-- STOP: any error.
--
-- Counts after the migration: functions ${postCounts.functions}, tables ${postCounts.tables}, indexes ${postCounts.indexes},
-- policies ${postCounts.policies}, triggers ${postCounts.triggers}.
-- Generated by supabase/tests/support/phase7f1a_release_generate.mjs; do not edit by hand.

DO $phase7f1a_postcheck$
DECLARE
  _mismatch text;
  _org uuid;
  _member uuid;
  _sku text;
  _found integer;
BEGIN
${assertion(post, "postcheck")}

  -- Nothing was backfilled: every existing catalog row carries only the safe defaults.
  IF EXISTS (SELECT 1 FROM public.catalog_products
             WHERE brand_id IS NOT NULL OR family_id IS NOT NULL OR normalized_mpn IS NOT NULL OR gtin IS NOT NULL
                OR attributes <> '{}'::jsonb OR product_kind <> 'single' OR purchase_restriction <> 'unknown')
     OR EXISTS (SELECT 1 FROM public.catalog_vendor_products
                WHERE listing_url IS NOT NULL OR last_seen_batch_id IS NOT NULL OR availability_status IS NOT NULL)
     OR EXISTS (SELECT 1 FROM public.catalog_import_batches WHERE source_type IS NOT NULL OR effective_date IS NOT NULL)
     OR EXISTS (SELECT 1 FROM public.catalog_brands) OR EXISTS (SELECT 1 FROM public.catalog_concepts)
     OR EXISTS (SELECT 1 FROM public.catalog_product_concepts) OR EXISTS (SELECT 1 FROM public.catalog_product_families)
     OR EXISTS (SELECT 1 FROM public.catalog_product_certifications) OR EXISTS (SELECT 1 FROM public.catalog_bundle_components)
     OR (SELECT array_agg(code) FROM public.catalog_certification_types) IS DISTINCT FROM ARRAY['nsf_certified_for_sport'] THEN
    RAISE EXCEPTION 'postcheck: catalog rows were backfilled or seeded unexpectedly';
  END IF;

  -- Catalog scope, as a member of each organization would search (transaction-local identity;
  -- nothing is written): an organization with an active linked vendor still finds a listing of
  -- that catalog by its exact SKU; an organization without one finds no global listing.
  FOR _org IN SELECT o.id FROM public.organizations o ORDER BY o.id LOOP
    SELECT m.user_id INTO _member FROM public.organization_memberships m
    WHERE m.organization_id = _org AND m.active ORDER BY m.role, m.user_id LIMIT 1;
    CONTINUE WHEN _member IS NULL;
    PERFORM set_config('request.jwt.claim.sub', _member::text, true);
    SELECT l.vendor_sku INTO _sku FROM public.catalog_vendor_products l
    JOIN public.vendors v ON v.catalog_vendor_id = l.catalog_vendor_id AND v.organization_id = _org AND v.active
    JOIN public.catalog_products p ON p.id = l.catalog_product_id AND p.active
    WHERE l.active AND NOT l.discontinued ORDER BY l.normalized_vendor_sku LIMIT 1;
    IF _sku IS NOT NULL THEN
      SELECT count(*) INTO _found FROM public.search_supply_request_products(_org, _sku, 5) s
      WHERE s.vendor_sku = _sku;
      IF _found = 0 THEN
        RAISE EXCEPTION 'postcheck: organization % no longer finds its catalog listing %', _org, _sku;
      END IF;
    ELSE
      SELECT l.vendor_sku INTO _sku FROM public.catalog_vendor_products l
      WHERE l.active AND NOT l.discontinued ORDER BY l.normalized_vendor_sku LIMIT 1;
      IF _sku IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.search_supply_request_products(_org, _sku, 5) s WHERE s.identity_source = 'global_catalog') THEN
        RAISE EXCEPTION 'postcheck: organization % without a linked catalog vendor still sees the global catalog', _org;
      END IF;
    END IF;
  END LOOP;
  PERFORM set_config('request.jwt.claim.sub', '', true);
END
$phase7f1a_postcheck$;

${select}`;

let differs = false;
for (const [name, text] of [
  ["precheck.sql", precheck],
  ["postcheck.sql", postcheck],
]) {
  let current = "";
  try {
    current = readFileSync(join(release, name), "utf8");
  } catch {
    current = "";
  }
  if (checkOnly) {
    if (current !== text) {
      differs = true;
      console.error(`${name} differs from the generated file`);
    } else console.log(`${name} matches the generated file`);
  } else if (current !== text) {
    writeFileSync(join(release, name), text);
    console.log(`wrote ${name}`);
  } else console.log(`${name} unchanged`);
}
console.log(`counts pre ${JSON.stringify(preCounts)} post ${JSON.stringify(postCounts)}`);
process.exit(differs ? 1 : 0);

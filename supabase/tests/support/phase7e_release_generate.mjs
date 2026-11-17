#!/usr/bin/env node
// Generates supabase/release/phase7e/precheck.sql and postcheck.sql from fingerprint.sql and
// two disposable databases. Never reads .env files or talks to a hosted project.
//
//   --pre  <port|file>  Postgres on 127.0.0.1 with every migration before 7E (main 63b86bb,
//                       through 7D), or a file holding the fingerprint's output there
//                       (psql -At -F ' | ').
//   --post <port|file>  The same with every migration including 7E.
//   --check        Do not write; exit 1 if the committed files differ from what would be written.
//   --out <dir>    Write the generated files to <dir> instead of the release folder.
//
// Both files are an assertion DO block followed by the exact fingerprint SELECT. The expected
// values in the DO blocks (function hashes, table, index, constraint, trigger and storage
// policy definitions, object counts) are read from the fingerprint on those databases.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const release = join(root, "supabase/release/phase7e");
const args = process.argv.slice(2);
const option = (name) => {
  const index = args.indexOf(name);
  if (index < 0 || !args[index + 1]) throw new Error(`missing ${name} <port|file>`);
  return args[index + 1];
};
const preSource = option("--pre");
const postSource = option("--post");
const checkOnly = args.includes("--check");
const outDir = args.includes("--out") ? args[args.indexOf("--out") + 1] : release;

const NEW_FUNCTIONS = [
  "delete_invoice_internal",
  "financial_assert_access",
  "financial_assert_range",
  "financial_commitment_rows",
  "financial_context_is",
  "financial_currency_basis",
  "financial_outside_budget_ids",
  "financial_possible_duplicate_ids",
  "financial_spend_line_rows",
  "financial_spend_row_json",
  "financial_spend_rows",
  "get_financial_document_detail",
  "get_financial_spend_series",
  "get_financial_spend_summary",
  "list_financial_commitments",
  "list_financial_document_removals",
  "list_financial_product_lines",
  "list_financial_product_spend",
  "list_financial_spend_documents",
  "list_financial_vendor_spend",
  "remove_posted_financial_document",
  "tg_financial_document_removals_append_only",
  "tg_guard_organization_budget_overlap",
  "tg_guard_posted_invoice",
  "tg_guard_posted_invoice_item",
  "vendor_invoice_storage_deletable",
];
// Changed by 7E with the same signatures and result shapes.
const CHANGED_FUNCTIONS = [
  "delete_invoice_permanently",
  "get_budget_lineage",
  "get_budget_purchasing_overview",
  "get_budget_summary",
  "get_price_intelligence_overview",
  "get_product_price_intelligence",
  "get_supply_request_budget_impact",
  "post_reviewed_invoice",
];
const NEW_TABLE = "financial_document_removals";
const NEW_TRIGGERS = [
  "financial_document_removals.financial_document_removals_append_only",
  "invoice_items.invoice_items_posted_guard",
  "invoices.invoices_posted_guard",
  "organization_budgets.organization_budgets_no_overlap",
];
const NEW_INDEXES = [
  "financial_document_removals_org_removed_idx",
  "financial_document_removals_pkey",
  "financial_document_removals_storage_path_idx",
  "invoices_org_posted_spend_idx",
];
const CHANGED_STORAGE_POLICY = "vendor_invoices_storage_owner_delete";
const PINNED_STORAGE_POLICIES = ["vendor_invoices_storage_owner_insert", "vendor_invoices_storage_owner_select"];

const fingerprintFile = readFileSync(join(release, "fingerprint.sql"), "utf8");
const select = fingerprintFile.slice(fingerprintFile.indexOf("SELECT section, key, value FROM ("));

function fingerprintRows(source) {
  const rows = new Map();
  if (!/^\d+$/.test(source)) {
    for (const line of readFileSync(source, "utf8").split("\n").filter(Boolean)) {
      const [section, key, ...rest] = line.split(" | ");
      rows.set(`${section}\t${key}`, rest.join(" | "));
    }
    return rows;
  }
  const out = execFileSync(
    "psql",
    ["-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-At", "-F", "\t", "-c", select],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PGPASSWORD: "postgres",
        PGHOST: "127.0.0.1",
        PGPORT: source,
        PGOPTIONS: "-c client_min_messages=warning -c default_transaction_read_only=on",
      },
    },
  );
  for (const line of out.split("\n").filter(Boolean)) {
    const [section, key, value] = line.split("\t");
    rows.set(`${section}\t${key}`, value);
  }
  return rows;
}
const pre = fingerprintRows(preSource);
const post = fingerprintRows(postSource);
const value = (rows, section, key) => {
  const found = rows.get(`${section}\t${key}`);
  if (found === undefined) throw new Error(`fingerprint has no ${section} | ${key}`);
  return found;
};
const keysOf = (rows, section) =>
  [...rows.keys()].filter((k) => k.startsWith(`${section}\t`)).map((k) => k.split("\t")[1]).sort();

const functionList = [
  ...select.slice(0, select.indexOf(") AS fn(name)")).matchAll(/^\s+\('([a-z0-9_]+)'\),?$/gm),
].map((m) => m[1]);
for (const name of [...NEW_FUNCTIONS, ...CHANGED_FUNCTIONS])
  if (!functionList.includes(name)) throw new Error(`${name} is not in the fingerprint`);
const pinnedFunctions = functionList
  .filter((name) => !NEW_FUNCTIONS.includes(name) && !CHANGED_FUNCTIONS.includes(name))
  .sort();
for (const name of pinnedFunctions) {
  if (value(pre, "function", name) === "absent") throw new Error(`pinned function ${name} is absent on the pre database`);
  if (value(pre, "function", name) !== value(post, "function", name)) throw new Error(`${name} differs between pre and post`);
}
for (const name of NEW_FUNCTIONS)
  if (value(pre, "function", name) !== "absent") throw new Error(`${name} exists on the pre database`);
for (const name of CHANGED_FUNCTIONS) {
  if (value(pre, "function", name) === "absent") throw new Error(`${name} is absent on the pre database`);
  if (value(pre, "function", name) === value(post, "function", name)) throw new Error(`${name} was expected to change`);
}
const pinnedTables = keysOf(pre, "table").filter((name) => name !== NEW_TABLE);
for (const name of pinnedTables)
  if (value(pre, "table", name) !== value(post, "table", name)) throw new Error(`table ${name} differs between pre and post`);
if (value(pre, "storage policy", CHANGED_STORAGE_POLICY) === value(post, "storage policy", CHANGED_STORAGE_POLICY))
  throw new Error(`${CHANGED_STORAGE_POLICY} was expected to change`);
for (const name of PINNED_STORAGE_POLICIES)
  if (value(pre, "storage policy", name) !== value(post, "storage policy", name)) throw new Error(`${name} changed`);
// Every existing index, constraint and trigger is unchanged; only the documented ones are new.
for (const section of ["index", "constraint", "trigger"]) {
  for (const key of keysOf(pre, section))
    if (value(pre, section, key) !== value(post, section, key)) throw new Error(`${section} ${key} changed`);
}

const valuesList = (pairs) =>
  pairs.map(([name, v], i) => `      ('${name}', '${v}')${i < pairs.length - 1 ? "," : ""}`).join("\n");
const counts = (rows) =>
  Object.fromEntries(
    ["functions", "tables", "indexes", "policies", "triggers"].map((kind) => [kind, value(rows, "count", `public ${kind}`)]),
  );
const preCounts = counts(pre);
const postCounts = counts(post);

const FUNCTION_VALUE = `      SELECT md5(pg_get_functiondef(p.oid)) || ' secdef=' || p.prosecdef
        || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
        || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')
        || ' service_role=' || has_function_privilege('service_role', p.oid, 'EXECUTE')
        || ' public=' || EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
                                 WHERE acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = expected.name ORDER BY p.oid LIMIT 1), 'absent')`;
const functionLoop = (pairs, message) => `  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((
${FUNCTION_VALUE})
    FROM (VALUES
${valuesList(pairs)}
    ) AS expected(name, value)
    WHERE coalesce((
${FUNCTION_VALUE} IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '${message}', _stage, _mismatch;
  END LOOP;`;
const TABLE_VALUE = `coalesce((SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum)) || ' rls=' || bool_and(c.relrowsecurity)
      FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      WHERE c.oid = to_regclass('public.' || expected.name)), 'absent')`;
const tableLoop = (pairs, message) => `  FOR _mismatch IN
    SELECT expected.name FROM (VALUES
${valuesList(pairs)}
    ) AS expected(name, value)
    WHERE ${TABLE_VALUE} IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '${message}', _stage, _mismatch;
  END LOOP;`;
const STORAGE_POLICY_VALUE = `(SELECT pol.polcmd::text || ' ' || md5(coalesce(pg_get_expr(pol.polqual, pol.polrelid), '')
      || '|' || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), ''))
      FROM pg_policy pol WHERE pol.polrelid = to_regclass('storage.objects') AND pol.polname = expected.name)`;
const storagePolicyLoop = (pairs, message) => `  FOR _mismatch IN
    SELECT expected.name FROM (VALUES
${valuesList(pairs)}
    ) AS expected(name, value)
    WHERE ${STORAGE_POLICY_VALUE} IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '${message}', _stage, _mismatch;
  END LOOP;`;
const countCheck = (c) => `  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace) <> ${c.functions}
     OR (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> ${c.tables}
     OR (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public') <> ${c.indexes}
     OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'public') <> ${c.policies}
     OR (SELECT count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
         WHERE c.relnamespace = 'public'::regnamespace AND NOT tg.tgisinternal) <> ${c.triggers} THEN
    RAISE EXCEPTION '%: public object counts differ from the reviewed state (expected functions ${c.functions}, tables ${c.tables}, indexes ${c.indexes}, policies ${c.policies}, triggers ${c.triggers})', _stage;
  END IF;`;
const enumCheck = `  IF (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'public.org_role'::regtype)
       IS DISTINCT FROM ARRAY['owner', 'admin', 'staff']
     OR (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'public.supply_request_status'::regtype)
       IS DISTINCT FROM ARRAY['submitted', 'under_review', 'approved', 'ordered', 'received', 'completed', 'denied', 'cancelled'] THEN
    RAISE EXCEPTION '%: organization roles or request statuses differ from the reviewed state', _stage;
  END IF;
  IF current_setting('TimeZone') NOT IN ('UTC', 'Etc/UTC') THEN
    RAISE EXCEPTION '%: the database TimeZone must be UTC (found %)', _stage, current_setting('TimeZone');
  END IF;`;
const dataChecks = `  -- Data 7E would treat differently from today: none may exist.
  IF EXISTS (SELECT 1 FROM public.invoices WHERE posted_at IS NOT NULL
             AND (document_type IN ('CREDIT_MEMO', 'STATEMENT') OR (currency_code IS NOT NULL AND upper(currency_code) <> 'USD'))) THEN
    RAISE EXCEPTION '%: posted credit memos, statements or other-currency documents exist; 7E would change budget figures. Review before releasing.', _stage;
  END IF;
  IF EXISTS (SELECT 1 FROM public.organization_budgets a JOIN public.organization_budgets b
             ON b.organization_id = a.organization_id AND b.id > a.id AND a.active AND b.active
             AND a.period_start <= b.period_end AND b.period_start <= a.period_end) THEN
    RAISE EXCEPTION '%: active budgets overlap; resolve before releasing 7E', _stage;
  END IF;`;
const pairsFor = (rows, section, keys) => keys.map((k) => [k, value(rows, section, k)]);

const precheck = `-- Phase 7E production PRECHECK. Run BEFORE 20261117120000_phase7e_budget_analytics.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users can run the same file:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase7e/precheck.sql > phase7e_pre.txt
--
-- Success: the result grid shows the fingerprint rows. Download them as CSV (phase7e_pre.csv).
-- STOP: any error.
--
-- Pins production through Phase 7D (main 63b86bb): the invoice, budget, request, commitment,
-- notification, role, inventory, replenishment and discovery functions; the financial,
-- request, inventory and organization tables; the vendor-invoices storage policies; the
-- organization roles and request statuses; UTC; and that no posted credit memo, statement,
-- other-currency document or overlapping active budget exists. Counts: functions ${preCounts.functions},
-- tables ${preCounts.tables}, indexes ${preCounts.indexes}, policies ${preCounts.policies}, triggers ${preCounts.triggers}. Generated by
-- supabase/tests/support/phase7e_release_generate.mjs; do not edit by hand.

DO $phase7e_precheck$
DECLARE
  _stage text := 'precheck';
  _mismatch text;
BEGIN
  IF to_regclass('public.financial_document_removals') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN ('invoices_posted_guard', 'invoice_items_posted_guard',
                'organization_budgets_no_overlap', 'financial_document_removals_append_only'))
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
${NEW_FUNCTIONS.map((name, i) => `                  '${name}'${i < NEW_FUNCTIONS.length - 1 ? "," : ")) THEN"}`).join("\n")}
    RAISE EXCEPTION 'precheck: Phase 7E objects already exist';
  END IF;
  IF to_regclass('public.inventory_replenishment_rules') IS NULL THEN
    RAISE EXCEPTION 'precheck: Phase 7D is not applied';
  END IF;

  -- Every function this phase builds on or must leave alone is exactly as reviewed.
${functionLoop(pairsFor(pre, "function", pinnedFunctions), "%: function is missing or differs from the reviewed production state: %")}

  -- The functions this phase changes, as reviewed before the migration.
${functionLoop(pairsFor(pre, "function", CHANGED_FUNCTIONS), "%: function is missing or differs from the reviewed production state: %")}

  -- Tables this phase reads or must leave alone: exact columns, types, NOT NULL and RLS.
${tableLoop(pairsFor(pre, "table", pinnedTables), "%: table is missing or differs from the reviewed production state: %")}

  -- The vendor-invoices storage policies (7E replaces the owner delete policy).
${storagePolicyLoop(pairsFor(pre, "storage policy", [CHANGED_STORAGE_POLICY, ...PINNED_STORAGE_POLICIES]), "%: storage policy is missing or differs from the reviewed production state: %")}

${enumCheck}

${dataChecks}

${countCheck(preCounts)}
END
$phase7e_precheck$;

${select}`;

const postcheck = `-- Phase 7E production POSTCHECK. Run AFTER 20261117120000_phase7e_budget_analytics.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase7e/postcheck.sql > phase7e_post.txt
--
-- Success: the result grid shows the fingerprint rows. Download them as CSV (phase7e_post.csv)
-- and compare with the precheck (README.md lists the only lines that may differ).
-- STOP: any error.
--
-- Generated by supabase/tests/support/phase7e_release_generate.mjs; do not edit by hand.

DO $phase7e_postcheck$
DECLARE
  _stage text := 'postcheck';
  _mismatch text;
BEGIN
  -- The new functions, exactly as reviewed (client RPCs callable by authenticated; internal
  -- calculations, helpers and trigger functions callable by no client role).
${functionLoop(pairsFor(post, "function", NEW_FUNCTIONS), "%: Phase 7E function is missing or differs from the reviewed migration: %")}

  -- The changed functions, exactly as reviewed.
${functionLoop(pairsFor(post, "function", CHANGED_FUNCTIONS), "%: Phase 7E function is missing or differs from the reviewed migration: %")}

  -- Everything else the precheck pinned is unchanged.
${functionLoop(pairsFor(pre, "function", pinnedFunctions), "%: function changed during the migration: %")}
${tableLoop(pairsFor(pre, "table", pinnedTables), "%: table changed during the migration: %")}
${storagePolicyLoop(pairsFor(post, "storage policy", [CHANGED_STORAGE_POLICY, ...PINNED_STORAGE_POLICIES]), "%: storage policy differs from the reviewed migration: %")}

${enumCheck}

  -- The removal record table: exact columns, RLS on, no policies, service_role SELECT only, empty.
${tableLoop([[NEW_TABLE, value(post, "table", NEW_TABLE)]], "%: Phase 7E table differs from the reviewed migration: %")}
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = '${NEW_TABLE}')
     OR EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE table_schema = 'public'
                AND table_name = '${NEW_TABLE}'
                AND (grantee IN ('anon', 'authenticated', 'PUBLIC') OR (grantee = 'service_role' AND privilege_type <> 'SELECT'))) THEN
    RAISE EXCEPTION '%: the removal record table must have no policies and no client grants', _stage;
  END IF;
  IF EXISTS (SELECT 1 FROM public.${NEW_TABLE}) THEN
    RAISE EXCEPTION '%: removal records exist that the migration does not create', _stage;
  END IF;

  -- New indexes, constraints and triggers, exactly as reviewed.
  FOR _mismatch IN
    SELECT expected.name FROM (VALUES
${valuesList(pairsFor(post, "index", NEW_INDEXES))}
    ) AS expected(name, value)
    WHERE (SELECT md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid FROM pg_index ix
           JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relname = expected.name) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: index is missing or differs: %', _stage, _mismatch;
  END LOOP;
  FOR _mismatch IN
    SELECT expected.name FROM (VALUES
${valuesList(pairsFor(post, "constraint", keysOf(post, "constraint").filter((k) => k.startsWith(`${NEW_TABLE}.`))))}
    ) AS expected(name, value)
    WHERE (SELECT con.contype::text || ' ' || md5(pg_get_constraintdef(con.oid)) || ' validated=' || con.convalidated
           FROM pg_constraint con JOIN pg_class t ON t.oid = con.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace
           WHERE n.nspname = 'public' AND t.relname || '.' || con.conname = expected.name) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: constraint is missing or differs: %', _stage, _mismatch;
  END LOOP;
  FOR _mismatch IN
    SELECT expected.name FROM (VALUES
${valuesList(pairsFor(post, "trigger", NEW_TRIGGERS))}
    ) AS expected(name, value)
    WHERE (SELECT md5(pg_get_triggerdef(tg.oid)) || ' enabled=' || tg.tgenabled::text FROM pg_trigger tg
           JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND NOT tg.tgisinternal AND c.relname || '.' || tg.tgname = expected.name) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: trigger is missing or differs: %', _stage, _mismatch;
  END LOOP;

  -- 7E's Spent equals the pre-7E formula for every active budget (no figure moved).
  FOR _mismatch IN
    SELECT budget.name FROM public.organization_budgets budget
    WHERE budget.active AND (
      SELECT coalesce(sum(document.amount), 0) FROM public.financial_spend_rows(budget.organization_id, budget.period_start, budget.period_end) document
      WHERE document.counted
    ) IS DISTINCT FROM (
      SELECT coalesce(sum(coalesce(i.invoice_total, i.total_amount, i.total,
        (SELECT sum(item.total_price) FROM public.invoice_items item WHERE item.invoice_id = i.id AND item.organization_id = i.organization_id), 0)), 0)
      FROM public.invoices i
      WHERE i.organization_id = budget.organization_id AND i.posted_at IS NOT NULL
        AND coalesce(i.invoice_date, (i.posted_at AT TIME ZONE 'UTC')::date) BETWEEN budget.period_start AND budget.period_end)
  LOOP
    RAISE EXCEPTION '%: Spent for budget % differs from the pre-7E figure', _stage, _mismatch;
  END LOOP;
${countCheck(postCounts)}
END
$phase7e_postcheck$;

${select}`;

let differs = false;
for (const [name, text] of [["precheck.sql", precheck], ["postcheck.sql", postcheck]]) {
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
    writeFileSync(join(outDir, name), text);
    console.log(`wrote ${name}`);
  } else console.log(`${name} unchanged`);
}
console.log(`counts pre ${JSON.stringify(preCounts)} post ${JSON.stringify(postCounts)}`);
process.exit(differs ? 1 : 0);

#!/usr/bin/env node
// Generates supabase/release/phase6b1/precheck.sql and postcheck.sql from fingerprint.sql and
// two disposable databases. Never reads .env files or talks to a hosted project.
//
//   --pre  <port|file>  Postgres on 127.0.0.1 with every migration before 6B.1 (main 18ab8ba,
//                       through 7E), or a file holding the fingerprint's output there
//                       (psql -At -F ' | ').
//   --post <port|file>  The same with every migration including 6B.1.
//   --check        Do not write; exit 1 if the committed files differ from what would be written.
//   --out <dir>    Write the generated files to <dir> instead of the release folder.
//
// Both files are an assertion DO block followed by the exact fingerprint SELECT. The expected
// values in the DO blocks (function hashes, table, index, constraint and trigger definitions,
// object counts) are read from the fingerprint on those databases.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const release = join(root, "supabase/release/phase6b1");
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
  "get_price_intelligence_summary",
  "get_product_vendor_price_history",
  "get_supply_request_price_context",
  "list_price_intelligence_products",
  "price_catalog_unit_agrees",
  "price_name_anchors",
  "price_observation_evidence",
  "price_observation_rows",
  "price_package_agreement",
  "price_product_state",
  "price_recency",
  "price_recent_anchors",
  "price_row_is_valid",
  "price_unit_is_valid",
  "price_unit_key",
];
// Changed by 6B.1 with the same signatures and result keys.
const CHANGED_FUNCTIONS = ["get_price_intelligence_overview", "get_product_price_intelligence"];
// Client RPCs (authenticated may execute); every other new function is internal.
const CLIENT_FUNCTIONS = [
  "get_price_intelligence_summary",
  "get_product_vendor_price_history",
  "get_supply_request_price_context",
  "list_price_intelligence_products",
];
const NEW_INDEXES = [
  "inventory_price_history_org_recent_idx",
  "inventory_price_history_product_vendor_order_idx",
];

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
const pinnedTables = keysOf(pre, "table");
for (const name of pinnedTables)
  if (value(pre, "table", name) !== value(post, "table", name)) throw new Error(`table ${name} differs between pre and post`);
for (const name of CLIENT_FUNCTIONS)
  if (!value(post, "function", name).endsWith("secdef=true authenticated=true anon=false service_role=true public=false"))
    throw new Error(`${name} grants are not the reviewed client grants: ${value(post, "function", name)}`);
for (const name of NEW_FUNCTIONS.filter((n) => !CLIENT_FUNCTIONS.includes(n)))
  if (!value(post, "function", name).endsWith("authenticated=false anon=false service_role=false public=false"))
    throw new Error(`internal ${name} is executable by a client role: ${value(post, "function", name)}`);
for (const name of NEW_INDEXES)
  if (value(post, "index", name) === undefined) throw new Error(`${name} missing`);
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
const pairsFor = (rows, section, keys) => keys.map((k) => [k, value(rows, section, k)]);

const precheck = `-- Phase 6B.1 production PRECHECK. Run BEFORE 20261123120000_phase6b1_multi_vendor_intelligence.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users can run the same file:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase6b1/precheck.sql > phase6b1_pre.txt
--
-- Success: the result grid shows the fingerprint rows. Download them as CSV (phase6b1_pre.csv).
-- STOP: any error.
--
-- Pins production through Phase 7E (main 18ab8ba): the two Price Intelligence functions this
-- phase changes, the 7E financial functions it builds on, the invoice, catalog, request,
-- commitment, notification, role, inventory, replenishment and discovery functions; the price,
-- invoice, vendor, product, request and inventory tables; the organization roles and request
-- statuses; and UTC. Counts: functions ${preCounts.functions}, tables ${preCounts.tables}, indexes ${preCounts.indexes},
-- policies ${preCounts.policies}, triggers ${preCounts.triggers}. Generated by
-- supabase/tests/support/phase6b1_release_generate.mjs; do not edit by hand.

DO $phase6b1_precheck$
DECLARE
  _stage text := 'precheck';
  _mismatch text;
BEGIN
  IF to_regclass('public.inventory_price_history_product_vendor_order_idx') IS NOT NULL
     OR to_regclass('public.inventory_price_history_org_recent_idx') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
${NEW_FUNCTIONS.map((name, i) => `                  '${name}'${i < NEW_FUNCTIONS.length - 1 ? "," : ")) THEN"}`).join("\n")}
    RAISE EXCEPTION 'precheck: Phase 6B.1 objects already exist';
  END IF;
  IF to_regclass('public.financial_document_removals') IS NULL THEN
    RAISE EXCEPTION 'precheck: Phase 7E is not applied';
  END IF;

  -- Every function this phase builds on or must leave alone is exactly as reviewed.
${functionLoop(pairsFor(pre, "function", pinnedFunctions), "%: function is missing or differs from the reviewed production state: %")}

  -- The functions this phase changes, as reviewed before the migration (exact signatures).
${functionLoop(pairsFor(pre, "function", CHANGED_FUNCTIONS), "%: function is missing or differs from the reviewed production state: %")}
  IF to_regprocedure('public.get_price_intelligence_overview(uuid)') IS NULL
     OR to_regprocedure('public.get_product_price_intelligence(uuid, uuid)') IS NULL THEN
    RAISE EXCEPTION '%: the Price Intelligence signatures differ from the reviewed production state', _stage;
  END IF;

  -- Tables this phase reads or must leave alone: exact columns, types, NOT NULL and RLS.
${tableLoop(pairsFor(pre, "table", pinnedTables), "%: table is missing or differs from the reviewed production state: %")}

  -- The SQL Editor role must be able to create functions and indexes in public.
  IF NOT has_schema_privilege(current_user, 'public', 'CREATE')
     OR NOT pg_has_role(current_user, (SELECT relowner FROM pg_class WHERE oid = 'public.inventory_price_history'::regclass), 'USAGE') THEN
    RAISE EXCEPTION '%: % cannot create the 6B.1 functions and indexes', _stage, current_user;
  END IF;

${enumCheck}

${countCheck(preCounts)}
END
$phase6b1_precheck$;

${select}`;

// The old Price Intelligence reads keep exactly the keys the deployed app parses (strictly).
const OLD_OVERVIEW_KEYS = ["averageWindowDays", "currencyCode", "organizationId", "productCount", "productLimit", "rows"];
const OLD_ROW_KEYS = ["absoluteChange", "bestAlternative", "comparability", "current", "percentChange", "previous", "productId", "productName", "recentAverage", "unitSavings"];
const OLD_DETAIL_KEYS = ["coverage", "currencyCode", "historyLimit", "organizationId", "packageComparability", "productId", "productName", "recentPurchases", "summary", "vendorHistory", "vendorLimit"];
const keyArray = (keys) => `ARRAY[${keys.map((k) => `'${k}'`).join(", ")}]`;

const postcheck = `-- Phase 6B.1 production POSTCHECK. Run AFTER 20261123120000_phase6b1_multi_vendor_intelligence.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase6b1/postcheck.sql > phase6b1_post.txt
--
-- Success: the result grid shows the fingerprint rows. Download them as CSV (phase6b1_post.csv)
-- and compare with the precheck (README.md lists the only lines that may differ).
-- STOP: any error.
--
-- Generated by supabase/tests/support/phase6b1_release_generate.mjs; do not edit by hand.

DO $phase6b1_postcheck$
DECLARE
  _stage text := 'postcheck';
  _mismatch text;
  _org uuid;
  _owner uuid;
  _product uuid;
  _overview jsonb;
  _detail jsonb;
BEGIN
  -- The new functions, exactly as reviewed (the four client RPCs callable by authenticated;
  -- every internal helper callable by no client role).
${functionLoop(pairsFor(post, "function", NEW_FUNCTIONS), "%: Phase 6B.1 function is missing or differs from the reviewed migration: %")}

  -- The changed functions, exactly as reviewed.
${functionLoop(pairsFor(post, "function", CHANGED_FUNCTIONS), "%: Phase 6B.1 function is missing or differs from the reviewed migration: %")}

  -- Everything else the precheck pinned is unchanged.
${functionLoop(pairsFor(pre, "function", pinnedFunctions), "%: function changed during the migration: %")}
${tableLoop(pairsFor(pre, "table", pinnedTables), "%: table changed during the migration: %")}

${enumCheck}

  -- The two new indexes, exactly as reviewed.
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

  -- The old Price Intelligence reads, as an owner of the first organization with price history
  -- would call them from the deployed app: exactly the same keys, no savings, no 90-day average.
  -- (Transaction-local identity; nothing is written.)
  SELECT h.organization_id INTO _org FROM public.inventory_price_history h ORDER BY h.organization_id LIMIT 1;
  IF _org IS NOT NULL THEN
    SELECT m.user_id INTO _owner FROM public.organization_memberships m
    WHERE m.organization_id = _org AND m.role = 'owner' AND m.active ORDER BY m.user_id LIMIT 1;
    SELECT h.product_id INTO _product FROM public.inventory_price_history h
    WHERE h.organization_id = _org ORDER BY h.purchase_date DESC, h.created_at DESC, h.id DESC LIMIT 1;
  END IF;
  IF _owner IS NOT NULL THEN
    PERFORM set_config('request.jwt.claim.sub', _owner::text, true);
    _overview := public.get_price_intelligence_overview(_org);
    _detail := public.get_product_price_intelligence(_org, _product);
    IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(_overview) k) IS DISTINCT FROM ${keyArray(OLD_OVERVIEW_KEYS)}
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(_overview -> 'rows') r
                  WHERE (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r) k) IS DISTINCT FROM ${keyArray(OLD_ROW_KEYS)}
                     OR r -> 'unitSavings' <> 'null'::jsonb OR r -> 'recentAverage' <> 'null'::jsonb)
       OR (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(_detail) k) IS DISTINCT FROM ${keyArray(OLD_DETAIL_KEYS)} THEN
      RAISE EXCEPTION '%: the deployed app''s Price Intelligence reads changed shape', _stage;
    END IF;
    -- The new reads answer for the same owner.
    PERFORM public.get_price_intelligence_summary(_org);
    PERFORM public.list_price_intelligence_products(_org);
    PERFORM public.get_product_vendor_price_history(_org, _product);
    PERFORM set_config('request.jwt.claim.sub', '', true);
  END IF;

${countCheck(postCounts)}
END
$phase6b1_postcheck$;

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

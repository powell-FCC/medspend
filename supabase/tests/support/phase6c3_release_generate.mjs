#!/usr/bin/env node
// Generates supabase/release/phase6c3/precheck.sql and postcheck.sql from fingerprint.sql and
// two disposable databases. Never reads .env files or talks to a hosted project.
//
//   --pre  <port|file>  Postgres on 127.0.0.1 with every migration before 6C.3 (main c2891f6,
//                       through 6C.4), or a file holding the fingerprint's output there
//                       (psql -At -F ' | ').
//   --post <port|file>  The same with every migration including 6C.3.
//   --check        Do not write; exit 1 if the committed files differ from what would be written.
//   --out <dir>    Write the generated files to <dir> instead of the release folder.
//
// Both files are an assertion DO block followed by the exact fingerprint SELECT. The expected
// values in the DO blocks (function hashes, table definitions, index definitions, object
// counts) are read from the fingerprint as it runs on those databases, read-only.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../..");
const release = join(root, "supabase/release/phase6c3");
const args = process.argv.slice(2);
const option = (name) => {
  const index = args.indexOf(name);
  if (index < 0 || !args[index + 1]) throw new Error(`missing ${name} <port>`);
  return args[index + 1];
};
const prePort = option("--pre");
const postPort = option("--post");
const checkOnly = args.includes("--check");
const outDir = args.includes("--out") ? args[args.indexOf("--out") + 1] : release;

const NEW_FUNCTIONS = [
  "capture_supply_request_decision_notification",
  "capture_supply_request_submitted_notification",
  "claim_notification_deliveries",
  "complete_notification_delivery",
  "dispatch_notification_events",
  "enqueue_due_notification_digests",
  "get_organization_notification_settings",
  "guard_notification_sending_boundary",
  "notification_approver_digest_content",
  "notification_request_items",
  "set_organization_notification_sending",
  "update_organization_notification_settings",
];
const NEW_TABLES = [
  "notification_events",
  "notification_deliveries",
  "organization_notification_settings",
];
// The triggers 6C.3 adds (two event-capture triggers on existing request tables, two
// updated_at triggers and the sending-boundary guard on its own tables).
const NEW_TRIGGERS = [
  "notification_deliveries.notification_deliveries_updated_at",
  "organization_notification_settings.organization_notification_settings_sending_boundary",
  "organization_notification_settings.organization_notification_settings_updated_at",
  "supply_request_updates.supply_request_updates_decision_notification",
  "supply_requests.supply_requests_submitted_notification",
];
// Existing tables whose exact definition (columns, types, NOT NULL, RLS) both files assert.
const PINNED_TABLES = [
  "organization_memberships",
  "organizations",
  "profiles",
  "supply_request_items",
  "supply_request_updates",
  "supply_requests",
];

const fingerprintFile = readFileSync(join(release, "fingerprint.sql"), "utf8");
const select = fingerprintFile.slice(fingerprintFile.indexOf("SELECT section, key, value FROM ("));

function fingerprintRows(source) {
  if (!/^\d+$/.test(source)) {
    const rows = new Map();
    for (const line of readFileSync(source, "utf8").split("\n").filter(Boolean)) {
      const [section, key, ...rest] = line.split(" | ");
      rows.set(`${section}\t${key}`, rest.join(" | "));
    }
    return rows;
  }
  const port = source;
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
const value = (rows, section, key) => {
  const found = rows.get(`${section}\t${key}`);
  if (found === undefined) throw new Error(`fingerprint has no ${section} | ${key}`);
  return found;
};

// The function list is section 1 of the fingerprint.
const functionList = [
  ...select.slice(0, select.indexOf(") AS fn(name)")).matchAll(/^\s+\('([a-z0-9_]+)'\),?$/gm),
].map((m) => m[1]);
const pinnedFunctions = functionList.filter((name) => !NEW_FUNCTIONS.includes(name)).sort();
for (const name of pinnedFunctions) {
  if (value(pre, "function", name) === "absent")
    throw new Error(`pinned function ${name} is absent on the pre database`);
  if (value(pre, "function", name) !== value(post, "function", name))
    throw new Error(`${name} differs between pre and post`);
}
for (const name of NEW_FUNCTIONS) {
  if (value(pre, "function", name) !== "absent")
    throw new Error(`${name} exists on the pre database`);
}

const valuesList = (pairs) =>
  pairs
    .map(([name, v], i) => `      ('${name}', '${v}')${i < pairs.length - 1 ? "," : ""}`)
    .join("\n");
const counts = (rows) =>
  Object.fromEntries(
    ["functions", "tables", "indexes", "policies", "triggers"].map((kind) => [
      kind,
      value(rows, "count", `public ${kind}`),
    ]),
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
const countCheck = (
  c,
) => `  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace) <> ${c.functions}
     OR (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> ${c.tables}
     OR (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public') <> ${c.indexes}
     OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'public') <> ${c.policies}
     OR (SELECT count(*) FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid
         WHERE c.relnamespace = 'public'::regnamespace AND NOT tg.tgisinternal) <> ${c.triggers} THEN
    RAISE EXCEPTION '%: public object counts differ from the reviewed state (expected functions ${c.functions}, tables ${c.tables}, indexes ${c.indexes}, policies ${c.policies}, triggers ${c.triggers})', _stage;
  END IF;`;

const pinnedPairs = pinnedFunctions.map((name) => [name, value(pre, "function", name)]);
const tablePairs = PINNED_TABLES.map((name) => {
  if (value(pre, "table", name) !== value(post, "table", name))
    throw new Error(`table ${name} differs between pre and post`);
  return [name, value(pre, "table", name)];
});

// Tables Phase 6C.3 reads or must leave alone, and the role model recipient resolution builds
// on: org_role is exactly owner, admin, staff (is_org_admin = owner or admin, pinned by hash
// above) and supply_request_status includes cancelled (6C.2). Checked from the catalog.
const foundationChecks = `  -- Tables this phase reads or must leave alone: exact columns, types, NOT NULL and RLS.
  FOR _mismatch IN
    SELECT format('%s=%s', expected.name, coalesce((SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum)) || ' rls=' || bool_and(c.relrowsecurity)
      FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      WHERE c.oid = to_regclass('public.' || expected.name)), 'absent'))
    FROM (VALUES
${valuesList(tablePairs)}
    ) AS expected(name, value)
    WHERE coalesce((SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum)) || ' rls=' || bool_and(c.relrowsecurity)
      FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      WHERE c.oid = to_regclass('public.' || expected.name)), 'absent') IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: table is missing or differs from the reviewed production state: %', _stage, _mismatch;
  END LOOP;

  -- The role model and lifecycle statuses recipient resolution builds on.
  IF (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'public.org_role'::regtype)
       IS DISTINCT FROM ARRAY['owner', 'admin', 'staff']
     OR (SELECT array_agg(enumlabel::text ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = 'public.supply_request_status'::regtype)
       IS DISTINCT FROM ARRAY['submitted', 'under_review', 'approved', 'ordered', 'received', 'completed', 'denied', 'cancelled'] THEN
    RAISE EXCEPTION '%: organization roles or request statuses differ from the reviewed state', _stage;
  END IF;`;
const newPairs = NEW_FUNCTIONS.map((name) => [name, value(post, "function", name)]);
const newIndexes = [...post.keys()]
  .filter(
    (key) =>
      key.startsWith("index\t") &&
      /^(notification_|organization_notification_settings)/.test(key.split("\t")[1]),
  )
  .map((key) => key.split("\t")[1])
  .sort();

const precheck = `-- Phase 6C.3 production PRECHECK. Run BEFORE 20261110120000_phase6c3_request_notifications.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users can run the same file:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase6c3/precheck.sql > phase6c3_pre.txt
--
-- Success: the result grid shows the fingerprint rows. Download them as CSV (phase6c3_pre.csv).
-- STOP: any error.
--
-- Pins the current production foundation through Phase 6C.4 (main c2891f6): the request
-- lifecycle functions, the organization role helpers, budget, invoice, inventory, batch intake
-- and discovery functions, the definitions of the request, membership, organization and
-- profile tables, the organization roles and request statuses. Counts: functions ${preCounts.functions},
-- tables ${preCounts.tables}, indexes ${preCounts.indexes}, policies ${preCounts.policies}, triggers ${preCounts.triggers}. Generated by
-- supabase/tests/support/phase6c3_release_generate.mjs; do not edit by hand.

DO $phase6c3_precheck$
DECLARE
  _stage text := 'precheck';
  _mismatch text;
BEGIN
  IF to_regclass('public.notification_events') IS NOT NULL
     OR to_regclass('public.notification_deliveries') IS NOT NULL
     OR to_regclass('public.organization_notification_settings') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN ('supply_requests_submitted_notification', 'supply_request_updates_decision_notification'))
     OR EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public' AND p.proname IN (
${NEW_FUNCTIONS.map((name, i) => `                  '${name}'${i < NEW_FUNCTIONS.length - 1 ? "," : ")) THEN"}`).join("\n")}
    RAISE EXCEPTION 'precheck: Phase 6C.3 objects already exist';
  END IF;
  IF to_regclass('public.invoice_upload_batches') IS NULL THEN
    RAISE EXCEPTION 'precheck: Phase 6C.4 is not applied';
  END IF;

  -- Every function this phase builds on or must leave alone is exactly as reviewed.
${functionLoop(pinnedPairs, "%: function is missing or differs from the reviewed production state: %")}

${foundationChecks}

${countCheck(preCounts)}
END
$phase6c3_precheck$;

${select}`;

const tableHash = (
  table,
) => `(SELECT md5(string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, ',' ORDER BY a.attnum)) || ' rls=' || bool_and(c.relrowsecurity)
      FROM pg_class c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      WHERE c.oid = to_regclass('public.${table}'))`;

const newTriggerPairs = NEW_TRIGGERS.map((key) => [key, value(post, "trigger", key)]);
const postcheck = `-- Phase 6C.3 production POSTCHECK. Run AFTER 20261110120000_phase6c3_request_notifications.sql.
--
-- Safe for the Supabase SQL Editor: no psql meta-commands, no transaction control, and no
-- writes (one read-only DO block of assertions, then one SELECT). Paste the whole file and run
-- it once. psql users:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F ' | ' -f supabase/release/phase6c3/postcheck.sql > phase6c3_post.txt
--
-- Success: the result grid shows the fingerprint rows. Download them as CSV (phase6c3_post.csv)
-- and compare with the precheck (README.md lists the only lines that may differ).
-- STOP: any error.
--
-- Generated by supabase/tests/support/phase6c3_release_generate.mjs; do not edit by hand.

DO $phase6c3_postcheck$
DECLARE
  _stage text := 'postcheck';
  _mismatch text;
BEGIN
  -- The new functions, exactly as reviewed (two admin settings RPCs, worker functions for the
  -- service role only, three trigger functions without client EXECUTE).
${functionLoop(newPairs, "%: Phase 6C.3 function is missing or differs from the reviewed migration: %")}

  -- Everything the precheck pinned is unchanged.
${functionLoop(pinnedPairs, "%: function changed during the migration: %")}

${foundationChecks}

  -- New tables: exact columns, RLS on, no policies, service_role SELECT only.
  IF ${tableHash(NEW_TABLES[0])} IS DISTINCT FROM '${value(post, "table", NEW_TABLES[0])}'
     OR ${tableHash(NEW_TABLES[1])} IS DISTINCT FROM '${value(post, "table", NEW_TABLES[1])}'
     OR ${tableHash(NEW_TABLES[2])} IS DISTINCT FROM '${value(post, "table", NEW_TABLES[2])}' THEN
    RAISE EXCEPTION '%: Phase 6C.3 tables differ from the reviewed migration', _stage;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('notification_events', 'notification_deliveries', 'organization_notification_settings'))
     OR EXISTS (SELECT 1 FROM information_schema.role_table_grants WHERE table_schema = 'public'
                AND table_name IN ('notification_events', 'notification_deliveries', 'organization_notification_settings')
                AND (grantee IN ('anon', 'authenticated', 'PUBLIC') OR (grantee = 'service_role' AND privilege_type <> 'SELECT'))) THEN
    RAISE EXCEPTION '%: Phase 6C.3 tables must have no policies and no client grants', _stage;
  END IF;
  -- Nothing is configured or delivered by the migration: no settings rows (every organization
  -- on the defaults, master sending OFF) and no deliveries. Events may already exist if requests
  -- were submitted or decided since the migration; they stay pending until the Worker runs.
  IF EXISTS (SELECT 1 FROM public.organization_notification_settings) OR EXISTS (SELECT 1 FROM public.notification_deliveries)
     OR EXISTS (SELECT 1 FROM public.notification_events WHERE status <> 'pending' OR event_type = 'approver_digest') THEN
    RAISE EXCEPTION '%: Phase 6C.3 tables hold configuration or deliveries the migration does not create', _stage;
  END IF;
  FOR _mismatch IN
    SELECT expected.name FROM (VALUES
${valuesList(newIndexes.map((name) => [name, value(post, "index", name)]))}
    ) AS expected(name, value)
    WHERE (SELECT md5(pg_get_indexdef(ix.indexrelid)) || ' valid=' || ix.indisvalid FROM pg_index ix
           JOIN pg_class c ON c.oid = ix.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relname = expected.name) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: index is missing or differs: %', _stage, _mismatch;
  END LOOP;
  FOR _mismatch IN
    SELECT expected.name FROM (VALUES
${valuesList(newTriggerPairs)}
    ) AS expected(name, value)
    WHERE (SELECT md5(pg_get_triggerdef(tg.oid)) || ' enabled=' || tg.tgenabled::text FROM pg_trigger tg
           JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND NOT tg.tgisinternal AND c.relname || '.' || tg.tgname = expected.name) IS DISTINCT FROM expected.value
  LOOP
    RAISE EXCEPTION '%: trigger is missing or differs: %', _stage, _mismatch;
  END LOOP;
${countCheck(postCounts)}
END
$phase6c3_postcheck$;

${select}`;

let differs = false;
for (const [name, text] of [
  ["precheck.sql", precheck],
  ["postcheck.sql", postcheck],
]) {
  const current = readFileSync(join(release, name), "utf8");
  const path = join(outDir, name);
  if (checkOnly) {
    if (current !== text) {
      differs = true;
      console.error(`${name} differs from the generated file`);
    } else console.log(`${name} matches the generated file`);
  } else if (current !== text) {
    writeFileSync(path, text);
    console.log(`wrote ${name}`);
  } else console.log(`${name} unchanged`);
}
console.log(`counts pre ${JSON.stringify(preCounts)} post ${JSON.stringify(postCounts)}`);
process.exit(differs ? 1 : 0);

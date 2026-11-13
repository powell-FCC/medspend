// Phase 7D structural checks: release files and migration shape. Behaviour is proven by the SQL
// suite, the race, mutation and release checks, the integration test and the unit tests.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const migration = read("supabase/migrations/20261113120000_phase7d_inventory_replenishment.sql");
const code = migration.replace(/--.*$/gm, "");

test("precheck and postcheck end with exactly the shared fingerprint SELECT", () => {
  const fingerprint = read("supabase/release/phase7d/fingerprint.sql");
  const select = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM ("));
  for (const file of ["precheck", "postcheck"]) {
    const text = read(`supabase/release/phase7d/${file}.sql`);
    assert.ok(text.endsWith(select), `${file}.sql ends with the fingerprint`);
    assert.doesNotMatch(
      text,
      /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im,
      `${file}.sql has no transaction control`,
    );
    assert.doesNotMatch(text, /^\\/m, `${file}.sql has no psql meta-commands`);
  }
  const precheck = read("supabase/release/phase7d/precheck.sql");
  assert.match(
    precheck,
    /expected functions 174, tables 53, indexes 199, policies 58, triggers 84/,
  );
  assert.match(precheck, /precheck: Phase 7C is not applied/);
  assert.match(precheck, /precheck: Phase 7D objects already exist/);
  for (const name of [
    "post_reviewed_invoice",
    "inventory_workspace_stock_status",
    "receive_supply_request",
    "submit_inventory_count",
  ]) {
    assert.match(precheck, new RegExp(`\\('${name}', '[0-9a-f]{32} `), name);
  }
  const postcheck = read("supabase/release/phase7d/postcheck.sql");
  assert.match(
    postcheck,
    /expected functions 182, tables 54, indexes 203, policies 58, triggers 85/,
  );
  for (const name of [
    "set_inventory_replenishment_rule",
    "set_inventory_replenishment_rule_enabled",
    "list_inventory_replenishment",
    "get_inventory_replenishment_summary",
    "list_inventory_location_replenishment_rules",
    "move_inventory_stock",
  ]) {
    assert.match(
      postcheck,
      new RegExp(
        `\\('${name}', '[0-9a-f]{32} secdef=true authenticated=true anon=false service_role=true public=false'\\)`,
      ),
      name,
    );
  }
  for (const name of [
    "inventory_replenishment_rows",
    "inventory_replenishment_rule_json",
    "tg_guard_inventory_replenishment_rule",
  ]) {
    assert.match(
      postcheck,
      new RegExp(`\\('${name}', '[0-9a-f]{32} secdef=false authenticated=false anon=false`),
      name,
    );
  }
  assert.match(postcheck, /inventory_replenishment_rules\.inventory_replenishment_rules_guard/);
  assert.match(postcheck, /inventory_transfers\.inventory_transfers_source_check/);
  assert.match(postcheck, /EXISTS \(SELECT 1 FROM public\.inventory_replenishment_rules\)/);
  assert.match(postcheck, /an existing transfer is not marked manual/);
  assert.match(
    postcheck,
    /move_inventory_stock does not have exactly the seven-argument signature/,
  );
  // move_inventory_stock is pinned at its reviewed body before and the source-aware body after.
  const pin = (text: string) => text.match(/\('move_inventory_stock', '([0-9a-f]{32}) /)?.[1];
  assert.ok(pin(precheck) && pin(postcheck) && pin(precheck) !== pin(postcheck));
  // The transfer hash is comparable across the new column; par_level is fingerprinted with items.
  assert.match(fingerprint, /'inventory_transfers hash \(without source\)'/);
  assert.match(fingerprint, /\('inventory_items'\)/);
});

test("the migration is one transaction, enables RLS itself, writes no rows and refuses a rerun first", () => {
  assert.equal(migration.match(/^BEGIN;$/gm)?.length, 1);
  assert.equal(migration.match(/^COMMIT;$/gm)?.length, 1);
  assert.doesNotMatch(migration, /create\s+temp/i);
  assert.match(
    code,
    /ALTER TABLE public\.inventory_replenishment_rules ENABLE ROW LEVEL SECURITY;/,
  );
  assert.doesNotMatch(code, /CREATE POLICY/);
  assert.doesNotMatch(
    code,
    /GRANT [A-Z, ]+ ON (TABLE )?public\.inventory_replenishment_rules TO (anon|authenticated)/,
  );
  assert.doesNotMatch(code, /TO anon\b/);
  // Additive: outside function bodies (move_inventory_stock keeps its 7A.1 balance writes),
  // no rows are written and no balances, items, requests or notifications are touched.
  const statements = code.replace(/AS \$\$[\s\S]*?\n\$\$;/g, "");
  assert.doesNotMatch(
    statements,
    /(INSERT INTO|UPDATE|DELETE FROM) public\.(inventory_items|inventory_location_balances|inventory_adjustments|supply_requests|supply_request_items|notification_events|invoices)\b/i,
  );
  assert.doesNotMatch(code, /ALTER TABLE public\.inventory_items/);
  // A rerun is refused by the existence check before the dependency check (7D drops the
  // six-argument move_inventory_stock the dependency check looks for).
  assert.ok(
    code.indexOf("Phase 7D replenishment objects already exist unexpectedly") <
      code.indexOf("Phase 7D requires Phase 7C"),
  );
});

test("release README documents the order, the deltas, the compatibility window and FC Cincinnati", () => {
  const readme = read("supabase/release/phase7d/README.md");
  assert.match(
    readme,
    /functions 174 → 182, tables 53 → 54, indexes 199 → 203, triggers 84 → 85, policies 58/,
  );
  assert.match(readme, /## Compatibility window \(migrate first, then deploy\)/);
  assert.match(readme, /recorded `manual`/);
  assert.match(readme, /No rule is created by the release, and these scripts create none\./);
  assert.match(
    readme,
    /Acceptance is read-only: do not create a production rule, transfer, count or request for it\./,
  );
  assert.match(readme, /nothing reads `inventory_items\.par_level`/);
});

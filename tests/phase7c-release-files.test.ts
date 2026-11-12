// Phase 7C structural checks: release files and migration grants. Behaviour is proven by the
// SQL suite, the race, mutation and release checks, the integration test and the unit tests.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const migration = read("supabase/migrations/20261112140000_phase7c_receiving_destination.sql");
const code = migration.replace(/--.*$/gm, "");

test("precheck and postcheck end with exactly the shared fingerprint SELECT", () => {
  const fingerprint = read("supabase/release/phase7c/fingerprint.sql");
  const select = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM ("));
  for (const file of ["precheck", "postcheck"]) {
    const text = read(`supabase/release/phase7c/${file}.sql`);
    assert.ok(text.endsWith(select), `${file}.sql ends with the fingerprint`);
    assert.doesNotMatch(
      text,
      /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im,
      `${file}.sql has no transaction control`,
    );
    assert.doesNotMatch(text, /^\\/m, `${file}.sql has no psql meta-commands`);
  }
  const precheck = read("supabase/release/phase7c/precheck.sql");
  assert.match(
    precheck,
    /expected functions 171, tables 52, indexes 194, policies 58, triggers 83/,
  );
  assert.match(precheck, /precheck: Phase 7C\.0 is not applied/);
  for (const name of ["decide_supply_request", "post_reviewed_invoice", "move_inventory_stock"]) {
    assert.match(precheck, new RegExp(`\\('${name}', '[0-9a-f]{32} `), name);
  }
  const postcheck = read("supabase/release/phase7c/postcheck.sql");
  assert.match(
    postcheck,
    /expected functions 174, tables 53, indexes 199, policies 58, triggers 84/,
  );
  for (const name of [
    "list_receiving_destinations",
    "list_supply_request_receipts",
    "receive_supply_request",
    "receive_and_complete_supply_request",
  ]) {
    assert.match(
      postcheck,
      new RegExp(
        `\\('${name}', '[0-9a-f]{32} secdef=true authenticated=true anon=false service_role=false public=false'\\)`,
      ),
      name,
    );
  }
  assert.match(
    postcheck,
    /\('apply_supply_request_receipt', '[0-9a-f]{32} secdef=true authenticated=false anon=false service_role=false public=false'\)/,
  );
  assert.match(postcheck, /supply_request_receipts\.supply_request_receipts_immutable/);
  assert.match(postcheck, /EXISTS \(SELECT 1 FROM public\.supply_request_receipts\)/);
  assert.match(postcheck, /a destination-less receive signature still exists/);
  // transition_supply_request is pinned at its reviewed body before and the refusing body after.
  const pin = (text: string) => text.match(/\('transition_supply_request', '([0-9a-f]{32}) /)?.[1];
  assert.ok(pin(precheck) && pin(postcheck) && pin(precheck) !== pin(postcheck));
});

test("the migration is one transaction, enables RLS itself and grants nothing to clients on its table", () => {
  assert.equal(migration.match(/^BEGIN;$/gm)?.length, 1);
  assert.equal(migration.match(/^COMMIT;$/gm)?.length, 1);
  assert.doesNotMatch(migration, /create\s+temp/i);
  assert.match(code, /ALTER TABLE public\.supply_request_receipts ENABLE ROW LEVEL SECURITY;/);
  assert.doesNotMatch(code, /CREATE POLICY/);
  assert.match(code, /GRANT SELECT ON public\.supply_request_receipts TO service_role;/);
  assert.doesNotMatch(
    code,
    /GRANT [A-Z, ]+ ON (TABLE )?public\.supply_request_receipts TO (anon|authenticated)/,
  );
  assert.doesNotMatch(code, /TO anon\b/);
  // Destination-only: no stock, invoice or inventory writes, and no locations created.
  assert.doesNotMatch(
    code,
    /(INSERT INTO|UPDATE|DELETE FROM) public\.(inventory_\w+|invoices|invoice_\w+|organization_budgets|supply_request_commitments)\b/i,
  );
  assert.doesNotMatch(code, /public\.(apply_inventory_location_delta|move_inventory_stock)\(/);
  // A rerun is refused by the existence check before the dependency check.
  assert.ok(
    code.indexOf("receiving destination objects already exist unexpectedly") <
      code.indexOf("Phase 7C requires Phase 7A.1"),
  );
  assert.match(code, /Use the receiving action to choose a receiving destination\./);
  assert.match(
    code,
    /Refresh SportSpend and choose a receiving destination to receive this request\./,
  );
});

test("release README documents the order, the deltas, the compatibility window and locations", () => {
  const readme = read("supabase/release/phase7c/README.md");
  assert.match(
    readme,
    /functions 171 → 174, tables 52 → 53, indexes 194 → 199, triggers 83 → 84, policies 58/,
  );
  assert.match(readme, /## Compatibility window \(migrate first, then deploy\)/);
  assert.match(readme, /deliberately no destination-less fallback/);
  assert.match(readme, /FC Cincinnati currently has only \*\*Unassigned\*\*/);
  assert.match(readme, /Creating locations is not part of this release/);
  assert.match(readme, /requests received before 7C have no receipt/);
});

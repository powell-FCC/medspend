// Phase 7C.0 structural checks: release files and migration grants. Behaviour is proven by the
// SQL suite, the race, mutation and release checks, the integration test and the unit tests.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const migration = read("supabase/migrations/20261112120000_phase7c0_request_workflow_profiles.sql");

test("precheck and postcheck end with exactly the shared fingerprint SELECT", () => {
  const fingerprint = read("supabase/release/phase7c0/fingerprint.sql");
  const select = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM ("));
  for (const file of ["precheck", "postcheck"]) {
    const text = read(`supabase/release/phase7c0/${file}.sql`);
    assert.ok(text.endsWith(select), `${file}.sql ends with the fingerprint`);
    assert.doesNotMatch(
      text,
      /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im,
      `${file}.sql has no transaction control`,
    );
    assert.doesNotMatch(text, /^\\/m, `${file}.sql has no psql meta-commands`);
  }
  // Request history is hashed without the new column so the line compares across the migration.
  assert.match(fingerprint, /\(to_jsonb\(r\) - 'compound_action'\)::text/);
  const precheck = read("supabase/release/phase7c0/precheck.sql");
  assert.match(
    precheck,
    /expected functions 161, tables 51, indexes 193, policies 58, triggers 81/,
  );
  assert.match(precheck, /\('decide_supply_request', '[0-9a-f]{32} /);
  assert.match(precheck, /\('capture_supply_request_decision_notification', '[0-9a-f]{32} /);
  assert.match(precheck, /\('notification_approver_digest_content', '[0-9a-f]{32} /);
  assert.match(
    precheck,
    /\('list_staff_supply_request_updates', '[0-9a-f]{32} secdef=true authenticated=true anon=false/,
  );
  assert.match(precheck, /ARRAY\['owner', 'admin', 'staff'\]/);
  assert.match(
    precheck,
    /ARRAY\['submitted', 'under_review', 'approved', 'ordered', 'received', 'completed', 'denied', 'cancelled'\]/,
  );
  const postcheck = read("supabase/release/phase7c0/postcheck.sql");
  assert.match(
    postcheck,
    /expected functions 171, tables 52, indexes 194, policies 58, triggers 83/,
  );
  for (const name of [
    "approve_and_order_supply_request",
    "receive_and_complete_supply_request",
    "receive_supply_request",
    "get_request_workflow_profile",
    "get_organization_request_workflow_settings",
    "update_organization_request_workflow_settings",
  ]) {
    assert.match(
      postcheck,
      new RegExp(
        `\\('${name}', '[0-9a-f]{32} secdef=true authenticated=true anon=false service_role=false public=false'\\)`,
      ),
      name,
    );
  }
  for (const name of [
    "organization_request_workflow_profile",
    "mark_supply_request_compound_action",
    "apply_supply_request_receipt",
  ]) {
    assert.match(
      postcheck,
      new RegExp(
        `\\('${name}', '[0-9a-f]{32} secdef=true authenticated=false anon=false service_role=false public=false'\\)`,
      ),
      name,
    );
  }
  assert.match(postcheck, /supply_request_updates\.supply_request_updates_compound_action_guard/);
  assert.match(postcheck, /supply_request_updates\.supply_request_updates_compound_action_check/);
  assert.match(
    postcheck,
    /EXISTS \(SELECT 1 FROM public\.organization_request_workflow_settings\)/,
  );
});

test("the migration is one transaction, enables RLS itself and grants nothing to clients on its table", () => {
  assert.equal(migration.match(/^BEGIN;$/gm)?.length, 1);
  assert.equal(migration.match(/^COMMIT;$/gm)?.length, 1);
  assert.doesNotMatch(migration, /create\s+temp/i);
  assert.match(
    migration,
    /ALTER TABLE public\.organization_request_workflow_settings ENABLE ROW LEVEL SECURITY;/,
  );
  assert.doesNotMatch(migration, /CREATE POLICY/);
  assert.match(
    migration,
    /GRANT SELECT ON public\.organization_request_workflow_settings TO service_role;/,
  );
  assert.doesNotMatch(
    migration,
    /GRANT [A-Z, ]+ ON (TABLE )?public\.organization_request_workflow_settings TO (anon|authenticated)/,
  );
  assert.doesNotMatch(migration.replace(/--.*$/gm, ""), /TO anon\b/);
  assert.doesNotMatch(
    migration.replace(/--.*$/gm, ""),
    /INSERT INTO public\.organization_request_workflow_settings[^;]*VALUES[^;]*'lean'/,
  );
});

test("release README documents the order, the deltas, FC Cincinnati and the reporting caveat", () => {
  const readme = read("supabase/release/phase7c0/README.md");
  assert.match(
    readme,
    /functions 161 → 171, tables 51 → 52, indexes 193 → 194, triggers 81 → 83, policies 58/,
  );
  assert.match(readme, /Do not switch FC Cincinnati to Lean as part of the release/);
  assert.match(readme, /approval → order duration is intentionally 0/);
  assert.match(readme, /receipt → completion duration is intentionally 0/);
  assert.match(readme, /Migrate first/);
});

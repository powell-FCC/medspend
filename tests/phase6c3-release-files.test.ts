// Phase 6C.3 structural checks: release files and migration grants. Behaviour is proven by
// the SQL suite, the race and mutation checks, the integration test, the workerd scheduled
// check and the unit tests.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const migration = read("supabase/migrations/20261110120000_phase6c3_request_notifications.sql");
const NEW_TABLES = [
  "notification_events",
  "notification_deliveries",
  "organization_notification_settings",
];

test("precheck and postcheck end with exactly the shared fingerprint SELECT", () => {
  const fingerprint = read("supabase/release/phase6c3/fingerprint.sql");
  const select = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM ("));
  for (const file of ["precheck", "postcheck"]) {
    const text = read(`supabase/release/phase6c3/${file}.sql`);
    assert.ok(text.endsWith(select), `${file}.sql ends with the fingerprint`);
    assert.doesNotMatch(
      text,
      /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im,
      `${file}.sql has no transaction control`,
    );
    assert.doesNotMatch(text, /^\\/m, `${file}.sql has no psql meta-commands`);
  }
  const precheck = read("supabase/release/phase6c3/precheck.sql");
  assert.match(
    precheck,
    /expected functions 149, tables 48, indexes 181, policies 58, triggers 76/,
  );
  assert.match(
    precheck,
    /\('is_org_admin', '[0-9a-f]{32} secdef=true authenticated=true anon=(true|false) service_role=(true|false) public=(true|false)'\)/,
  );
  assert.match(precheck, /\('decide_supply_request', '[0-9a-f]{32} /);
  assert.match(precheck, /ARRAY\['owner', 'admin', 'staff'\]/);
  const postcheck = read("supabase/release/phase6c3/postcheck.sql");
  assert.match(
    postcheck,
    /expected functions 161, tables 51, indexes 193, policies 58, triggers 81/,
  );
  assert.match(
    postcheck,
    /\('claim_notification_deliveries', '[0-9a-f]{32} secdef=true authenticated=false anon=false service_role=true public=false'\)/,
  );
  assert.match(
    postcheck,
    /\('update_organization_notification_settings', '[0-9a-f]{32} secdef=true authenticated=true anon=false service_role=false public=false'\)/,
  );
  assert.match(postcheck, /supply_requests\.supply_requests_submitted_notification/);
  assert.match(
    postcheck,
    /organization_notification_settings\.organization_notification_settings_sending_boundary/,
  );
  assert.match(
    postcheck,
    /\('guard_notification_sending_boundary', '[0-9a-f]{32} secdef=true authenticated=false anon=false service_role=false public=false'\)/,
  );
  assert.match(postcheck, /supply_request_updates\.supply_request_updates_decision_notification/);
});

test("the migration is one transaction, enables RLS itself and grants nothing to clients on its tables", () => {
  assert.equal(migration.match(/^BEGIN;$/gm)?.length, 1);
  assert.equal(migration.match(/^COMMIT;$/gm)?.length, 1);
  assert.doesNotMatch(migration, /create\s+temp/i);
  for (const table of NEW_TABLES) {
    assert.match(migration, new RegExp(`ALTER TABLE public\\.${table} ENABLE ROW LEVEL SECURITY;`));
    assert.doesNotMatch(migration, new RegExp(`CREATE POLICY [a-z_]+ ON public\\.${table}`));
  }
  assert.match(
    migration,
    /REVOKE ALL ON public\.organization_notification_settings, public\.notification_events,\s+public\.notification_deliveries FROM PUBLIC, anon, authenticated, service_role;/,
  );
  assert.match(
    migration,
    /GRANT SELECT ON public\.organization_notification_settings, public\.notification_events,\s+public\.notification_deliveries TO service_role;/,
  );
  assert.doesNotMatch(migration, /GRANT [A-Z, ]+ ON (TABLE )?public\.notification/);
  assert.doesNotMatch(migration.replace(/--.*$/gm, ""), /TO anon\b/);
});

test("release README documents the rollout gates and the expected deltas", () => {
  const readme = read("supabase/release/phase6c3/README.md");
  assert.match(
    readme,
    /functions 149 → 161, tables 48 → 51, indexes 181 → 193, triggers 76 → 81, policies 58/,
  );
  assert.match(readme, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(readme, /RESEND_API_KEY/);
  assert.match(readme, /set_organization_notification_sending/);
  assert.match(readme, /master switch/);
  assert.match(readme, /created_before_sending_enabled/);
  assert.doesNotMatch(readme, /never replayed when the switch turns on/);
});

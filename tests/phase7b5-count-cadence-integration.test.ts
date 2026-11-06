// Phase 7B.5 API integration: the count cadence policy and freshness reads through a real
// PostgREST with signed user JWTs, via the same helpers the server functions use
// (src/inventory/workspace-reads.ts). The fixture has 300 storage locations and 28,000 count
// sessions. Started by supabase/tests/run_phase7b5_count_cadence_integration.sh; skipped by a
// plain `npm test`.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import {
  getCountFreshness,
  getCountPolicy,
  listAllWorkspaceLocations,
  setCountPolicy,
} from "../src/inventory/workspace-reads.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
// This suite writes data. It only ever runs against a loopback address.
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7b5_count_cadence_integration.sh";

const id = (suffix: string) => `7b5c0000-0000-4000-8000-000000000${suffix}`;
const ORG = id("101");
const OTHER_ORG = id("102");

const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
function signToken(claims: Record<string, unknown>) {
  const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ ...claims, exp: Math.floor(Date.now() / 1000) + 3600 })}`;
  return `${body}.${createHmac("sha256", JWT_SECRET).update(body).digest("base64url")}`;
}
function clientFor(claims: Record<string, unknown>): SupabaseClient<Database> {
  return createClient<Database>(REST_URL, "local-publishable-key", {
    global: {
      headers: { Authorization: `Bearer ${signToken(claims)}` },
      fetch: (input, init) => fetch(String(input).replace("/rest/v1", ""), init),
    },
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });
}
const user = (suffix: string) =>
  configured ? clientFor({ role: "authenticated", sub: id(suffix) }) : (null as never);
const owner = user("001");
const admin = user("002");
const staff = user("003");
const otherOwner = user("004");
const otherAdmin = user("005");
const stranger = user("009");
const anon = configured ? clientFor({ role: "anon" }) : (null as never);
type Db = SupabaseClient<Database>;

// Expected states from the fixture: L001..L280 newest count ((n - 1) % 60) days + 12 hours
// ago, so with a 30-day cadence k < 30 is current, k = 30 is due (30d12h: within the day after
// it came due) and k > 30 is overdue. L281..L300 were never counted.
const counted = Array.from({ length: 280 }, (_, i) => i % 60);
const expected = {
  current: counted.filter((k) => k < 30).length,
  due: counted.filter((k) => k === 30).length,
  overdue: counted.filter((k) => k > 30).length,
  neverCounted: 20,
  nothingToCount: 3,
};

test("policy: no row means off, for owner and admin alike", { skip }, async () => {
  for (const db of [owner, admin])
    assert.deepEqual(await getCountPolicy(db, ORG), {
      configured: false,
      enabled: false,
      intervalDays: null,
      updatedAt: null,
      updatedByName: null,
    });
});

test("cadence off: factual states only, nothing due or overdue", { skip }, async () => {
  for (const db of [owner, admin]) {
    const off = await getCountFreshness(db, { organizationId: ORG });
    assert.deepEqual(off.policy, { enabled: false, intervalDays: null });
    assert.deepEqual(off.summary, {
      current: 0,
      due: 0,
      overdue: 0,
      neverCounted: expected.neverCounted,
      counted: 280,
      nothingToCount: expected.nothingToCount,
    });
    assert.deepEqual(off.attention, { total: 0, rows: [] });
    assert.equal(off.nextDue, null);
  }
});

test("only the owner can set the policy; everyone else is refused", { skip }, async () => {
  const call = (db: Db) =>
    db.rpc("set_inventory_count_policy", {
      _organization_id: ORG,
      _enabled: true,
      _interval_days: 30,
    });
  for (const db of [admin, staff, otherOwner, otherAdmin, stranger]) {
    const result = await call(db);
    assert.match(result.error?.message ?? "", /owner access required/);
    assert.equal(result.status, 403);
  }
  assert.match((await call(anon)).error?.message ?? "", /permission denied/);
  for (const [days, message] of [
    [0, /Count every 1 to 365 days/],
    [366, /Count every 1 to 365 days/],
    [-1, /Count every 1 to 365 days/],
  ] as const)
    await assert.rejects(
      setCountPolicy(owner, { organizationId: ORG, enabled: true, intervalDays: days }),
      message,
    );
  await assert.rejects(
    setCountPolicy(owner, { organizationId: ORG, enabled: true, intervalDays: null }),
    /Choose how many days between counts/,
  );
  assert.equal((await getCountPolicy(admin, ORG)).configured, false, "refusals wrote nothing");
});

test("reads: staff, other organizations, non-members and anon are refused", { skip }, async () => {
  const calls: Array<
    (db: Db) => PromiseLike<{ error: { message: string } | null; status: number }>
  > = [
    (db) => db.rpc("get_inventory_count_policy", { _organization_id: ORG }),
    (db) => db.rpc("get_inventory_count_freshness", { _organization_id: ORG }),
  ];
  for (const call of calls) {
    for (const db of [owner, admin]) assert.equal((await call(db)).error, null);
    for (const db of [staff, otherOwner, otherAdmin, stranger]) {
      const result = await call(db);
      assert.match(result.error?.message ?? "", /owner or admin access required/);
      assert.equal(result.status, 403);
    }
    assert.match((await call(anon)).error?.message ?? "", /permission denied/);
  }
  // No raw access to the policy table or the internal freshness helper for anyone.
  for (const db of [owner, admin, staff]) {
    assert.match(
      (await db.from("inventory_count_policies").select("*")).error?.message ?? "",
      /permission denied/,
    );
    assert.match(
      (
        await db.rpc(
          "inventory_location_count_freshness" as never,
          {
            _organization_id: ORG,
            _as_of: new Date().toISOString(),
          } as never,
        )
      ).error?.message ?? "",
      /permission denied/,
    );
  }
});

test(
  "cadence on (30 days): states at scale, owner = admin, most overdue first",
  { skip },
  async () => {
    const saved = await setCountPolicy(owner, {
      organizationId: ORG,
      enabled: true,
      intervalDays: 30,
    });
    assert.equal(saved.enabled, true);
    assert.equal(saved.intervalDays, 30);
    assert.equal(saved.updatedByName, "Integration Owner");
    const started = performance.now();
    const ownerView = await getCountFreshness(owner, { organizationId: ORG, limit: 50 });
    const elapsed = performance.now() - started;
    const adminView = await getCountFreshness(admin, { organizationId: ORG, limit: 50 });
    assert.deepEqual({ ...adminView, evaluatedAt: "" }, { ...ownerView, evaluatedAt: "" });
    assert.deepEqual(ownerView.policy, { enabled: true, intervalDays: 30 });
    assert.deepEqual(ownerView.summary, { ...expected, counted: 0 });
    assert.equal(ownerView.attention.total, expected.due + expected.overdue);
    assert.equal(ownerView.attention.rows.length, 50, "page of 50");
    const dueTimes = ownerView.attention.rows.map((row) => Date.parse(row.nextDueAt!));
    assert.deepEqual(
      dueTimes,
      [...dueTimes].sort((a, b) => a - b),
      "earliest due date (most overdue) first",
    );
    assert.ok(
      ownerView.attention.rows.every((row) => row.state === "overdue" || row.state === "due"),
    );
    assert.ok(ownerView.nextDue, "the soonest upcoming count is reported");
    assert.ok(elapsed < 3000, `freshness over 300 locations / 28,000 sessions took ${elapsed}ms`);
    // B is unaffected by A's policy.
    const other = await getCountFreshness(otherAdmin, { organizationId: OTHER_ORG });
    assert.equal(other.policy.enabled, false);
    assert.equal(other.summary.counted, 1);
  },
);

test(
  "one location: storage, Unassigned, archived and another organization's",
  { skip },
  async () => {
    const all = await listAllWorkspaceLocations(owner, ORG, "all");
    const byName = (name: string) => all.find((location) => location.name === name)!;
    const l001 = await getCountFreshness(admin, {
      organizationId: ORG,
      locationId: byName("L001").id,
    });
    assert.equal(l001.location?.state, "current");
    assert.equal(l001.location?.countableItemCount, 2);
    const l031 = await getCountFreshness(admin, {
      organizationId: ORG,
      locationId: byName("L031").id,
    });
    assert.equal(l031.location?.state, "due", "30 days 12 hours since the last count");
    const l060 = await getCountFreshness(admin, {
      organizationId: ORG,
      locationId: byName("L060").id,
    });
    assert.equal(l060.location?.state, "overdue");
    assert.equal(
      Date.parse(l060.location!.nextDueAt!) - Date.parse(l060.location!.lastCountedAt!),
      30 * 24 * 60 * 60 * 1000,
    );
    const never = await getCountFreshness(admin, {
      organizationId: ORG,
      locationId: byName("L300").id,
    });
    assert.deepEqual(
      { state: never.location?.state, nextDueAt: never.location?.nextDueAt },
      { state: "never_counted", nextDueAt: null },
    );
    for (const name of ["Unassigned", "Archived 1"]) {
      const view = await getCountFreshness(admin, {
        organizationId: ORG,
        locationId: byName(name).id,
      });
      assert.equal(view.location?.state, "not_applicable", name);
      assert.equal(view.location?.nextDueAt, null, name);
    }
    const empty = await getCountFreshness(admin, {
      organizationId: ORG,
      locationId: byName("Empty 1").id,
    });
    assert.equal(empty.location?.state, "nothing_to_count");
    const otherLocations = await listAllWorkspaceLocations(otherOwner, OTHER_ORG, "all");
    await assert.rejects(
      getCountFreshness(admin, { organizationId: ORG, locationId: otherLocations[1].id }),
      /Inventory location not found/,
    );
  },
);

test("a submitted count through the API makes its location current", { skip }, async () => {
  const all = await listAllWorkspaceLocations(owner, ORG, "all");
  const target = all.find((location) => location.name === "L060")!;
  const page = await staff.rpc("get_inventory_count_location", {
    _organization_id: ORG,
    _inventory_location_id: target.id,
  });
  assert.equal(page.error, null);
  const items = (
    page.data as { items: Array<{ inventoryItemId: string; version: number; quantity: string }> }
  ).items;
  const saved = await staff.rpc("submit_inventory_count", {
    _organization_id: ORG,
    _inventory_location_id: target.id,
    _idempotency_key: "p7b5-itest-count",
    _lines: items.map((item) => ({
      inventoryItemId: item.inventoryItemId,
      observedVersion: item.version,
      countedQuantity: item.quantity,
    })),
  });
  assert.equal(saved.error, null);
  const after = await getCountFreshness(owner, { organizationId: ORG, locationId: target.id });
  assert.equal(after.location?.state, "current");
  assert.equal(after.summary.overdue, expected.overdue - 1);
});

test("turning cadence off keeps the interval and removes every due state", { skip }, async () => {
  const off = await setCountPolicy(owner, {
    organizationId: ORG,
    enabled: false,
    intervalDays: null,
  });
  assert.deepEqual(
    { enabled: off.enabled, intervalDays: off.intervalDays },
    { enabled: false, intervalDays: 30 },
  );
  const view = await getCountFreshness(admin, { organizationId: ORG });
  assert.deepEqual(view.policy, { enabled: false, intervalDays: null });
  assert.equal(view.summary.due + view.summary.overdue + view.summary.current, 0);
  assert.equal(view.attention.total, 0);
});

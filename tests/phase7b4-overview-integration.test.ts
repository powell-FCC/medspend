// Phase 7B.4 API integration: the owner+admin Inventory Overview through a real PostgREST with
// signed user JWTs, via the same read helper the server function uses
// (src/inventory/workspace-reads.ts). PostgREST runs with the hosted default row cap (1000)
// and the fixture holds more Unassigned items and more storage locations than that. Started
// by supabase/tests/run_phase7b4_overview_integration.sh; skipped by a plain `npm test`.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import {
  OVERVIEW_ATTENTION_LIMIT,
  getInventoryOverview,
  listAdjustmentHistoryPage,
  listCountHistoryPage,
  listTransferHistoryPage,
} from "../src/inventory/workspace-reads.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
// This suite reads a fixture database. It only ever runs against a loopback address.
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7b4_overview_integration.sh";

const id = (suffix: string) => `7b4c0000-0000-4000-8000-000000000${suffix}`;
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

test("the API row cap is active: raw location reads are truncated", { skip }, async () => {
  const raw = await owner
    .from("inventory_locations")
    .select("id", { count: "exact" })
    .eq("organization_id", ORG);
  assert.equal(raw.error, null);
  assert.equal(raw.data!.length, 1000);
  assert.equal(raw.count, 1100 + 20 + 1);
});

test("owner and admin read the same overview, with totals past the row cap", { skip }, async () => {
  const ownerView = await getInventoryOverview(owner, ORG);
  const adminView = await getInventoryOverview(admin, ORG);
  assert.deepEqual(adminView, ownerView);
  const { snapshot, attention } = ownerView;
  assert.deepEqual(
    { ...snapshot, unassignedLocationId: typeof snapshot.unassignedLocationId },
    {
      activeItemCount: 1203,
      itemsInStockCount: 1203,
      recordedQuantity: 2406,
      stockedUnitCount: 2,
      activeStorageLocationCount: 1100,
      archivedStorageLocationCount: 20,
      unassignedLocationId: "string",
      unassignedItemCount: 1200,
      unassignedQuantity: 2400,
    },
  );
  assert.equal(attention.unassignedStock.total, 1200);
  assert.equal(attention.unassignedStock.rows.length, OVERVIEW_ATTENTION_LIMIT);
  assert.equal(
    attention.unassignedStock.rows[0].name,
    "Itest Item 0004",
    "by name, placed items excluded",
  );
  assert.deepEqual(
    attention.neverCountedLocations.rows.map((row) => [row.name, row.countableItemCount]),
    [["Itest Bay 0002", 2]],
  );
  assert.deepEqual(
    attention.neverCountedItems.rows.map((row) => [row.name, row.locationCount]),
    [
      ["Itest Item 0002", 1],
      ["Itest Item 0003", 1],
    ],
  );
  assert.equal(attention.noActiveLabel.total, 1050);
  assert.equal(attention.noActiveLabel.rows[0].name, "Itest Bay 0051");
  assert.equal(attention.archivedWithActiveLabel.total, 20);
  assert.ok(attention.archivedWithActiveLabel.rows.every((row) => row.activeLabelCount === 1));
});

test("staff, other organizations, non-members and anon are refused", { skip }, async () => {
  const call = (db: SupabaseClient<Database>) =>
    db.rpc("get_inventory_overview", { _organization_id: ORG });
  for (const db of [owner, admin]) assert.equal((await call(db)).error, null);
  for (const db of [staff, otherOwner, otherAdmin, stranger]) {
    const result = await call(db);
    assert.match(result.error?.message ?? "", /owner or admin access required/);
    assert.equal(result.status, 403);
  }
  assert.match((await call(anon)).error?.message ?? "", /permission denied/);
});

test("organizations are isolated", { skip }, async () => {
  const other = await getInventoryOverview(otherAdmin, OTHER_ORG);
  assert.equal(other.snapshot.activeItemCount, 1);
  assert.equal(other.snapshot.activeStorageLocationCount, 0);
  assert.deepEqual(
    other.attention.unassignedStock.rows.map((row) => row.name),
    ["Itest Other Item"],
  );
  assert.equal(other.attention.noActiveLabel.total, 0);
});

test("recent activity reads return at most five, newest first", { skip }, async () => {
  const base = {
    organizationId: ORG,
    locationId: null,
    itemId: null,
    createdBy: null,
    createdFrom: null,
    createdBefore: null,
    cursor: null,
    limit: 5,
  };
  const transfers = await listTransferHistoryPage(admin, base);
  assert.equal(transfers.rows.length, 3);
  const adjustments = await listAdjustmentHistoryPage(admin, { ...base, reason: null });
  assert.equal(
    adjustments.rows.length,
    0,
    "the count's physical_count row is not a manual adjustment",
  );
  const counts = await listCountHistoryPage(admin, {
    organizationId: ORG,
    locationId: null,
    countedBy: null,
    changedOnly: false,
    submittedFrom: null,
    submittedBefore: null,
    cursor: null,
    limit: 5,
  });
  assert.deepEqual(
    counts.rows.map((row) => row.locationName),
    ["Itest Bay 0001"],
  );
});

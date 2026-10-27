// Phase 7A.2 API integration: QR labels, counts and the staff read hardening through a real
// PostgREST with signed user JWTs, exactly as the application calls them. Started by
// supabase/tests/run_phase7a2_count_integration.sh; skipped by a plain `npm test`, which has
// no local stack.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7a2_count_integration.sh";

const id = (suffix: string) => `7a1b0000-0000-4000-8000-000000000${suffix}`;
const ORG = id("101");
const OTHER_ORG = id("102");

const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
function signToken(claims: Record<string, unknown>) {
  const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ ...claims, exp: Math.floor(Date.now() / 1000) + 3600 })}`;
  return `${body}.${createHmac("sha256", JWT_SECRET).update(body).digest("base64url")}`;
}
function clientFor(claims: Record<string, unknown>) {
  return createClient(REST_URL, "local-publishable-key", {
    global: {
      headers: { Authorization: `Bearer ${signToken(claims)}` },
      fetch: (input, init) => fetch(String(input).replace("/rest/v1", ""), init),
    },
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });
}
const user = (suffix: string) => clientFor({ role: "authenticated", sub: id(suffix) });
const owner = configured ? user("001") : (null as never);
const otherOwner = configured ? user("002") : (null as never);
const staff = configured ? user("003") : (null as never);
const admin = configured ? user("004") : (null as never);
const stranger = configured
  ? clientFor({ role: "authenticated", sub: "7a1b0000-0000-4000-8000-000000000999" })
  : (null as never);
const anon = configured ? clientFor({ role: "anon" }) : (null as never);

let locationId = "";
let token = "";
type Page = {
  location: { name: string };
  items: Array<{ inventoryItemId: string; quantity: string; version: number }>;
};
const confirm = (page: Page, overrides: Record<string, string> = {}) =>
  page.items.map((item) => ({
    inventoryItemId: item.inventoryItemId,
    observedVersion: item.version,
    countedQuantity: overrides[item.inventoryItemId] ?? item.quantity,
  }));

test("staff can no longer read inventory rows or prices directly", { skip }, async () => {
  const direct = await staff
    .from("inventory_items")
    .select("id,last_purchase_price,vendor_name")
    .eq("organization_id", ORG);
  assert.equal(direct.error, null);
  assert.deepEqual(direct.data, []);
  const owners = await owner.from("inventory_items").select("id").eq("organization_id", ORG);
  assert.ok(owners.data!.length >= 5, "owners still read inventory");
  const admins = await admin
    .from("inventory_items")
    .select("id")
    .eq("organization_id", ORG)
    .eq("active", true);
  assert.ok(admins.data!.length >= 4, "admins still read active inventory");
  const ids = owners.data!.map((row) => row.id);
  const identities = await staff.rpc("get_supply_request_inventory_identities", {
    _organization_id: ORG,
    _inventory_item_ids: ids,
  });
  assert.equal(identities.error, null);
  assert.ok(identities.data!.length >= 4);
  for (const row of identities.data!) {
    assert.deepEqual(Object.keys(row).sort(), [
      "active",
      "id",
      "manufacturer",
      "name",
      "sku",
      "unit",
      "vendor_name",
    ]);
    assert.equal(row.active, true, "staff see active items only");
  }
  const foreign = await otherOwner.rpc("get_supply_request_inventory_identities", {
    _organization_id: ORG,
    _inventory_item_ids: ids,
  });
  assert.match(foreign.error?.message ?? "", /organization membership required/);
});

test("staff request search still works after the hardening", { skip }, async () => {
  const { data, error } = await staff.rpc("search_supply_request_products", {
    _organization_id: ORG,
    _query: "tape",
    _limit: 10,
  });
  assert.equal(error, null);
  assert.ok(Array.isArray(data));
});

test(
  "owners issue labels; nobody else can, and nobody reads labels directly",
  { skip },
  async () => {
    const created = await owner.rpc("create_inventory_location", {
      _organization_id: ORG,
      _name: "Integration Cabinet",
    });
    assert.equal(created.error, null);
    locationId = created.data as string;
    for (const client of [staff, admin, otherOwner]) {
      const refused = await client.rpc("issue_inventory_location_label", {
        _organization_id: ORG,
        _inventory_location_id: locationId,
      });
      assert.match(refused.error?.message ?? "", /owner access required/);
    }
    const anonIssue = await anon.rpc("issue_inventory_location_label", {
      _organization_id: ORG,
      _inventory_location_id: locationId,
    });
    assert.ok(anonIssue.error, "anon cannot issue");
    const issued = await owner.rpc("issue_inventory_location_label", {
      _organization_id: ORG,
      _inventory_location_id: locationId,
    });
    assert.equal(issued.error, null);
    token = (issued.data as { token: string }).token;
    assert.match(token, /^[A-Za-z0-9_-]{43}$/);
    for (const client of [owner, staff]) {
      const direct = await client.from("inventory_location_labels").select("*");
      assert.ok(direct.error, "labels are not readable through the API");
    }
  },
);

test("a token alone authorizes nothing: only members resolve it", { skip }, async () => {
  const resolved = await staff.rpc("resolve_inventory_count_label", { _token: token });
  assert.equal(resolved.error, null);
  assert.deepEqual(resolved.data, {
    status: "available",
    organizationId: ORG,
    locationId,
    locationName: "Integration Cabinet",
  });
  for (const client of [otherOwner, stranger]) {
    const outsider = await client.rpc("resolve_inventory_count_label", { _token: token });
    assert.deepEqual(outsider.data, { status: "unavailable" }, "no tenant details for outsiders");
  }
  const anonResolve = await anon.rpc("resolve_inventory_count_label", { _token: token });
  assert.ok(anonResolve.error, "anon cannot resolve");
  const outsiderPage = await otherOwner.rpc("get_inventory_count_location", {
    _organization_id: ORG,
    _inventory_location_id: locationId,
  });
  assert.match(outsiderPage.error?.message ?? "", /organization membership required/);
});

test(
  "staff count a location through the API: atomic, idempotent, stale-safe",
  { skip },
  async () => {
    const tape = (
      await owner.from("inventory_items").select("id,quantity").eq("product_id", id("401")).single()
    ).data!;
    const unassigned = (
      await owner
        .from("inventory_locations")
        .select("id")
        .eq("organization_id", ORG)
        .eq("kind", "unassigned")
        .single()
    ).data!;
    const move = await owner.rpc("move_inventory_stock", {
      _organization_id: ORG,
      _inventory_item_id: tape.id,
      _from_inventory_location_id: unassigned.id,
      _to_inventory_location_id: locationId,
      _quantity: 4.5,
      _idempotency_key: "integration-move",
    });
    assert.equal(move.error, null);

    const loaded = await staff.rpc("get_inventory_count_location", {
      _organization_id: ORG,
      _inventory_location_id: locationId,
    });
    assert.equal(loaded.error, null);
    const page = loaded.data as unknown as Page;
    assert.deepEqual(
      page.items.map((item) => [item.inventoryItemId, item.quantity]),
      [[tape.id, "4.5"]],
    );
    assert.doesNotMatch(JSON.stringify(page), /price|vendor/i);

    const lines = confirm(page, { [tape.id]: "4.25" });
    const saved = await staff.rpc("submit_inventory_count", {
      _organization_id: ORG,
      _inventory_location_id: locationId,
      _lines: lines,
      _idempotency_key: "integration-count-1",
    });
    assert.equal(saved.error, null);
    const summary = saved.data as {
      lineCount: number;
      changedCount: number;
      replayed: boolean;
      sessionId: string;
    };
    assert.deepEqual([summary.lineCount, summary.changedCount, summary.replayed], [1, 1, false]);

    const replay = await staff.rpc("submit_inventory_count", {
      _organization_id: ORG,
      _inventory_location_id: locationId,
      _lines: confirm(page, { [tape.id]: "4.250" }),
      _idempotency_key: "integration-count-1",
    });
    assert.equal((replay.data as { replayed: boolean; sessionId: string }).replayed, true);
    assert.equal((replay.data as { sessionId: string }).sessionId, summary.sessionId);
    const reused = await staff.rpc("submit_inventory_count", {
      _organization_id: ORG,
      _inventory_location_id: locationId,
      _lines: confirm(page, { [tape.id]: "1" }),
      _idempotency_key: "integration-count-1",
    });
    assert.match(reused.error?.message ?? "", /already used for a different count/);
    const stale = await staff.rpc("submit_inventory_count", {
      _organization_id: ORG,
      _inventory_location_id: locationId,
      _lines: lines,
      _idempotency_key: "integration-count-2",
    });
    assert.match(stale.error?.message ?? "", /Inventory changed while you were counting/);

    const total = (
      await owner.from("inventory_items").select("quantity").eq("id", tape.id).single()
    ).data!;
    assert.equal(
      Number(total.quantity),
      Number(tape.quantity) - 0.25,
      "organization total moved by the delta only",
    );
    const history = await owner
      .from("inventory_adjustments")
      .select("adjustment_amount,source_type,reason")
      .eq("inventory_item_id", tape.id)
      .eq("source_type", "physical_count");
    assert.deepEqual(history.data, [
      { adjustment_amount: -0.25, source_type: "physical_count", reason: "Physical count" },
    ]);
  },
);

test(
  "count history is owner-readable only and never writable through the API",
  { skip },
  async () => {
    const staffSessions = await staff.from("inventory_count_sessions").select("id");
    assert.deepEqual(staffSessions.data, []);
    const ownerSessions = await owner
      .from("inventory_count_sessions")
      .select("id,counted_by,line_count");
    assert.equal(ownerSessions.data!.length, 1);
    assert.equal(ownerSessions.data![0].counted_by, id("003"));
    const insert = await owner.from("inventory_count_sessions").insert({
      organization_id: ORG,
      inventory_location_id: locationId,
      counted_by: id("001"),
      submitted_at: new Date().toISOString(),
      line_count: 1,
      changed_count: 0,
      idempotency_key: "direct",
      request_hash: "0".repeat(64),
    });
    assert.ok(insert.error, "no direct writes");
    const ledger = await owner.from("inventory_adjustments").insert({
      organization_id: ORG,
      inventory_item_id: id("501"),
      adjustment_amount: 0,
      previous_quantity: 0,
      new_quantity: 0,
      reason: "Physical count",
      created_by: id("001"),
      source_type: "physical_count",
    });
    assert.ok(ledger.error, "no hand-written checkpoints");
  },
);

test("revoked labels stop resolving; members are told it was replaced", { skip }, async () => {
  const revoked = await owner.rpc("revoke_inventory_location_labels", {
    _organization_id: ORG,
    _inventory_location_id: locationId,
  });
  assert.equal(revoked.data, 1);
  const member = await staff.rpc("resolve_inventory_count_label", { _token: token });
  assert.deepEqual(member.data, { status: "replaced" });
  const outsider = await otherOwner.rpc("resolve_inventory_count_label", { _token: token });
  assert.deepEqual(outsider.data, { status: "unavailable" });
  const fresh = await owner.rpc("issue_inventory_location_label", {
    _organization_id: ORG,
    _inventory_location_id: locationId,
  });
  const again = await staff.rpc("resolve_inventory_count_label", {
    _token: (fresh.data as { token: string }).token,
  });
  assert.equal((again.data as { status: string }).status, "available");
  const status = await owner.rpc("list_inventory_location_count_status", { _organization_id: ORG });
  const row = status.data!.find((entry) => entry.inventory_location_id === locationId)!;
  assert.equal(row.active_label_count, 1);
  assert.ok(row.last_counted_at);
  const staffStatus = await staff.rpc("list_inventory_location_count_status", {
    _organization_id: ORG,
  });
  assert.match(staffStatus.error?.message ?? "", /owner access required/);
});

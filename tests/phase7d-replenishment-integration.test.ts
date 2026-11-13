// Phase 7D API integration: replenishment reads and owner rule writes through a real PostgREST
// with signed user JWTs, via the same helpers the server functions use
// (src/inventory/replenishment-reads.ts). The fixture is the agreed large shape: 2,000 items,
// 20 storage locations, 40,000 rules and 200,000 count lines. Started by
// supabase/tests/run_phase7d_replenishment_integration.sh; skipped by a plain `npm test`.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import {
  getReplenishmentSummary,
  listLocationReplenishmentRules,
  listReplenishmentPage,
  setReplenishmentRule,
  setReplenishmentRuleEnabled,
} from "../src/inventory/replenishment-reads.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
// This suite writes data. It only ever runs against a loopback address.
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7d_replenishment_integration.sh";

const id = (suffix: string) => `7d1c0000-0000-4000-8000-000000000${suffix}`;
const item = (n: number) => `7d1c0000-0000-4000-9000-${String(n).padStart(12, "0")}`;
const loc = (n: number) => `7d1c0000-0000-4000-a000-${String(n).padStart(12, "0")}`;
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
const stranger = user("009");
const anon = configured ? clientFor({ role: "anon" }) : (null as never);

async function timed<T>(work: () => Promise<T>): Promise<[T, number]> {
  const start = performance.now();
  const value = await work();
  return [value, performance.now() - start];
}

test(
  "summary and attention at 40,000 rules: owner and admin, paged, within budget",
  { skip },
  async () => {
    const [summary, summaryMs] = await timed(() => getReplenishmentSummary(admin, ORG));
    assert.equal(summary.rules.total, 40000);
    assert.equal(summary.rules.active, 40000);
    const c = summary.categories;
    assert.equal(c.moveAvailable + c.partlyCovered + c.needsPurchasing + c.ok + c.inactive, 40000);
    assert.ok(c.moveAvailable > 0 && c.partlyCovered > 0 && c.needsPurchasing > 0 && c.ok > 0);
    assert.deepEqual(summary.items, { active: 2000, withRule: 2000, withoutRule: 0 });
    assert.deepEqual(summary.locations, { activeStorage: 20, withRule: 20, withoutRule: 0 });
    assert.deepEqual(
      await getReplenishmentSummary(owner, ORG),
      summary,
      "owner and admin see the same",
    );

    const [first, firstMs] = await timed(() =>
      listReplenishmentPage(admin, { organizationId: ORG, view: "attention", limit: 100 }),
    );
    assert.equal(first.rows.length, 100);
    assert.ok(first.nextCursor);
    const second = await listReplenishmentPage(admin, {
      organizationId: ORG,
      view: "attention",
      limit: 100,
      cursor: first.nextCursor,
    });
    const both = [...first.rows, ...second.rows];
    const once = await listReplenishmentPage(admin, {
      organizationId: ORG,
      view: "attention",
      limit: 200,
    });
    assert.deepEqual(
      both.map((row) => row.ruleId),
      once.rows.map((row) => row.ruleId),
      "keyset paging gives the same rows as one larger page",
    );
    for (const row of both) {
      assert.ok(["move_available", "partly_covered", "needs_purchasing"].includes(row.category));
      assert.ok(row.shortageQuantity > 0);
      assert.equal(
        Number((row.moveQuantity + row.externalQuantity).toFixed(6)),
        row.shortageQuantity,
        "move + external = shortage",
      );
      assert.ok(row.lastCountedAt, "every location was counted");
      assert.equal(row.locationCountState, "counted");
      assert.match(row.updatedAt, /\.\d{6}|:\d{2}[+Z]/, "versions arrive as full timestamps");
    }
    console.log(`summary ${summaryMs.toFixed(0)} ms, attention page ${firstMs.toFixed(0)} ms`);
    assert.ok(summaryMs < 5000 && firstMs < 5000, "reads stay within budget at 40,000 rules");
  },
);

test(
  "location rules: all 2,000 rules at one location, paged under the API row cap",
  { skip },
  async () => {
    const [rules, ms] = await timed(() => listLocationReplenishmentRules(admin, ORG, loc(1)));
    assert.equal(rules.length, 2000);
    assert.equal(new Set(rules.map((rule) => rule.ruleId)).size, 2000);
    assert.ok(rules.every((rule) => rule.inventoryLocationId === loc(1)));
    const names = rules.map((rule) => rule.itemName);
    assert.deepEqual(
      names,
      [...names].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase())),
    );
    console.log(`location rules (4 pages) ${ms.toFixed(0)} ms`);
  },
);

test(
  "open-request note: inventory-backed ordered requests only, never subtracted",
  { skip },
  async () => {
    const rules = await listLocationReplenishmentRules(admin, ORG, loc(1));
    const one = rules.find((rule) => rule.inventoryItemId === item(1));
    const two = rules.find((rule) => rule.inventoryItemId === item(2));
    const three = rules.find((rule) => rule.inventoryItemId === item(3));
    assert.equal(one?.openRequestCount, 1);
    assert.equal(one?.openOrderedRequestCount, 1);
    assert.equal(two?.openRequestCount, 1);
    assert.equal(three?.openRequestCount, 0, "the free-text request is not counted");
    // Item 1 at L01: current (1 * 1) % 13 = 1, Minimum (1 + 1) % 5 = 2, Target 7: shortage 6
    // whatever is on order.
    assert.equal(one?.currentQuantity, 1);
    assert.equal(one?.shortageQuantity, 6);
  },
);

test(
  "roles: staff, strangers, other organizations and anon are refused; admins cannot write",
  { skip },
  async () => {
    for (const [label, db] of [
      ["staff", staff],
      ["stranger", stranger],
      ["other owner", otherOwner],
    ] as const) {
      await assert.rejects(
        getReplenishmentSummary(db, ORG),
        /owner or admin access required/,
        label,
      );
      await assert.rejects(
        listReplenishmentPage(db, { organizationId: ORG, view: "attention" }),
        /owner or admin access required/,
        label,
      );
      await assert.rejects(
        listLocationReplenishmentRules(db, ORG, loc(1)),
        /owner or admin access required/,
        label,
      );
    }
    await assert.rejects(getReplenishmentSummary(anon, ORG), /permission denied/);
    const rules = await listLocationReplenishmentRules(owner, ORG, loc(2));
    const rule = rules[0];
    await assert.rejects(
      setReplenishmentRule(admin, {
        organizationId: ORG,
        inventoryItemId: rule.inventoryItemId,
        locationId: loc(2),
        minimumQuantity: 1,
        targetQuantity: 2,
        expectedUpdatedAt: rule.updatedAt,
      }),
      /owner access required/,
    );
    await assert.rejects(
      setReplenishmentRuleEnabled(admin, {
        organizationId: ORG,
        ruleId: rule.ruleId,
        enabled: false,
        expectedUpdatedAt: rule.updatedAt,
      }),
      /owner access required/,
    );
    // Raw tables and the internal calculation stay closed, even to owners.
    const raw = await owner
      .from("inventory_replenishment_rules" as never)
      .select("*")
      .limit(1);
    assert.match(raw.error?.message ?? "", /permission denied/);
    const internal = await owner.rpc(
      "inventory_replenishment_rows" as never,
      { _organization_id: ORG } as never,
    );
    assert.ok(internal.error, "the internal calculation is not callable");
    // The neighbour's own rule is visible only to them.
    assert.equal((await getReplenishmentSummary(otherOwner, OTHER_ORG)).rules.total, 1);
  },
);

test(
  "owner writes through the API: duplicate refused, edit with the listed version, stale refused",
  { skip },
  async () => {
    const before = (await listLocationReplenishmentRules(owner, ORG, loc(3))).find(
      (rule) => rule.inventoryItemId === item(10),
    )!;
    await assert.rejects(
      setReplenishmentRule(owner, {
        organizationId: ORG,
        inventoryItemId: item(10),
        locationId: loc(3),
        minimumQuantity: 1,
        targetQuantity: 2,
        expectedUpdatedAt: null,
      }),
      /Item 0010 already has a replenishment rule at L03\. Reload to edit it\./,
    );
    // The version string from the list goes back exactly (microseconds survive the round trip).
    const edited = await setReplenishmentRule(owner, {
      organizationId: ORG,
      inventoryItemId: item(10),
      locationId: loc(3),
      minimumQuantity: 2.5,
      targetQuantity: 7.25,
      expectedUpdatedAt: before.updatedAt,
    });
    assert.equal(edited.minimumQuantity, 2.5);
    assert.equal(edited.targetQuantity, 7.25);
    const started = performance.now();
    await assert.rejects(
      setReplenishmentRule(owner, {
        organizationId: ORG,
        inventoryItemId: item(10),
        locationId: loc(3),
        minimumQuantity: 1,
        targetQuantity: 2,
        expectedUpdatedAt: before.updatedAt,
      }),
      /This replenishment rule changed since you opened it\. Reload and try again\./,
    );
    assert.ok(
      performance.now() - started < 5000,
      "a stale edit answers at once (never a retried 40001)",
    );
    const off = await setReplenishmentRuleEnabled(owner, {
      organizationId: ORG,
      ruleId: before.ruleId,
      enabled: false,
      expectedUpdatedAt: edited.updatedAt,
    });
    assert.equal(off.enabled, false);
    const inactive = await listReplenishmentPage(admin, { organizationId: ORG, view: "inactive" });
    assert.deepEqual(
      inactive.rows.map((row) => [row.ruleId, row.inactiveReason]),
      [[before.ruleId, "disabled"]],
    );
    const on = await setReplenishmentRuleEnabled(owner, {
      organizationId: ORG,
      ruleId: before.ruleId,
      enabled: true,
      expectedUpdatedAt: off.updatedAt,
    });
    assert.equal(on.enabled, true);
  },
);

test(
  "Move Stock source marker through the API: old callers manual, replenishment when asked",
  { skip },
  async () => {
    const unassigned = await owner
      .from("inventory_locations")
      .select("id")
      .eq("organization_id", ORG)
      .eq("kind", "unassigned")
      .single();
    const from = unassigned.data!.id;
    // Item 6: Unassigned 6 % 7 = 6.
    const oldCall = await owner.rpc("move_inventory_stock", {
      _organization_id: ORG,
      _inventory_item_id: item(6),
      _from_inventory_location_id: from,
      _to_inventory_location_id: loc(1),
      _quantity: 1,
      _idempotency_key: "itest-old-app",
    });
    assert.equal(oldCall.error, null);
    const recommended = await owner.rpc("move_inventory_stock", {
      _organization_id: ORG,
      _inventory_item_id: item(6),
      _from_inventory_location_id: from,
      _to_inventory_location_id: loc(1),
      _quantity: 2,
      _idempotency_key: "itest-replenishment",
      _source: "replenishment",
    });
    assert.equal(recommended.error, null);
    const replay = await owner.rpc("move_inventory_stock", {
      _organization_id: ORG,
      _inventory_item_id: item(6),
      _from_inventory_location_id: from,
      _to_inventory_location_id: loc(1),
      _quantity: 2,
      _idempotency_key: "itest-replenishment",
    });
    assert.equal((replay.data as { replayed: boolean }).replayed, true);
    const unknown = await owner.rpc("move_inventory_stock", {
      _organization_id: ORG,
      _inventory_item_id: item(6),
      _from_inventory_location_id: from,
      _to_inventory_location_id: loc(1),
      _quantity: 1,
      _idempotency_key: "itest-unknown",
      _source: "automatic",
    });
    assert.match(unknown.error?.message ?? "", /Unknown move source/);
    const adminMove = await admin.rpc("move_inventory_stock", {
      _organization_id: ORG,
      _inventory_item_id: item(6),
      _from_inventory_location_id: from,
      _to_inventory_location_id: loc(1),
      _quantity: 1,
      _idempotency_key: "itest-admin",
      _source: "replenishment",
    });
    assert.match(adminMove.error?.message ?? "", /owner access required/);
    const transfers = await owner
      .from("inventory_transfers")
      .select("idempotency_key, source")
      .eq("organization_id", ORG)
      .like("idempotency_key", "itest-%")
      .order("idempotency_key");
    assert.deepEqual(transfers.data, [
      { idempotency_key: "itest-old-app", source: "manual" },
      { idempotency_key: "itest-replenishment", source: "replenishment" },
    ]);
  },
);

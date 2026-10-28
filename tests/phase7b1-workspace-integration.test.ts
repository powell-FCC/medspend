// Phase 7B.1 API integration: the owner+admin Inventory workspace reads and atomic Replace
// labels through a real PostgREST with signed user JWTs, plus the server-function layer's
// read helpers and owner check (src/inventory/workspace-reads.ts, owner-access.ts) built
// the way requireSupabaseAuth builds its client. PostgREST runs with the hosted default
// row cap (1000) and the fixture is larger than it. Started by
// supabase/tests/run_phase7b1_workspace_integration.sh; skipped by a plain `npm test`.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import { assertInventoryOwner } from "../src/inventory/owner-access.ts";
import {
  getWorkspaceItemBalances,
  getWorkspaceLocation,
  listAllWorkspaceLocations,
  listWorkspaceItemsPage,
  listWorkspaceLocationStockPage,
  replaceLocationLabels,
} from "../src/inventory/workspace-reads.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
// This suite writes data. It only ever runs against a loopback address.
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7b1_workspace_integration.sh";

const id = (suffix: string) => `7b1c0000-0000-4000-8000-000000000${suffix}`;
const ORG = id("101");
const OTHER_ORG = id("102");
const ITEMS = 1100;

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
async function locationNamed(db: Db, name: string) {
  const all = await listAllWorkspaceLocations(db, ORG, "all");
  const found = all.find((location) => location.name === name);
  assert.ok(found, name);
  return found;
}
async function allStock(db: Db, locationId: string, limit = 500) {
  const rows = [];
  let cursor: { name: string; id: string } | null = null;
  for (let pages = 0; pages < 20; pages++) {
    const page = await listWorkspaceLocationStockPage(db, {
      organizationId: ORG,
      locationId,
      cursor,
      limit,
    });
    rows.push(...page.rows);
    if (!page.nextCursor) return rows;
    cursor = page.nextCursor;
  }
  throw new Error("stock paging did not finish");
}
async function allItems(db: Db, filters: { lowStock?: boolean; search?: string } = {}) {
  const rows = [];
  let cursor: { name: string; id: string } | null = null;
  for (let pages = 0; pages < 20; pages++) {
    const page = await listWorkspaceItemsPage(db, {
      organizationId: ORG,
      search: filters.search ?? "",
      category: "",
      status: "all",
      lowStock: filters.lowStock ?? false,
      cursor,
      limit: 500,
    });
    rows.push(...page.rows);
    if (!page.nextCursor) return rows;
    cursor = page.nextCursor;
  }
  throw new Error("item paging did not finish");
}

// ---------------------------------------------------------------------------------------
// Row cap: the API really truncates, and the workspace reads never depend on it.
// ---------------------------------------------------------------------------------------
test("the API row cap is active: a raw balance read stops at 1000 rows", { skip }, async () => {
  const raw = await owner
    .from("inventory_location_balances")
    .select("inventory_item_id", { count: "exact" })
    .eq("organization_id", ORG);
  assert.equal(raw.error, null);
  assert.equal(raw.data!.length, 1000, "PostgREST returned only the capped page");
  assert.equal(raw.count, 2234, "the organization really has more balance rows");
});

test(
  "locations: complete summaries for 210 locations, from counts done in the database",
  { skip },
  async () => {
    for (const db of [owner, admin]) {
      const all = await listAllWorkspaceLocations(db, ORG, "all");
      assert.equal(all.length, 210, "every location, across more than one 200-row page");
      assert.equal(new Set(all.map((location) => location.id)).size, 210, "no duplicates");
      assert.equal(all[0].kind, "unassigned", "Unassigned first");
      assert.equal(all[0].name, "Unassigned");
      assert.equal(all[0].countableItemCount, null);
      assert.equal(all[0].activeLabelCount, null);
      assert.equal(all[0].stockedItemCount, 734);
      assert.equal(all[all.length - 1].name, "Retired Closet", "archived last");
      const bulk = all.find((location) => location.name === "Bulk Cabinet")!;
      assert.equal(bulk.stockedItemCount, ITEMS, "more than the row cap, counted in full");
      assert.equal(bulk.countableItemCount, ITEMS);
      const side = all.find((location) => location.name === "Side Cart")!;
      assert.equal(side.stockedItemCount, 34);
      assert.equal((await listAllWorkspaceLocations(db, ORG, "active")).length, 209);
      assert.deepEqual(
        (await listAllWorkspaceLocations(db, ORG, "archived")).map((location) => location.name),
        ["Retired Closet"],
      );
    }
    assert.deepEqual(
      await listAllWorkspaceLocations(admin, ORG, "all"),
      await listAllWorkspaceLocations(owner, ORG, "all"),
      "owners and admins receive the same contract",
    );
  },
);

test(
  "location stock pages past the row cap and retrieves every row exactly once",
  { skip },
  async () => {
    const bulk = await locationNamed(admin, "Bulk Cabinet");
    const rows = await allStock(admin, bulk.id);
    assert.equal(rows.length, ITEMS);
    assert.equal(new Set(rows.map((row) => row.inventoryItemId)).size, ITEMS);
    const names = rows.map((row) => row.name);
    assert.deepEqual(names, [...names].sort(), "stable name order across pages");
    const total = rows.reduce((sum, row) => sum + row.quantity, 0);
    assert.equal(total, 366 * 10 + (ITEMS - 366) * 4);
    // Small pages walk the same rows in the same order.
    const small = await allStock(admin, bulk.id, 250);
    assert.deepEqual(
      small.map((row) => row.inventoryItemId),
      rows.map((row) => row.inventoryItemId),
    );
    const ownerRows = await allStock(owner, bulk.id);
    assert.deepEqual(ownerRows, rows, "owner and admin see the same stock");
    const single = await admin.rpc("list_inventory_workspace_location_stock", {
      _organization_id: ORG,
      _inventory_location_id: bulk.id,
      _limit: 500,
    });
    assert.equal(single.data!.length, 500, "one call returns one page, never more than asked");
  },
);

test(
  "items page past the row cap with correct summaries and server-side filters",
  { skip },
  async () => {
    const rows = await allItems(admin);
    assert.equal(rows.length, ITEMS);
    assert.equal(new Set(rows.map((row) => row.id)).size, ITEMS);
    const byName = new Map(rows.map((row) => [row.name, row]));
    // Item 0001: 4 in the bulk cabinet, 1 in the side cart, 5 left in Unassigned.
    assert.deepEqual(
      (({
        quantity,
        unassignedQuantity,
        physicalQuantity,
        physicalLocationCount,
        singlePhysicalLocationName,
      }) => ({
        quantity,
        unassignedQuantity,
        physicalQuantity,
        physicalLocationCount,
        singlePhysicalLocationName,
      }))(byName.get("Item 0001")!),
      {
        quantity: 10,
        unassignedQuantity: 5,
        physicalQuantity: 5,
        physicalLocationCount: 2,
        singlePhysicalLocationName: null,
      },
    );
    // Item 0003: everything in the bulk cabinet.
    const three = byName.get("Item 0003")!;
    assert.equal(three.unassignedQuantity, 0);
    assert.equal(three.physicalLocationCount, 1);
    assert.equal(three.singlePhysicalLocationName, "Bulk Cabinet");
    // Item 0100: bulk cabinet plus Unassigned.
    assert.equal(byName.get("Item 0100")!.unassignedQuantity, 6);
    assert.equal(byName.get("Item 0100")!.singlePhysicalLocationName, "Bulk Cabinet");
    for (const row of rows) {
      assert.equal(row.unassignedQuantity + row.physicalQuantity, row.quantity, row.name);
    }
    const low = await allItems(admin, { lowStock: true });
    assert.equal(low.length, Math.floor(ITEMS / 7), "organization-level par filter, server-side");
    assert.ok(low.every((row) => row.stockStatus === "critical"));
    const search = await allItems(admin, { search: "sku-110" });
    assert.deepEqual(
      search.map((row) => row.name),
      ["Item 0110", "Item 1100"],
    );
    assert.deepEqual(await allItems(owner), rows, "owner and admin see the same items");
  },
);

test("item balances for the move and adjust dialogs are complete", { skip }, async () => {
  const items = await allItems(admin, { search: "SKU-1" });
  const one = items.find((row) => row.name === "Item 0001")!;
  for (const db of [owner, admin]) {
    const balances = await getWorkspaceItemBalances(db, ORG, one.id);
    assert.equal(balances.quantity, 10);
    assert.equal(balances.balances.length, 3, "Unassigned, bulk cabinet and side cart");
    assert.equal(
      balances.balances.reduce((sum, balance) => sum + balance.quantity, 0),
      10,
    );
    assert.ok(balances.balances.every((balance) => balance.inventoryItemId === one.id));
  }
});

// ---------------------------------------------------------------------------------------
// Authorization: every read function, every role.
// ---------------------------------------------------------------------------------------
test(
  "every read function: owner and admin pass; staff, other orgs, non-members and anon are refused",
  { skip },
  async () => {
    const bulk = await locationNamed(owner, "Bulk Cabinet");
    const item = (await allItems(owner, { search: "SKU-1" }))[0];
    const calls: Array<[string, (db: Db) => PromiseLike<{ error: { message: string } | null }>]> = [
      [
        "list_inventory_workspace_locations",
        (db) => db.rpc("list_inventory_workspace_locations", { _organization_id: ORG }),
      ],
      [
        "get_inventory_workspace_location",
        (db) =>
          db.rpc("get_inventory_workspace_location", {
            _organization_id: ORG,
            _inventory_location_id: bulk.id,
          }),
      ],
      [
        "list_inventory_workspace_location_stock",
        (db) =>
          db.rpc("list_inventory_workspace_location_stock", {
            _organization_id: ORG,
            _inventory_location_id: bulk.id,
            _limit: 5,
          }),
      ],
      [
        "list_inventory_workspace_items",
        (db) => db.rpc("list_inventory_workspace_items", { _organization_id: ORG, _limit: 5 }),
      ],
      [
        "list_inventory_workspace_item_balances",
        (db) =>
          db.rpc("list_inventory_workspace_item_balances", {
            _organization_id: ORG,
            _inventory_item_id: item.id,
          }),
      ],
    ];
    for (const [name, call] of calls) {
      for (const db of [owner, admin])
        assert.equal((await call(db)).error, null, `${name} allowed`);
      for (const db of [staff, otherOwner, otherAdmin, stranger]) {
        assert.match((await call(db)).error?.message ?? "", /owner or admin access required/, name);
      }
      assert.match((await call(anon)).error?.message ?? "", /permission denied/, `${name} anon`);
    }
  },
);

test("rows never escape the requested organization", { skip }, async () => {
  const other = await listAllWorkspaceLocations(otherOwner, OTHER_ORG, "all");
  assert.deepEqual(
    other.map((location) => location.name),
    ["Unassigned", "Other Org Cabinet"],
  );
  const otherCabinet = other[1];
  // An A admin asking about B's location or item through A gets nothing.
  await assert.rejects(
    getWorkspaceLocation(admin, ORG, otherCabinet.id),
    /Inventory location not found/,
  );
  await assert.rejects(
    listWorkspaceLocationStockPage(admin, {
      organizationId: ORG,
      locationId: otherCabinet.id,
      cursor: null,
      limit: 5,
    }),
    /Inventory location not found/,
  );
  const otherItems = await listWorkspaceItemsPage(otherOwner, {
    organizationId: OTHER_ORG,
    search: "",
    category: "",
    status: "all",
    lowStock: false,
    cursor: null,
    limit: 10,
  });
  assert.deepEqual(
    otherItems.rows.map((row) => row.name),
    ["Other Org Item"],
  );
  await assert.rejects(
    getWorkspaceItemBalances(admin, ORG, otherItems.rows[0].id),
    /Inventory item not found/,
  );
  const aIds = new Set(
    (await listAllWorkspaceLocations(admin, ORG, "all")).map((location) => location.id),
  );
  assert.ok(other.every((location) => !aIds.has(location.id)));
  assert.ok((await allItems(admin)).every((row) => row.name !== "Other Org Item"));
});

test(
  "exact returned columns; no purchase price, date or vendor cost anywhere",
  { skip },
  async () => {
    const bulk = await locationNamed(admin, "Bulk Cabinet");
    const item = (await allItems(admin, { search: "SKU-1" }))[0];
    const keys = async (call: PromiseLike<{ data: unknown }>) => {
      const { data } = await call;
      const row = Array.isArray(data) ? data[0] : data;
      return Object.keys(row as object).sort();
    };
    const contracts: Record<string, string[]> = {
      list_inventory_workspace_locations: await keys(
        admin.rpc("list_inventory_workspace_locations", { _organization_id: ORG, _limit: 1 }),
      ),
      get_inventory_workspace_location: await keys(
        admin.rpc("get_inventory_workspace_location", {
          _organization_id: ORG,
          _inventory_location_id: bulk.id,
        }),
      ),
      list_inventory_workspace_location_stock: await keys(
        admin.rpc("list_inventory_workspace_location_stock", {
          _organization_id: ORG,
          _inventory_location_id: bulk.id,
          _limit: 1,
        }),
      ),
      list_inventory_workspace_items: await keys(
        admin.rpc("list_inventory_workspace_items", { _organization_id: ORG, _limit: 1 }),
      ),
      list_inventory_workspace_item_balances: await keys(
        admin.rpc("list_inventory_workspace_item_balances", {
          _organization_id: ORG,
          _inventory_item_id: item.id,
        }),
      ),
    };
    assert.deepEqual(contracts, {
      list_inventory_workspace_locations: [
        "active",
        "active_label_count",
        "countable_item_count",
        "description",
        "inventory_location_id",
        "kind",
        "last_counted_at",
        "last_counted_by_name",
        "last_label_issued_at",
        "name",
        "sort_group",
        "sort_name",
        "stocked_item_count",
      ],
      get_inventory_workspace_location: [
        "active",
        "activeLabelCount",
        "archivedStockedItemCount",
        "countableItemCount",
        "description",
        "id",
        "kind",
        "lastCountedAt",
        "lastCountedByName",
        "lastLabelIssuedAt",
        "name",
        "stockedItemCount",
      ],
      list_inventory_workspace_location_stock: [
        "inventory_item_id",
        "item_active",
        "last_counted_at",
        "name",
        "organization_par_level",
        "organization_quantity",
        "organization_stock_status",
        "quantity",
        "sku",
        "sort_name",
        "unit",
      ],
      list_inventory_workspace_items: [
        "active",
        "category",
        "description",
        "inventory_item_id",
        "manufacturer",
        "name",
        "par_level",
        "physical_location_count",
        "physical_quantity",
        "quantity",
        "single_physical_location_name",
        "sku",
        "sort_name",
        "stock_status",
        "unassigned_quantity",
        "unit",
        "vendor_name",
      ],
      list_inventory_workspace_item_balances: ["balances", "inventoryItemId", "quantity"],
    });
    const everything =
      JSON.stringify(await allItems(admin)) + JSON.stringify(await allStock(admin, bulk.id));
    assert.doesNotMatch(everything, /12\.34|last_purchase|lastPurchase|price|2026-10-01/i);
  },
);

test("admins still read no raw location, balance, count or label rows", { skip }, async () => {
  for (const table of [
    "inventory_locations",
    "inventory_location_balances",
    "inventory_transfers",
    "inventory_count_sessions",
  ] as const) {
    const { data, error } = await admin.from(table).select("*").eq("organization_id", ORG).limit(5);
    assert.equal(error, null, table);
    assert.deepEqual(data, [], `${table} stays owner-only`);
  }
  const labels = await admin.from("inventory_location_labels").select("*");
  assert.match(labels.error?.message ?? "", /permission denied/);
});

// ---------------------------------------------------------------------------------------
// Mutations: owner-only at the server-function layer and in the database.
// ---------------------------------------------------------------------------------------
test(
  "the server-function owner check refuses admins and staff with their real JWTs",
  { skip },
  async () => {
    await assertInventoryOwner(owner, id("001"), ORG);
    for (const [db, suffix] of [
      [admin, "002"],
      [staff, "003"],
      [otherOwner, "004"],
      [stranger, "009"],
    ] as const) {
      await assert.rejects(assertInventoryOwner(db, id(suffix), ORG), /owner access required/);
    }
  },
);

test(
  "admins cannot change inventory through any path the workspace reaches",
  { skip },
  async () => {
    const bulk = await locationNamed(owner, "Bulk Cabinet");
    const side = await locationNamed(owner, "Side Cart");
    const empty = await locationNamed(owner, "Empty Shelf 001");
    const retired = await locationNamed(owner, "Retired Closet");
    const item = (await allItems(owner, { search: "SKU-1" })).find(
      (row) => row.name === "Item 0001",
    )!;
    const issued = await owner.rpc("issue_inventory_location_label", {
      _organization_id: ORG,
      _inventory_location_id: empty.id,
    });
    assert.equal(issued.error, null);
    const before = {
      locations: await listAllWorkspaceLocations(owner, ORG, "all"),
      items: await allItems(owner),
      balances: await getWorkspaceItemBalances(owner, ORG, item.id),
    };
    const rpcs: Array<[string, Record<string, unknown>]> = [
      ["create_inventory_location", { _organization_id: ORG, _name: "Admin Cabinet" }],
      [
        "update_inventory_location",
        { _organization_id: ORG, _inventory_location_id: bulk.id, _name: "Renamed" },
      ],
      [
        "set_inventory_location_active",
        { _organization_id: ORG, _inventory_location_id: empty.id, _active: false },
      ],
      [
        "set_inventory_location_active",
        { _organization_id: ORG, _inventory_location_id: retired.id, _active: true },
      ],
      [
        "move_inventory_stock",
        {
          _organization_id: ORG,
          _inventory_item_id: item.id,
          _from_inventory_location_id: bulk.id,
          _to_inventory_location_id: side.id,
          _quantity: 1,
          _idempotency_key: "admin-move",
        },
      ],
      [
        "adjust_inventory_location_quantity",
        {
          _organization_id: ORG,
          _inventory_item_id: item.id,
          _inventory_location_id: bulk.id,
          _adjustment_amount: -1,
          _reason: "Damaged",
        },
      ],
      [
        "adjust_inventory_quantity",
        {
          _organization_id: ORG,
          _inventory_item_id: item.id,
          _adjustment_amount: 1,
          _reason: "Correction",
        },
      ],
      [
        "issue_inventory_location_label",
        { _organization_id: ORG, _inventory_location_id: bulk.id },
      ],
      [
        "revoke_inventory_location_labels",
        { _organization_id: ORG, _inventory_location_id: empty.id },
      ],
      [
        "replace_inventory_location_labels",
        { _organization_id: ORG, _inventory_location_id: empty.id },
      ],
    ];
    for (const [name, args] of rpcs) {
      const { error } = await admin.rpc(name as never, args as never);
      assert.match(error?.message ?? "", /Forbidden/, name);
    }
    // Item create, edit and archive, and categories, as the forms send them.
    const insert = await admin
      .from("inventory_items")
      .insert({ organization_id: ORG, name: "Admin Item", unit: "each", quantity: 0 });
    assert.match(insert.error?.message ?? "", /row-level security/);
    const update = await admin
      .from("inventory_items")
      .update({ name: "Admin Renamed", par_level: 99 })
      .eq("id", item.id)
      .select("id");
    assert.deepEqual(update.data ?? [], [], "admin item edits match no rows");
    const archive = await admin
      .from("inventory_items")
      .update({ active: false })
      .eq("id", item.id)
      .select("id");
    assert.deepEqual(archive.data ?? [], [], "admin item archive matches no rows");
    const category = await admin
      .from("inventory_categories")
      .insert({ organization_id: ORG, name: "Admin Category" });
    assert.match(category.error?.message ?? "", /row-level security/);
    const directLocation = await admin
      .from("inventory_locations")
      .insert({ organization_id: ORG, name: "Direct" });
    assert.match(directLocation.error?.message ?? "", /permission denied/);
    const after = {
      locations: await listAllWorkspaceLocations(owner, ORG, "all"),
      items: await allItems(owner),
      balances: await getWorkspaceItemBalances(owner, ORG, item.id),
    };
    assert.deepEqual(after, before, "nothing changed");
  },
);

// ---------------------------------------------------------------------------------------
// Atomic Replace and revoke-only.
// ---------------------------------------------------------------------------------------
test(
  "a replacement that fails after revocation rolls back: earlier labels keep working",
  { skip },
  async () => {
    const forced = await locationNamed(owner, "Forced Failure Cabinet");
    const first = await owner.rpc("issue_inventory_location_label", {
      _organization_id: ORG,
      _inventory_location_id: forced.id,
    });
    assert.equal(first.error, null);
    const token = (first.data as { token: string }).token;
    await assert.rejects(
      replaceLocationLabels(owner, ORG, forced.id),
      /phase7b1 forced replacement failure/,
    );
    const after = await getWorkspaceLocation(admin, ORG, forced.id);
    assert.equal(after.activeLabelCount, 1, "no revocation committed and no replacement persisted");
    const resolved = await staff.rpc("resolve_inventory_count_label", { _token: token });
    assert.equal((resolved.data as { status: string }).status, "available");
  },
);

test(
  "replace revokes every earlier label and issues exactly one, shown once",
  { skip },
  async () => {
    const side = await locationNamed(owner, "Side Cart");
    const tokens = [];
    for (let i = 0; i < 2; i++) {
      const issued = await owner.rpc("issue_inventory_location_label", {
        _organization_id: ORG,
        _inventory_location_id: side.id,
      });
      tokens.push((issued.data as { token: string }).token);
    }
    assert.equal((await getWorkspaceLocation(admin, ORG, side.id)).activeLabelCount, 2);
    const replaced = await replaceLocationLabels(owner, ORG, side.id);
    assert.equal(replaced.revokedCount, 2);
    assert.match(replaced.token, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(replaced.locationName, "Side Cart");
    const detail = await getWorkspaceLocation(admin, ORG, side.id);
    assert.equal(detail.activeLabelCount, 1);
    assert.ok(detail.lastLabelIssuedAt);
    for (const old of tokens) {
      const resolved = await staff.rpc("resolve_inventory_count_label", { _token: old });
      assert.equal((resolved.data as { status: string }).status, "replaced");
    }
    const fresh = await staff.rpc("resolve_inventory_count_label", { _token: replaced.token });
    assert.equal((fresh.data as { status: string; locationName: string }).status, "available");
    // Nothing anywhere returns the token again.
    const again =
      JSON.stringify(await listAllWorkspaceLocations(owner, ORG, "all")) + JSON.stringify(detail);
    assert.ok(!again.includes(replaced.token));
  },
);

test(
  "revoke-only on an archived location ends with zero labels, and restore does not revive them",
  { skip },
  async () => {
    const shelf = await locationNamed(owner, "Empty Shelf 002");
    const issued = await owner.rpc("issue_inventory_location_label", {
      _organization_id: ORG,
      _inventory_location_id: shelf.id,
    });
    const token = (issued.data as { token: string }).token;
    assert.equal(
      (
        await owner.rpc("set_inventory_location_active", {
          _organization_id: ORG,
          _inventory_location_id: shelf.id,
          _active: false,
        })
      ).error,
      null,
    );
    const archived = await getWorkspaceLocation(admin, ORG, shelf.id);
    assert.equal(archived.active, false);
    assert.equal(archived.activeLabelCount, 1, "archiving suspends but does not revoke");
    const refusedReplace = await owner.rpc("replace_inventory_location_labels", {
      _organization_id: ORG,
      _inventory_location_id: shelf.id,
    });
    assert.match(refusedReplace.error?.message ?? "", /Restore Empty Shelf 002/);
    const refusedIssue = await owner.rpc("issue_inventory_location_label", {
      _organization_id: ORG,
      _inventory_location_id: shelf.id,
    });
    assert.match(refusedIssue.error?.message ?? "", /Restore Empty Shelf 002/);
    const revoked = await owner.rpc("revoke_inventory_location_labels", {
      _organization_id: ORG,
      _inventory_location_id: shelf.id,
    });
    assert.equal(revoked.data, 1);
    assert.equal((await getWorkspaceLocation(admin, ORG, shelf.id)).activeLabelCount, 0);
    await owner.rpc("set_inventory_location_active", {
      _organization_id: ORG,
      _inventory_location_id: shelf.id,
      _active: true,
    });
    const restored = await getWorkspaceLocation(admin, ORG, shelf.id);
    assert.equal(restored.active, true);
    assert.equal(restored.activeLabelCount, 0, "restore issues nothing");
    const resolved = await staff.rpc("resolve_inventory_count_label", { _token: token });
    assert.equal(
      (resolved.data as { status: string }).status,
      "replaced",
      "a revoked label stays dead",
    );
  },
);

test(
  "staff counting is unchanged: the count list and count page still work",
  { skip },
  async () => {
    const list = await staff.rpc("list_countable_inventory_locations", { _organization_id: ORG });
    assert.equal(list.error, null);
    assert.ok(list.data!.some((row) => row.name === "Bulk Cabinet"));
    const side = await locationNamed(owner, "Side Cart");
    const page = await staff.rpc("get_inventory_count_location", {
      _organization_id: ORG,
      _inventory_location_id: side.id,
    });
    assert.equal(page.error, null);
    assert.equal((page.data as { items: unknown[] }).items.length, 34);
  },
);

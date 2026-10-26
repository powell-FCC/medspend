// Phase 7A.1 old-application compatibility. Replays the exact PostgREST calls the currently
// deployed application (main f8a60fd) makes for inventory, invoice posting, invoice deletion
// and catalog stocking, through a real PostgREST with signed user JWTs.
//
// Started twice by supabase/tests/run_phase7a1_old_app_compat.sh: once against a database
// migrated to main only (control) and once with the 7A.1 migration applied. Every assertion
// must hold on both, which is what "safe to apply before the application deploys" means.
// Skipped by a plain `npm test`, which has no local stack.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const SCHEMA = process.env.MEDSPEND_7A1_COMPAT_SCHEMA ?? "";
const configured = Boolean(REST_URL && JWT_SECRET && SCHEMA);
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7a1_old_app_compat.sh";
const migrated = SCHEMA === "7a1";

const id = (suffix: string) => `7a1b0000-0000-4000-8000-000000000${suffix}`;
const ORG = id("101");
const TAPE_PRODUCT = id("401");

const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
function signToken(claims: Record<string, unknown>) {
  const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ ...claims, exp: Math.floor(Date.now() / 1000) + 3600 })}`;
  return `${body}.${createHmac("sha256", JWT_SECRET).update(body).digest("base64url")}`;
}
// The deployed app's client: publishable key plus the caller's bearer token. Untyped on
// purpose: these are main's calls, not the 7A.1 types.
function clientFor(claims: Record<string, unknown>) {
  return createClient(REST_URL, "local-publishable-key", {
    global: {
      headers: { Authorization: `Bearer ${signToken(claims)}` },
      fetch: (input, init) => fetch(String(input).replace("/rest/v1", ""), init),
    },
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });
}
const owner = configured ? clientFor({ role: "authenticated", sub: id("001") }) : (null as never);
const staff = configured ? clientFor({ role: "authenticated", sub: id("003") }) : (null as never);
const admin = configured ? clientFor({ role: "authenticated", sub: id("004") }) : (null as never);
const anon = configured ? clientFor({ role: "anon" }) : (null as never);
const inspect = configured ? clientFor({ role: "service_role" }) : (null as never);

async function quantity(itemId: string) {
  const { data, error } = await inspect
    .from("inventory_items")
    .select("quantity")
    .eq("id", itemId)
    .single();
  assert.equal(error, null);
  return Number(data!.quantity);
}
async function tapeId() {
  const { data } = await inspect
    .from("inventory_items")
    .select("id")
    .eq("product_id", TAPE_PRODUCT)
    .single();
  return data!.id as string;
}
// On the migrated schema every item must equal the sum of its balances, all in Unassigned
// (the old app cannot create physical locations).
async function invariant() {
  if (!migrated) return;
  const [{ data: items }, { data: balances }, { data: locations }] = await Promise.all([
    inspect.from("inventory_items").select("id,quantity").eq("organization_id", ORG),
    inspect
      .from("inventory_location_balances")
      .select("inventory_item_id,inventory_location_id,quantity")
      .eq("organization_id", ORG),
    inspect.from("inventory_locations").select("id,kind").eq("organization_id", ORG),
  ]);
  // service_role only has SELECT on the new tables; reading them is enough here.
  assert.ok(items && balances && locations, "migrated tables readable by service_role");
  assert.deepEqual(
    locations!.map((l) => l.kind),
    ["unassigned"],
  );
  for (const item of items!) {
    const sum = balances!
      .filter((b) => b.inventory_item_id === item.id)
      .reduce((s, b) => s + Number(b.quantity), 0);
    assert.equal(
      Number(sum.toFixed(6)),
      Number(item.quantity),
      `item ${item.id} equals its balances`,
    );
  }
}

test(`[${SCHEMA}] inventory list and categories read as before`, { skip }, async () => {
  const [items, categories] = await Promise.all([
    owner.from("inventory_items").select("*").eq("organization_id", ORG).order("name"),
    owner.from("inventory_categories").select("*").eq("organization_id", ORG).order("name"),
  ]);
  assert.equal(items.error, null);
  assert.equal(categories.error, null);
  assert.equal(items.data!.length, 5);
  assert.equal(Number(items.data!.find((row) => row.sku === "LEGACY-1")!.quantity), 14.333333);
  await invariant();
});

let created = "";
test(`[${SCHEMA}] old item create, edit and four-argument adjustments work`, { skip }, async () => {
  // saveInventoryItemFn, create path: insert at zero, then the four-argument adjust.
  const payload = {
    name: "Compat Splint",
    description: null,
    sku: null,
    vendor_name: null,
    category: "PPE",
    manufacturer: null,
    unit: "each",
    par_level: null,
  };
  const insert = await owner
    .from("inventory_items")
    .insert({ organization_id: ORG, ...payload, quantity: 0 })
    .select("id")
    .single();
  assert.equal(insert.error, null);
  created = insert.data!.id;
  const first = await owner.rpc("adjust_inventory_quantity", {
    _organization_id: ORG,
    _inventory_item_id: created,
    _adjustment_amount: 4.5,
    _reason: "Manual adjustment",
  });
  assert.equal(first.error, null);
  assert.equal(Number(first.data), 4.5);

  // saveInventoryItemFn, edit path: read quantity, update fields only, adjust the difference.
  const current = await owner
    .from("inventory_items")
    .select("quantity")
    .eq("id", created)
    .eq("organization_id", ORG)
    .single();
  assert.equal(current.error, null);
  const update = await owner
    .from("inventory_items")
    .update({ ...payload, name: "Compat Splint XL" })
    .eq("id", created)
    .eq("organization_id", ORG);
  assert.equal(update.error, null);
  const correction = await owner.rpc("adjust_inventory_quantity", {
    _organization_id: ORG,
    _inventory_item_id: created,
    _adjustment_amount: 6 - Number(current.data!.quantity),
    _reason: "Correction",
  });
  assert.equal(correction.error, null);
  assert.equal(Number(correction.data), 6);

  // adjustInventoryQuantityFn accepts every main reason, including "Invoice received".
  const receipt = await owner.rpc("adjust_inventory_quantity", {
    _organization_id: ORG,
    _inventory_item_id: created,
    _adjustment_amount: 1,
    _reason: "Invoice received",
  });
  assert.equal(receipt.error, null);
  assert.equal(Number(receipt.data), 7);
  const negative = await owner.rpc("adjust_inventory_quantity", {
    _organization_id: ORG,
    _inventory_item_id: created,
    _adjustment_amount: -8,
    _reason: "Damaged",
  });
  assert.match(negative.error?.message ?? "", /Quantity cannot be negative/);
  const forbidden = await admin.rpc("adjust_inventory_quantity", {
    _organization_id: ORG,
    _inventory_item_id: created,
    _adjustment_amount: 1,
    _reason: "Correction",
  });
  assert.match(forbidden.error?.message ?? "", /owner access required/);
  assert.equal(await quantity(created), 7);
  await invariant();
});

test(`[${SCHEMA}] old archive, restore and category rename work`, { skip }, async () => {
  for (const active of [false, true]) {
    const result = await owner
      .from("inventory_items")
      .update({ active })
      .eq("id", created)
      .eq("organization_id", ORG);
    assert.equal(result.error, null);
  }
  const rename = await owner
    .from("inventory_items")
    .update({ category: "Protective" })
    .eq("organization_id", ORG)
    .eq("category", "PPE");
  assert.equal(rename.error, null);
  const { data } = await inspect
    .from("inventory_items")
    .select("category,active,quantity")
    .eq("id", created)
    .single();
  assert.deepEqual([data!.category, data!.active, Number(data!.quantity)], ["Protective", true, 7]);
  await invariant();
});

test(`[${SCHEMA}] old invoice posting receives stock`, { skip }, async () => {
  const tape = await tapeId();
  const before = await quantity(tape);
  const { data, error } = await owner.rpc("post_reviewed_invoice", {
    _organization_id: ORG,
    _source_file_id: id("604"),
  });
  assert.equal(error, null);
  assert.deepEqual(
    [data.createdInventoryItems, data.updatedInventoryItems, data.alreadyCompleted],
    [0, 1, false],
  );
  assert.equal(await quantity(tape), before + 12.5);
  const again = await owner.rpc("post_reviewed_invoice", {
    _organization_id: ORG,
    _source_file_id: id("604"),
  });
  assert.equal(again.data.alreadyCompleted, true);
  assert.equal(await quantity(tape), before + 12.5);
  await invariant();
});

test(`[${SCHEMA}] old invoice deletion works for owners only`, { skip }, async () => {
  const tape = await tapeId();
  const before = await quantity(tape);
  for (const [client, pattern] of [
    [staff, /owner access required/],
    [admin, /owner access required/],
    [anon, /owner access required|permission denied/],
  ] as const) {
    const refused = await client.rpc("delete_invoice_permanently", {
      _organization_id: ORG,
      _source_file_id: id("604"),
    });
    assert.match(refused.error?.message ?? "", pattern);
  }
  assert.equal(await quantity(tape), before);
  const { data, error } = await owner.rpc("delete_invoice_permanently", {
    _organization_id: ORG,
    _source_file_id: id("604"),
  });
  assert.equal(error, null);
  assert.equal(typeof data.storagePath, "string");
  assert.equal(await quantity(tape), before - 12.5);
  await invariant();
});

test(
  `[${SCHEMA}] old catalog adoption and stocking create a zero-stock item`,
  { skip },
  async () => {
    const adopted = await admin.rpc("adopt_catalog_vendor_product", {
      _organization_id: ORG,
      _catalog_vendor_product_id: id("231"),
    });
    assert.equal(adopted.error, null);
    const stocked = await admin.rpc("stock_catalog_vendor_product", {
      _organization_id: ORG,
      _catalog_vendor_product_id: id("231"),
      _unit: "case",
      _par_level: 2,
    });
    assert.equal(stocked.error, null);
    assert.equal(stocked.data.inventoryCreated, true);
    assert.equal(Number(stocked.data.quantity), 0);
    assert.equal(await quantity(stocked.data.inventoryItemId), 0);
    const repeat = await admin.rpc("stock_catalog_vendor_product", {
      _organization_id: ORG,
      _catalog_vendor_product_id: id("231"),
      _unit: "case",
      _par_level: 2,
    });
    assert.equal(repeat.data.alreadyStocked, true);
    await invariant();
  },
);

test(`[${SCHEMA}] old inventory intelligence and staff reads still work`, { skip }, async () => {
  const receipts = await owner
    .from("inventory_adjustments")
    .select("inventory_item_id,created_at")
    .eq("organization_id", ORG)
    .eq("source_type", "invoice");
  assert.equal(receipts.error, null);
  assert.ok(receipts.data!.length >= 3);
  const staffItems = await staff
    .from("inventory_items")
    .select("id,name,unit,manufacturer,vendor_name,sku")
    .eq("organization_id", ORG)
    .eq("active", true);
  assert.equal(staffItems.error, null);
  assert.ok(staffItems.data!.length >= 5);
});

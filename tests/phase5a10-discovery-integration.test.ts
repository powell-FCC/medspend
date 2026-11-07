// Phase 5A.10 API integration: staff search, discovery and Saved Items through a real
// PostgREST with signed user JWTs, via the same helpers the server functions use
// (src/supply-requests/discovery-reads.ts). The fixture adds 100,000 synthetic catalog products
// and 3,600 organization requests. Started by
// supabase/tests/run_phase5a10_discovery_integration.sh; skipped by a plain `npm test`.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  getStaffProductDiscovery,
  searchStaffProducts,
  setStaffProductSaved,
} from "../src/supply-requests/discovery-reads.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
// This suite writes data. It only ever runs against a loopback address.
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase5a10_discovery_integration.sh";

const id = (suffix: string) => `5a10c000-0000-4000-8000-000000000${suffix}`;
const ORG = id("101");
const OTHER_ORG = id("102");

const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
function signToken(claims: Record<string, unknown>) {
  const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ ...claims, exp: Math.floor(Date.now() / 1000) + 3600 })}`;
  return `${body}.${createHmac("sha256", JWT_SECRET).update(body).digest("base64url")}`;
}
function clientFor(claims: Record<string, unknown>): SupabaseClient {
  return createClient(REST_URL, "local-publishable-key", {
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
const otherStaff = user("004");
const otherOwner = user("005");
const former = user("007");
const stranger = user("009");
const anon = configured ? clientFor({ role: "anon" }) : (null as never);

const keys = (rows: Array<{ resultId: string }>) => rows.map((row) => row.resultId);
const cvp = (suffix: string) => `catalog-vendor-product:${id(suffix)}`;

test(
  "staff search: exact SKU first, relevance before popularity, variants distinguished",
  { skip },
  async () => {
    const exact = await searchStaffProducts(staff, ORG, "FX-3000");
    assert.equal(exact[0]?.resultId, cvp("402"));
    assert.equal(exact[0]?.matchTier, 1);

    const tape = await searchStaffProducts(staff, ORG, "fixture athletic tape");
    // Three same-name variants by exact name (402 boosted by two approvals), then the popular
    // Bulk Pack (six approvals) only after them.
    assert.deepEqual(keys(tape).slice(0, 4), [cvp("402"), cvp("403"), cvp("401"), cvp("404")]);
    assert.deepEqual(
      tape.slice(0, 3).map((row) => row.matchTier),
      [2, 2, 2],
    );
    assert.equal(tape[3]?.approvedRequestCount, 6);
    assert.deepEqual(
      tape.slice(0, 3).map((row) => row.variantDetail),
      ['3" x 15 yd', '1/2" x 10 yd', '2" x 15 yd'],
    );
    // Denied requests and another organization's approvals never count.
    assert.equal(tape.find((row) => row.resultId === cvp("401"))?.approvedRequestCount, 0);

    const sized = await searchStaffProducts(staff, ORG, "fixture 2 inch tape");
    assert.deepEqual(keys(sized), [cvp("401")]);
    const typo = await searchStaffProducts(staff, ORG, "fixture atheltic");
    assert.ok(typo.length >= 3 && typo.every((row) => row.matchTier === 7));

    const purchased = await searchStaffProducts(staff, ORG, "fixture ice bag");
    assert.equal(purchased[0]?.purchaseCount, 1);
    assert.ok(purchased[0]?.lastPurchasedAt);
    assert.equal(purchased.length, 1, "organization B's product is not visible");
  },
);

test("staff search stays fast on the 100,000-product catalog", { skip }, async () => {
  const timings: Record<string, number> = {};
  for (const query of [
    "kinesiology tape",
    "elite ankle brace large",
    "SS-004244",
    "kinesiolgy tape",
    "nitrile gloves",
  ]) {
    await searchStaffProducts(staff, ORG, query); // warm the connection's plan cache
    const started = performance.now();
    const rows = await searchStaffProducts(staff, ORG, query);
    timings[query] = Math.round(performance.now() - started);
    assert.ok(rows.length > 0, query);
    assert.ok(rows.length <= 20);
  }
  console.log(`api round trips (ms): ${JSON.stringify(timings)}`);
  for (const [query, ms] of Object.entries(timings)) assert.ok(ms < 500, `${query} took ${ms} ms`);
  const sku = await searchStaffProducts(staff, ORG, "SS-004244");
  assert.equal(sku[0]?.vendorSku, "SS-004244");
  assert.equal(sku[0]?.matchTier, 1);
});

test("staff Saved Items: add, duplicate, discovery, boost, remove", { skip }, async () => {
  const identity = { productId: null, catalogVendorProductId: id("403"), inventoryItemId: null };
  assert.deepEqual(await setStaffProductSaved(staff, ORG, identity, true), {
    resultId: cvp("403"),
    saved: true,
  });
  assert.deepEqual(await setStaffProductSaved(staff, ORG, identity, true), {
    resultId: cvp("403"),
    saved: true,
  });

  const discovery = await getStaffProductDiscovery(staff, ORG);
  assert.equal(
    discovery.saved.filter((row) => row.resultId === cvp("403")).length,
    1,
    "saved once",
  );
  assert.equal(discovery.saved[0]?.resultId, cvp("403"), "newest saved first");
  const all = [...discovery.saved, ...discovery.frequent, ...discovery.purchased];
  assert.equal(new Set(keys(all)).size, all.length, "each product once");
  assert.ok(discovery.frequent.some((row) => row.resultId === cvp("404")));
  assert.equal(discovery.purchased.length, 6, "the history sections are bounded");

  const boosted = await searchStaffProducts(staff, ORG, "fixture athletic tape");
  assert.deepEqual(
    keys(boosted).slice(0, 3),
    [cvp("403"), cvp("402"), cvp("401")],
    "saved first within the tier",
  );
  assert.equal(boosted[0]?.isSaved, true);
  // Never across tiers: an exact SKU of another variant still wins.
  assert.equal((await searchStaffProducts(staff, ORG, "FX-2000"))[0]?.resultId, cvp("401"));

  // Another staff member sees none of it and cannot remove it.
  const theirs = await searchStaffProducts(otherStaff, ORG, "fixture athletic tape");
  assert.ok(theirs.every((row) => !row.isSaved));
  assert.equal((await getStaffProductDiscovery(otherStaff, ORG)).saved.length, 0);
  await setStaffProductSaved(otherStaff, ORG, identity, false);
  assert.equal((await searchStaffProducts(staff, ORG, "FX-0500"))[0]?.isSaved, true);
  // The other staff member's Saved Item in organization B stays in B.
  await setStaffProductSaved(otherStaff, OTHER_ORG, identity, true);
  assert.equal((await searchStaffProducts(otherStaff, ORG, "FX-0500"))[0]?.isSaved, false);
  assert.equal((await searchStaffProducts(otherStaff, OTHER_ORG, "FX-0500"))[0]?.isSaved, true);

  assert.deepEqual(await setStaffProductSaved(staff, ORG, identity, false), {
    resultId: cvp("403"),
    saved: false,
  });
  assert.equal((await searchStaffProducts(staff, ORG, "FX-0500"))[0]?.isSaved, false);
  await assert.rejects(
    setStaffProductSaved(
      staff,
      ORG,
      { productId: id("511"), catalogVendorProductId: null, inventoryItemId: null },
      true,
    ),
    /not available to request/,
  );
});

test(
  "owner and admin keep search and may use discovery and their own Saved Items",
  { skip },
  async () => {
    for (const db of [owner, admin]) {
      assert.equal((await searchStaffProducts(db, ORG, "FX-3000"))[0]?.resultId, cvp("402"));
      const identity = {
        productId: id("501"),
        catalogVendorProductId: null,
        inventoryItemId: null,
      };
      await setStaffProductSaved(db, ORG, identity, true);
      assert.ok(
        (await getStaffProductDiscovery(db, ORG)).saved.some((row) => row.productId === id("501")),
      );
      await setStaffProductSaved(db, ORG, identity, false);
    }
    // The legacy RPC (the currently deployed app) keeps its exact 12 columns.
    const { data, error } = await owner.rpc("search_supply_request_products", {
      _organization_id: ORG,
      _query: "FX-3000",
      _limit: 5,
    });
    assert.equal(error, null);
    assert.deepEqual(Object.keys((data as Array<Record<string, unknown>>)[0]!).sort(), [
      "catalog_vendor_product_id",
      "identity_source",
      "inventory_item_id",
      "manufacturer",
      "package_display",
      "package_status",
      "product_id",
      "product_name",
      "result_key",
      "vendor_name",
      "vendor_product_id",
      "vendor_sku",
    ]);
  },
);

test(
  "cross-organization, non-member, former member and signed-out callers are refused",
  { skip },
  async () => {
    const identity = { productId: id("501"), catalogVendorProductId: null, inventoryItemId: null };
    const cases: Array<[string, SupabaseClient, string]> = [
      ["staff in another organization", staff, OTHER_ORG],
      ["owner of another organization", otherOwner, ORG],
      ["non-member", stranger, ORG],
      ["former member", former, ORG],
    ];
    for (const [label, db, org] of cases) {
      await assert.rejects(searchStaffProducts(db, org, "tape"), /Not a member/, `${label} search`);
      await assert.rejects(getStaffProductDiscovery(db, org), /Not a member/, `${label} discovery`);
      await assert.rejects(
        setStaffProductSaved(db, org, identity, true),
        /Not a member/,
        `${label} save`,
      );
      await assert.rejects(
        setStaffProductSaved(db, org, identity, false),
        /Not a member/,
        `${label} remove`,
      );
      const legacy = await db.rpc("search_supply_request_products", {
        _organization_id: org,
        _query: "tape",
      });
      assert.match(legacy.error?.message ?? "", /Not a member/, `${label} legacy search`);
    }
    for (const [rpc, args] of [
      ["search_supply_request_products_with_signals", { _organization_id: ORG, _query: "tape" }],
      ["search_supply_request_products", { _organization_id: ORG, _query: "tape" }],
      ["get_staff_product_discovery", { _organization_id: ORG }],
      ["save_staff_product", { _organization_id: ORG, _product_id: id("501") }],
      ["remove_staff_saved_product", { _organization_id: ORG, _product_id: id("501") }],
    ] as const) {
      const { error } = await anon.rpc(rpc, args as never);
      assert.match(error?.message ?? "", /permission denied/, `anon ${rpc}`);
    }
  },
);

test("no raw table or internal function is reachable from the API", { skip }, async () => {
  for (const table of [
    "staff_saved_products",
    "catalog_vendor_product_search_documents",
    "catalog_search_terms",
  ]) {
    const { error } = await staff.from(table).select("*").limit(1);
    assert.match(error?.message ?? "", /permission denied/, table);
    const insert = await staff.from(table).insert({} as never);
    assert.ok(insert.error, `${table} insert`);
  }
  for (const [rpc, args] of [
    ["supply_request_product_search", { _organization_id: ORG, _query: "tape", _limit: 5 }],
    ["supply_request_product_history", { _organization_id: ORG }],
    [
      "supply_request_product_identities",
      {
        _organization_id: ORG,
        _product_ids: [],
        _catalog_vendor_product_ids: [],
        _inventory_item_ids: [],
      },
    ],
    ["refresh_catalog_vendor_product_search_documents", { _catalog_vendor_product_ids: null }],
  ] as const) {
    const { error } = await staff.rpc(rpc, args as never);
    assert.ok(error, `${rpc} must not be callable`);
  }
});

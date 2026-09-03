import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  cartContainsCustomItem,
  changeCartItemQuantity,
  createCustomCartItem,
  createStructuredCartItem,
  removeCartItem,
  resolveRequestContextId,
  toSubmissionItem,
} from "../src/supply-requests/staff-request-cart.ts";

const inventoryItemId = "11111111-1111-4111-8111-111111111111";
const productId = "22222222-2222-4222-8222-222222222222";
const vendorProductId = "33333333-3333-4333-8333-333333333333";
const catalogVendorProductId = "44444444-4444-4444-8444-444444444444";

const inventoryResult = {
  productName: "Elastic athletic tape",
  manufacturer: "Acme Medical",
  vendorName: "Supply Co",
  vendorSku: "TAPE-100",
  packageDisplay: "Box of 12 rolls",
  inventoryItemId,
  productId,
  vendorProductId,
  catalogVendorProductId,
};

const organizationProductResult = {
  productName: "Organization gauze",
  manufacturer: null,
  vendorName: null,
  vendorSku: null,
  packageDisplay: "Each",
  inventoryItemId: null,
  productId,
  vendorProductId: null,
  catalogVendorProductId: null,
};

test("inventory and organization product selections retain every returned identity field", () => {
  for (const [key, result] of [
    ["inventory", inventoryResult],
    ["organization", organizationProductResult],
  ] as const) {
    const item = createStructuredCartItem(key, result, 2);
    assert.equal(item.kind, "structured");
    assert.deepEqual(toSubmissionItem(item), {
      productId: result.productId,
      inventoryItemId: result.inventoryItemId,
      vendorProductId: result.vendorProductId,
      catalogVendorProductId: result.catalogVendorProductId,
      freeTextItem: null,
      quantity: 2,
    });
  }
});

test("a global catalog result with no productId remains structured", () => {
  const globalItem = createStructuredCartItem(
    "global",
    {
      productName: "Catalog-only cold pack",
      manufacturer: "Cold Pack Labs",
      vendorName: "Global Vendor",
      vendorSku: "CP-900",
      packageDisplay: "Case of 24",
      inventoryItemId: null,
      productId: null,
      vendorProductId: null,
      catalogVendorProductId,
    },
    3,
  );

  assert.equal(globalItem.kind, "structured");
  assert.equal(cartContainsCustomItem([globalItem]), false);
  assert.deepEqual(toSubmissionItem(globalItem), {
    productId: null,
    inventoryItemId: null,
    vendorProductId: null,
    catalogVendorProductId,
    freeTextItem: null,
    quantity: 3,
  });
});

test("custom lines remain free text and mixed carts map without identity inference", () => {
  const structured = createStructuredCartItem("structured", inventoryResult, 1);
  const custom = createCustomCartItem("custom", "  Custom ankle wrap  ", 4);

  assert.equal(custom.kind, "custom");
  assert.equal(cartContainsCustomItem([structured, custom]), true);
  assert.deepEqual([structured, custom].map(toSubmissionItem), [
    {
      productId,
      inventoryItemId,
      vendorProductId,
      catalogVendorProductId,
      freeTextItem: null,
      quantity: 1,
    },
    {
      productId: null,
      inventoryItemId: null,
      vendorProductId: null,
      catalogVendorProductId: null,
      freeTextItem: "Custom ankle wrap",
      quantity: 4,
    },
  ]);
});

test("quantity edits and removals preserve the identity of every remaining line", () => {
  const first = createStructuredCartItem("first", inventoryResult, 2);
  const second = createStructuredCartItem(
    "second",
    {
      ...organizationProductResult,
      productName: "Second item",
    },
    5,
  );

  const increased = changeCartItemQuantity([first, second], "first", 1);
  assert.equal(increased[0]?.quantity, 3);
  assert.deepEqual(toSubmissionItem(increased[0]!), {
    ...toSubmissionItem(first),
    quantity: 3,
  });
  assert.deepEqual(increased[1], second);

  const remaining = removeCartItem(increased, "first");
  assert.deepEqual(remaining, [second]);
  assert.deepEqual(toSubmissionItem(remaining[0]!), toSubmissionItem(second));
  assert.equal(changeCartItemQuantity([first], "first", -10)[0]?.quantity, 1);
  assert.equal(first.quantity, 2);
});

test("a sole active team or location is resolved automatically", () => {
  assert.equal(resolveRequestContextId(null, "", [{ id: "sole-team" }]), "sole-team");
  assert.equal(resolveRequestContextId(undefined, "", [{ id: "sole-location" }]), "sole-location");
});

test("multiple context options still require an explicit selection", () => {
  const options = [{ id: "first" }, { id: "second" }];
  assert.equal(resolveRequestContextId(null, "", options), null);
  assert.equal(resolveRequestContextId(null, "second", options), "second");
});

test("a valid membership default takes precedence over an explicit selection", () => {
  const options = [{ id: "membership-default" }, { id: "explicit-selection" }];
  assert.equal(
    resolveRequestContextId("membership-default", "explicit-selection", options),
    "membership-default",
  );
  assert.equal(
    resolveRequestContextId("inactive-default", "explicit-selection", options),
    "explicit-selection",
  );
});

test("unavailable defaults and selections never supply invalid request context", () => {
  assert.equal(resolveRequestContextId("inactive-default", "stale-selection", []), null);
  assert.equal(resolveRequestContextId(null, "", []), null);
  assert.equal(
    resolveRequestContextId("inactive-default", "stale-selection", [{ id: "sole-active" }]),
    "sole-active",
  );
  assert.equal(
    resolveRequestContextId("inactive-default", "stale-selection", [{ id: "first" }, { id: "second" }]),
    null,
  );
});

test("staff route uses unified search and represents the mobile search states", async () => {
  const route = await readFile(
    new URL("../src/routes/_authenticated/staff/request.tsx", import.meta.url),
    "utf8",
  );

  assert.match(route, /useServerFn\(searchSupplyRequestProductsFn\)/);
  assert.doesNotMatch(route, /\bsearchProductsFn\b/);
  assert.match(route, /useDebouncedValue\(normalizedQuery, 300\)/);
  assert.match(route, /Search by product name, manufacturer, vendor, or SKU/);
  assert.match(route, /Searching after you pause/);
  assert.match(route, /aria-label="Searching supplies"/);
  assert.match(route, /aria-label="Search results"/);
  assert.match(route, /No matching supplies found/);
  assert.match(route, /We couldn't search supplies/);
  assert.match(route, /product\.productName/);
  assert.match(route, /product\.manufacturer/);
  assert.match(route, /product\.vendorName/);
  assert.match(route, /product\.vendorSku/);
  assert.match(route, /product\.packageDisplay/);
  assert.match(route, /items\.map\(toSubmissionItem\)/);
  assert.match(route, /teamId: resolvedTeamId/);
  assert.match(route, /locationId: resolvedLocationId/);
  assert.match(route, /const showTeamSelector = !hasActiveDefaultTeam && teams\.length > 1/);
  assert.match(
    route,
    /const showLocationSelector = !hasActiveDefaultLocation && locations\.length > 1/,
  );
  assert.match(route, /if \(!resolvedTeamId \|\| !resolvedLocationId\)/);
  assert.doesNotMatch(route, /\.rpc\(/);
  assert.doesNotMatch(route, /\b(?:adopt|stock)(?:Catalog|Inventory)\w*Fn\b/);
  assert.doesNotMatch(route, /identitySource/);
});

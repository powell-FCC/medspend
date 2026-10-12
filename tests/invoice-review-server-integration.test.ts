// Integration test: the invoice review actions behind the server functions, against a real
// local Postgres (every migration applied) through a real PostgREST, with supabase-js and
// signed user JWTs. Started by supabase/tests/run_invoice_review_integration.sh; skipped by
// a plain `npm test`, which has no local stack.
//
// Exercised for real: input schemas, owner checks, every query and RPC the actions make,
// row-level security and role switching in PostgREST, the database functions and triggers,
// and the translation of database errors into reviewer-facing errors.
// Not exercised: TanStack's server-function transport, and the requireSupabaseAuth
// middleware that builds the client from the request (token verification with Supabase
// Auth). The client here is built the same way, from a bearer token.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test, { before } from "node:test";
import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import {
  INVENTORY_SKU_CONFLICT_MESSAGE,
  InvoiceReviewError,
  catalogMatchInput,
  catalogSearchInput,
  confirmInvoiceItemProduct,
  confirmMatchInput,
  deleteInvoiceItem,
  itemInput,
  itemKeyInput,
  matchInvoiceItemToCatalog,
  refreshDerivedInvoiceTotals,
  saveInvoiceItem,
  searchInvoiceCatalog,
  toInvoiceReviewError,
} from "../src/invoice/review-actions.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
// This suite writes data. It only ever runs against a loopback address.
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_invoice_review_integration.sh";

const id = (suffix: string) => `c0de0000-0000-4000-8000-000000000${suffix}`;
const OWNER = id("001");
const ADMIN = id("002");
const ORG = id("101");
const HENRY_SCHEIN = id("301");
const LISTING = {
  readyWrap: id("231"),
  hydrofilm: id("232"),
  mini: id("233"),
  medline: id("238"),
  collision: id("239"),
};
const PRODUCT = { tape: id("401"), stockedGauze: id("403"), otherGauze: id("404") };
const SOURCE = {
  match: id("601"),
  unlinked: id("602"),
  medline: id("603"),
  post: id("604"),
  derivedBoth: id("605"),
  derivedSubtotal: id("606"),
  printed: id("607"),
};
const INVOICE = {
  match: id("701"),
  derivedBoth: id("705"),
  derivedSubtotal: id("706"),
  printed: id("707"),
};

const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
function signToken(claims: Record<string, unknown>) {
  const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ ...claims, exp: Math.floor(Date.now() / 1000) + 3600 })}`;
  return `${body}.${createHmac("sha256", JWT_SECRET).update(body).digest("base64url")}`;
}
// Built the way requireSupabaseAuth builds it: publishable key plus the caller's bearer token.
function clientFor(claims: Record<string, unknown>): SupabaseClient<Database> {
  return createClient<Database>(REST_URL, "local-publishable-key", {
    global: {
      headers: { Authorization: `Bearer ${signToken(claims)}` },
      // supabase-js addresses PostgREST at <url>/rest/v1; the local PostgREST serves at the root.
      fetch: (input, init) => fetch(String(input).replace("/rest/v1", ""), init),
    },
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });
}
const owner = configured ? clientFor({ role: "authenticated", sub: OWNER }) : (null as never);
const admin = configured ? clientFor({ role: "authenticated", sub: ADMIN }) : (null as never);
// Assertions only: reads past row-level security.
const inspect = configured ? clientFor({ role: "service_role" }) : (null as never);

async function line(lineId: string) {
  const { data, error } = await inspect.from("invoice_items").select("*").eq("id", lineId).single();
  assert.equal(error, null);
  return data!;
}
async function identityCounts() {
  const [products, mappings, inventory, adjustments] = await Promise.all([
    inspect
      .from("products")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", ORG),
    inspect
      .from("vendor_products")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", ORG),
    inspect
      .from("inventory_items")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", ORG),
    inspect
      .from("inventory_adjustments")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", ORG),
  ]);
  return {
    products: products.count,
    mappings: mappings.count,
    inventory: inventory.count,
    adjustments: adjustments.count,
  };
}
async function mappingsForKey(key: string) {
  const { data } = await inspect
    .from("vendor_products")
    .select("id,vendor_sku,product_id,active,catalog_vendor_product_id")
    .eq("organization_id", ORG)
    .eq("vendor_id", HENRY_SCHEIN);
  return (data ?? []).filter(
    (mapping) => mapping.vendor_sku.replace(/[^A-Za-z0-9]/g, "").toUpperCase() === key,
  );
}
async function totals(invoiceId: string, sourceFileId: string) {
  const [{ data: invoice }, { data: job }] = await Promise.all([
    inspect
      .from("invoices")
      .select("subtotal,tax_amount,shipping_amount,invoice_total,total_amount,total")
      .eq("id", invoiceId)
      .single(),
    inspect
      .from("invoice_processing_jobs")
      .select("extraction_result")
      .eq("invoice_id", sourceFileId)
      .single(),
  ]);
  const extraction = job!.extraction_result as unknown as {
    header: Record<
      "subtotal" | "total" | "tax" | "shipping",
      { value: number | null; confidence: number; source: string; reviewed: boolean }
    >;
    reconciliation: { needsReview: boolean };
  };
  return {
    invoice: invoice!,
    header: extraction.header,
    needsReview: extraction.reconciliation.needsReview,
  };
}
const rejects = (promise: Promise<unknown>, code: string, message: RegExp) =>
  assert.rejects(promise, (error: unknown) => {
    assert.ok(
      error instanceof InvoiceReviewError,
      `expected a controlled error, got ${String(error)}`,
    );
    assert.equal(error.code, code);
    assert.match(error.message, message);
    // Nothing from the database leaks: no constraint names, SQL states, or row identifiers.
    assert.doesNotMatch(
      error.message,
      /duplicate key|violates|constraint|_uq\b|_unique\b|[0-9a-f]{8}-[0-9a-f]{4}-/i,
    );
    return true;
  });
const lineInput = (
  sourceFileId: string,
  values: {
    id?: string;
    sku: string;
    description: string;
    quantity: number;
    unitPrice: number;
    totalPrice: number;
  },
) => itemInput.parse({ organizationId: ORG, sourceFileId, unitOfMeasure: "EA", ...values });

let readyWrapProduct = "";
let baseline: Awaited<ReturnType<typeof identityCounts>>;

before(async () => {
  if (!configured) return;
  // As on every review load: exact vendor-SKU lines are matched by the database first.
  const { error } = await owner.rpc("resolve_invoice_exact_product_identities", {
    _organization_id: ORG,
    _source_file_id: SOURCE.match,
  });
  assert.equal(error, null);
  readyWrapProduct = (await line(id("805"))).product_id ?? "";
  assert.ok(
    readyWrapProduct,
    "fixture: the exact catalog SKU line should be matched automatically",
  );
  assert.equal((await line(id("806"))).product_id, readyWrapProduct);
  baseline = await identityCounts();
  assert.equal(baseline.inventory, 1, "fixture: only the pre-stocked gauze has inventory");
});

test("search returns the linked vendor's catalog, and only that vendor's", { skip }, async () => {
  const byName = await searchInvoiceCatalog(
    owner,
    OWNER,
    catalogSearchInput.parse({
      organizationId: ORG,
      sourceFileId: SOURCE.match,
      query: "hydrofilm",
    }),
  );
  assert.equal(byName.available, true);
  assert.equal(byName.catalogVendorName, "Henry Schein");
  assert.deepEqual(
    byName.results.map((result) => [
      result.catalogVendorProductId,
      result.vendorSku,
      result.organizationProductId,
    ]),
    [[LISTING.hydrofilm, "143-9000", null]],
  );

  // The invoice prints 3240025; the catalog stores 324-0025. Medline lists the same SKU.
  const bySku = await searchInvoiceCatalog(
    owner,
    OWNER,
    catalogSearchInput.parse({ organizationId: ORG, sourceFileId: SOURCE.match, query: "3240025" }),
  );
  assert.deepEqual(
    bySku.results.map((result) => result.catalogVendorProductId),
    [LISTING.readyWrap],
  );
  assert.equal(bySku.results[0].organizationProductId, readyWrapProduct);
  for (const query of ["324", "wrap", "dressing", "hydrofilm"]) {
    const found = await searchInvoiceCatalog(
      owner,
      OWNER,
      catalogSearchInput.parse({ organizationId: ORG, sourceFileId: SOURCE.match, query }),
    );
    assert.ok(
      !found.results.some((result) => result.catalogVendorProductId === LISTING.medline),
      query,
    );
  }
  // The Medline invoice sees Medline's listing for that SKU, not Henry Schein's.
  const medline = await searchInvoiceCatalog(
    owner,
    OWNER,
    catalogSearchInput.parse({
      organizationId: ORG,
      sourceFileId: SOURCE.medline,
      query: "3240025",
    }),
  );
  assert.deepEqual(
    medline.results.map((result) => result.catalogVendorProductId),
    [LISTING.medline],
  );
  // A SKU the catalog does not list.
  const missing = await searchInvoiceCatalog(
    owner,
    OWNER,
    catalogSearchInput.parse({ organizationId: ORG, sourceFileId: SOURCE.match, query: "1439386" }),
  );
  assert.deepEqual(missing, {
    available: true,
    reason: null,
    catalogVendorName: "Henry Schein",
    results: [],
  });
});

test("an unlinked vendor has no catalog to search or match against", { skip }, async () => {
  const search = await searchInvoiceCatalog(
    owner,
    OWNER,
    catalogSearchInput.parse({
      organizationId: ORG,
      sourceFileId: SOURCE.unlinked,
      query: "324-0025",
    }),
  );
  assert.deepEqual(search, {
    available: false,
    reason: "vendor_not_linked_to_catalog",
    catalogVendorName: "",
    results: [],
  });
  await rejects(
    matchInvoiceItemToCatalog(
      owner,
      OWNER,
      catalogMatchInput.parse({
        organizationId: ORG,
        sourceFileId: SOURCE.unlinked,
        itemId: id("811"),
        catalogVendorProductId: LISTING.readyWrap,
        expectedProductId: null,
      }),
    ),
    "rejected",
    /not linked to a catalog vendor/,
  );
  assert.equal((await line(id("811"))).product_id, null);
});

test("choosing a catalog item adopts it and matches the line, once", { skip }, async () => {
  const input = catalogMatchInput.parse({
    organizationId: ORG,
    sourceFileId: SOURCE.match,
    itemId: id("802"),
    catalogVendorProductId: LISTING.hydrofilm,
    expectedProductId: null,
  });
  const match = await matchInvoiceItemToCatalog(owner, OWNER, input);
  const matched = await line(id("802"));
  assert.equal(matched.product_id, match.productId);
  assert.equal(matched.product_match_source, "manual");
  assert.equal(matched.vendor_product_id, match.vendorProductId);
  assert.equal(match.vendorSkuRemembered, true);
  assert.equal(match.preservedMapping, null);
  const { data: product } = await inspect
    .from("products")
    .select("name,catalog_product_id,organization_id,active")
    .eq("id", match.productId)
    .single();
  assert.deepEqual(product, {
    name: "Hydrofilm Transparent Dressing 4x6",
    catalog_product_id: id("212"),
    organization_id: ORG,
    active: true,
  });
  // The invoice's own SKU is remembered for the adopted product; the listing keeps its mapping.
  assert.deepEqual(
    (await mappingsForKey("1439386")).map((mapping) => [
      mapping.vendor_sku,
      mapping.product_id,
      mapping.catalog_vendor_product_id,
    ]),
    [["1439386", match.productId, null]],
  );
  assert.deepEqual(
    (await mappingsForKey("1439000")).map((mapping) => [
      mapping.vendor_sku,
      mapping.product_id,
      mapping.catalog_vendor_product_id,
    ]),
    [["143-9000", match.productId, LISTING.hydrofilm]],
  );
  const afterFirst = await identityCounts();
  assert.deepEqual(afterFirst, {
    products: baseline.products! + 1,
    mappings: baseline.mappings! + 2,
    inventory: baseline.inventory,
    adjustments: baseline.adjustments,
  });

  // Repeating the same choice (naming the current match) creates nothing.
  const again = await matchInvoiceItemToCatalog(owner, OWNER, {
    ...input,
    expectedProductId: match.productId,
  });
  assert.equal(again.productId, match.productId);
  assert.equal(again.vendorProductId, match.vendorProductId);
  assert.deepEqual(await identityCounts(), afterFirst);
  // Another line choosing the same listing reuses the adopted product.
  const second = await matchInvoiceItemToCatalog(
    owner,
    OWNER,
    catalogMatchInput.parse({
      organizationId: ORG,
      sourceFileId: SOURCE.match,
      itemId: id("803"),
      catalogVendorProductId: LISTING.hydrofilm,
      expectedProductId: null,
    }),
  );
  assert.equal(second.productId, match.productId);
  assert.deepEqual(await identityCounts(), { ...afterFirst, mappings: afterFirst.mappings! + 1 });
});

test(
  "a stale, cross-vendor, or conflicting catalog choice is refused with a controlled error",
  { skip },
  async () => {
    const before = await identityCounts();
    const matched = await line(id("803"));
    // Stale: the caller believes the line is unmatched, or matched to something else.
    for (const expectedProductId of [null, PRODUCT.tape]) {
      await rejects(
        matchInvoiceItemToCatalog(
          owner,
          OWNER,
          catalogMatchInput.parse({
            organizationId: ORG,
            sourceFileId: SOURCE.match,
            itemId: id("803"),
            catalogVendorProductId: LISTING.mini,
            expectedProductId,
          }),
        ),
        "rejected",
        /product match has changed/,
      );
    }
    // Another vendor's listing, and a listing that does not exist.
    for (const catalogVendorProductId of [LISTING.medline, id("999")]) {
      await rejects(
        matchInvoiceItemToCatalog(
          owner,
          OWNER,
          catalogMatchInput.parse({
            organizationId: ORG,
            sourceFileId: SOURCE.match,
            itemId: id("804"),
            catalogVendorProductId,
            expectedProductId: null,
          }),
        ),
        "rejected",
        /does not belong to the invoice vendor's catalog/,
      );
    }
    // Adoption would collide with an existing organization product: the database's unique
    // violation is reported as a controlled conflict.
    await rejects(
      matchInvoiceItemToCatalog(
        owner,
        OWNER,
        catalogMatchInput.parse({
          organizationId: ORG,
          sourceFileId: SOURCE.match,
          itemId: id("804"),
          catalogVendorProductId: LISTING.collision,
          expectedProductId: null,
        }),
      ),
      "rejected",
      /conflicts with a product or vendor SKU mapping your organization already has/,
    );
    assert.deepEqual(await line(id("803")), matched);
    assert.equal((await line(id("804"))).product_id, null);
    assert.deepEqual(await identityCounts(), before);
  },
);

test(
  "re-matching a catalog-adopted SKU to another product succeeds and keeps the mapping",
  { skip },
  async () => {
    const before = await identityCounts();
    const adopted = await mappingsForKey("3240025");
    assert.deepEqual(
      adopted.map((mapping) => [
        mapping.vendor_sku,
        mapping.product_id,
        mapping.catalog_vendor_product_id,
      ]),
      [["324-0025", readyWrapProduct, LISTING.readyWrap]],
    );

    // Exact catalog SKU (324-0025) and the same SKU without separators (3240025).
    for (const itemId of [id("805"), id("806")]) {
      const match = await confirmInvoiceItemProduct(
        owner,
        OWNER,
        confirmMatchInput.parse({
          organizationId: ORG,
          sourceFileId: SOURCE.match,
          itemId,
          productId: PRODUCT.tape,
        }),
      );
      assert.deepEqual(match, {
        productId: PRODUCT.tape,
        vendorProductId: null,
        vendorSkuRemembered: false,
        preservedMapping: { vendorSku: "324-0025", productName: "Ready Wrap Plastic Wrap" },
      });
      const matched = await line(itemId);
      assert.equal(matched.product_id, PRODUCT.tape);
      assert.equal(matched.vendor_product_id, null);
      assert.equal(matched.product_match_source, "manual");
    }
    // To another catalog product, naming the product being replaced.
    const toCatalog = await matchInvoiceItemToCatalog(
      owner,
      OWNER,
      catalogMatchInput.parse({
        organizationId: ORG,
        sourceFileId: SOURCE.match,
        itemId: id("801"),
        catalogVendorProductId: LISTING.mini,
        expectedProductId: readyWrapProduct,
      }),
    );
    assert.equal(toCatalog.vendorSkuRemembered, false);
    assert.deepEqual(toCatalog.preservedMapping, {
      vendorSku: "324-0025",
      productName: "Ready Wrap Plastic Wrap",
    });
    assert.equal((await line(id("801"))).product_id, toCatalog.productId);
    assert.notEqual(toCatalog.productId, readyWrapProduct);

    // The adopted mapping is exactly as it was: not repointed, not duplicated, not shadowed.
    assert.deepEqual(await mappingsForKey("3240025"), adopted);
    // Only the newly chosen listing's own adoption was added (product and its 324-0026 mapping).
    assert.deepEqual(await identityCounts(), {
      products: before.products! + 1,
      mappings: before.mappings! + 1,
      inventory: before.inventory,
      adjustments: before.adjustments,
    });

    // Matching back to the catalog product reuses the adopted mapping for both spellings.
    for (const itemId of [id("805"), id("806")]) {
      const back = await confirmInvoiceItemProduct(
        owner,
        OWNER,
        confirmMatchInput.parse({
          organizationId: ORG,
          sourceFileId: SOURCE.match,
          itemId,
          productId: readyWrapProduct,
        }),
      );
      assert.equal(back.vendorProductId, adopted[0].id);
      assert.equal(back.vendorSkuRemembered, true);
      assert.equal(back.preservedMapping, null);
    }
    assert.equal((await mappingsForKey("3240025")).length, 1);
  },
);

test(
  "only an owner can use these actions, and inputs are validated before any query",
  { skip },
  async () => {
    await rejects(
      searchInvoiceCatalog(
        admin,
        ADMIN,
        catalogSearchInput.parse({
          organizationId: ORG,
          sourceFileId: SOURCE.match,
          query: "wrap",
        }),
      ),
      "forbidden",
      /owner access required/,
    );
    await rejects(
      matchInvoiceItemToCatalog(
        admin,
        ADMIN,
        catalogMatchInput.parse({
          organizationId: ORG,
          sourceFileId: SOURCE.match,
          itemId: id("804"),
          catalogVendorProductId: LISTING.mini,
          expectedProductId: null,
        }),
      ),
      "forbidden",
      /owner access required/,
    );
    // An admin's token with the owner's user id passes the application's own check, and is
    // still refused: the database decides from the token, and its refusal is passed on as is.
    await rejects(
      matchInvoiceItemToCatalog(
        admin,
        OWNER,
        catalogMatchInput.parse({
          organizationId: ORG,
          sourceFileId: SOURCE.match,
          itemId: id("804"),
          catalogVendorProductId: LISTING.mini,
          expectedProductId: null,
        }),
      ),
      "forbidden",
      /^Forbidden: owner access required$/,
    );
    assert.equal((await line(id("804"))).product_id, null);
    assert.throws(() =>
      catalogMatchInput.parse({
        organizationId: ORG,
        sourceFileId: SOURCE.match,
        itemId: "not-a-uuid",
        catalogVendorProductId: LISTING.mini,
        expectedProductId: null,
      }),
    );
    assert.throws(() =>
      catalogMatchInput.parse({
        organizationId: ORG,
        sourceFileId: SOURCE.match,
        itemId: id("804"),
        catalogVendorProductId: LISTING.mini,
      }),
    );
    assert.throws(() =>
      catalogSearchInput.parse({
        organizationId: ORG,
        sourceFileId: SOURCE.match,
        query: "x".repeat(201),
      }),
    );
    assert.equal(
      catalogSearchInput.parse({ organizationId: ORG, sourceFileId: SOURCE.match }).query,
      "",
    );
  },
);

test("no manual matching stocked inventory", { skip }, async () => {
  const counts = await identityCounts();
  assert.equal(counts.inventory, baseline.inventory);
  assert.equal(counts.adjustments, baseline.adjustments);
  const { count } = await inspect
    .from("inventory_price_history")
    .select("id", { count: "exact", head: true })
    .eq("organization_id", ORG);
  assert.equal(count, 0);
});

test(
  "a real constraint failure from posting is translated into a controlled error",
  { skip },
  async () => {
    // The line prints a SKU that another product already holds in inventory for this vendor.
    await confirmInvoiceItemProduct(
      owner,
      OWNER,
      confirmMatchInput.parse({
        organizationId: ORG,
        sourceFileId: SOURCE.post,
        itemId: id("831"),
        productId: PRODUCT.otherGauze,
      }),
    );
    // approveInvoiceFn makes exactly this call and passes its error to toInvoiceReviewError.
    const { data, error } = await owner.rpc("post_reviewed_invoice", {
      _organization_id: ORG,
      _source_file_id: SOURCE.post,
    });
    assert.equal(data, null);
    assert.equal(error?.code, "23505");
    assert.match(
      error?.message ?? "",
      /duplicate key value violates unique constraint "inventory_items_org_vendor_sku_unique"/,
    );
    const translated = toInvoiceReviewError(error!, "Could not approve this invoice.");
    assert.deepEqual(
      [translated.code, translated.message],
      ["conflict", INVENTORY_SKU_CONFLICT_MESSAGE],
    );
    // Posting is all-or-nothing: the invoice is still a draft and nothing was stocked.
    const { data: invoice } = await inspect
      .from("invoices")
      .select("processing_status,posted_at")
      .eq("source_file_id", SOURCE.post)
      .single();
    assert.deepEqual(invoice, { processing_status: "review_required", posted_at: null });
    assert.equal((await identityCounts()).inventory, baseline.inventory);
    // The posting gate's own refusal passes through unchanged.
    const gate = await owner.rpc("post_reviewed_invoice", {
      _organization_id: ORG,
      _source_file_id: SOURCE.match,
    });
    assert.match(
      toInvoiceReviewError(gate.error!, "fallback").message,
      /^Match or create a product for every invoice line before approval/,
    );
  },
);

test(
  "calculated subtotal and total follow line edits, deletions, and additions",
  { skip },
  async () => {
    const state = () => totals(INVOICE.derivedBoth, SOURCE.derivedBoth);
    const expectCalculated = async (subtotal: number, total: number) => {
      const now = await state();
      assert.deepEqual(
        [
          now.invoice.subtotal,
          now.invoice.invoice_total,
          now.invoice.total_amount,
          now.invoice.total,
        ],
        [subtotal, total, total, total],
      );
      assert.deepEqual(now.header.subtotal, {
        value: subtotal,
        confidence: 60,
        source: "Derived",
        reviewed: false,
      });
      assert.deepEqual(now.header.total, {
        value: total,
        confidence: 60,
        source: "Derived",
        reviewed: false,
      });
      assert.equal(now.needsReview, false);
    };
    await expectCalculated(30, 37);

    // Edit quantity and price.
    await saveInvoiceItem(
      owner,
      OWNER,
      lineInput(SOURCE.derivedBoth, {
        id: id("851"),
        sku: "D-1",
        description: "Derived both, line one",
        quantity: 3,
        unitPrice: 10.1,
        totalPrice: 30.3,
      }),
    );
    await expectCalculated(40.3, 47.3);
    // Delete a line.
    await deleteInvoiceItem(
      owner,
      OWNER,
      itemKeyInput.parse({ organizationId: ORG, sourceFileId: SOURCE.derivedBoth, id: id("852") }),
    );
    await expectCalculated(30.3, 37.3);
    // Add a line.
    const added = await saveInvoiceItem(
      owner,
      OWNER,
      lineInput(SOURCE.derivedBoth, {
        sku: "D-3",
        description: "Added line",
        quantity: 1,
        unitPrice: 4.35,
        totalPrice: 4.35,
      }),
    );
    await expectCalculated(34.65, 41.65);

    // A line whose total no longer follows from quantity and price is not reliable: the
    // calculated amounts are withdrawn, not left at their old values.
    await saveInvoiceItem(
      owner,
      OWNER,
      lineInput(SOURCE.derivedBoth, {
        id: added.id,
        sku: "D-3",
        description: "Added line",
        quantity: 2,
        unitPrice: 4.35,
        totalPrice: 5,
      }),
    );
    let now = await state();
    assert.deepEqual(
      [
        now.invoice.subtotal,
        now.invoice.invoice_total,
        now.invoice.total_amount,
        now.invoice.total,
      ],
      [null, null, null, null],
    );
    assert.deepEqual(now.header.subtotal, {
      value: null,
      confidence: 0,
      source: "Derived",
      reviewed: false,
    });
    assert.deepEqual(now.header.total, {
      value: null,
      confidence: 0,
      source: "Derived",
      reviewed: false,
    });
    // Tax and shipping were printed and are untouched throughout.
    assert.deepEqual([now.invoice.tax_amount, now.invoice.shipping_amount], [2, 5]);
    await saveInvoiceItem(
      owner,
      OWNER,
      lineInput(SOURCE.derivedBoth, {
        id: added.id,
        sku: "D-3",
        description: "Added line",
        quantity: 2,
        unitPrice: 4.35,
        totalPrice: 8.7,
      }),
    );
    await expectCalculated(39, 46);

    // A write that bypasses the application (straight to the table as the owner) cannot
    // leave a stale amount either: the database withdraws it in the same statement.
    const { error } = await owner
      .from("invoice_items")
      .update({ quantity: 1, total_price: 4.35 })
      .eq("id", added.id);
    assert.equal(error, null);
    now = await state();
    assert.deepEqual([now.invoice.subtotal, now.invoice.total_amount], [null, null]);
    assert.equal(now.header.subtotal.value, null);
    assert.equal(now.header.total.value, null);
    assert.equal(await refreshDerivedInvoiceTotals(owner, ORG, SOURCE.derivedBoth), true);
    await expectCalculated(34.65, 41.65);
    // A change that does not touch amounts leaves the calculated amounts alone.
    const { error: renameError } = await owner
      .from("invoice_items")
      .update({ description: "Renamed line" })
      .eq("id", added.id);
    assert.equal(renameError, null);
    await expectCalculated(34.65, 41.65);

    // Header edits: tax feeds the calculated total. The owner changes tax and saves the form
    // with the calculated amounts as shown. (saveInvoiceHeaderFn writes the header, then makes
    // this call.)
    const { error: taxError } = await owner
      .from("invoices")
      .update({ tax_amount: 3 })
      .eq("id", INVOICE.derivedBoth);
    assert.equal(taxError, null);
    await refreshDerivedInvoiceTotals(owner, ORG, SOURCE.derivedBoth, {
      subtotal: 34.65,
      total: 41.65,
    });
    await expectCalculated(34.65, 42.65);
    // The owner types a different subtotal: it becomes the owner's amount and is no longer
    // recalculated. The calculated total cannot be reconciled with it and is withdrawn.
    await owner.from("invoices").update({ subtotal: 99 }).eq("id", INVOICE.derivedBoth);
    await refreshDerivedInvoiceTotals(owner, ORG, SOURCE.derivedBoth, {
      subtotal: 99,
      total: 42.65,
    });
    now = await state();
    assert.equal(now.invoice.subtotal, 99);
    assert.deepEqual(now.header.subtotal, {
      value: 99,
      confidence: 100,
      source: "User",
      reviewed: true,
    });
    assert.equal(now.invoice.total_amount, null);
    assert.equal(now.header.total.source, "Derived");
    assert.equal(now.needsReview, true);
    await deleteInvoiceItem(
      owner,
      OWNER,
      itemKeyInput.parse({ organizationId: ORG, sourceFileId: SOURCE.derivedBoth, id: added.id }),
    );
    assert.equal((await state()).invoice.subtotal, 99);
  },
);

test(
  "a printed total is never recalculated; a calculated subtotal beside it is withdrawn when the lines disagree",
  { skip },
  async () => {
    const state = () => totals(INVOICE.derivedSubtotal, SOURCE.derivedSubtotal);
    await saveInvoiceItem(
      owner,
      OWNER,
      lineInput(SOURCE.derivedSubtotal, {
        id: id("861"),
        sku: "S-1",
        description: "Derived subtotal, line one",
        quantity: 3,
        unitPrice: 10,
        totalPrice: 30,
      }),
    );
    let now = await state();
    // Lines now sum to 40; the document says 37 in total. The printed total stands, the
    // calculated subtotal is withdrawn rather than recalculated to 40, and review is flagged.
    assert.deepEqual(
      [now.invoice.invoice_total, now.invoice.total_amount, now.invoice.total],
      [37, 37, 37],
    );
    assert.deepEqual(now.header.total, {
      value: 37,
      confidence: 94,
      source: "Parser",
      reviewed: false,
    });
    assert.equal(now.invoice.subtotal, null);
    assert.deepEqual(now.header.subtotal, {
      value: null,
      confidence: 0,
      source: "Derived",
      reviewed: false,
    });
    assert.equal(now.needsReview, true);
    // Restoring the line restores the calculation.
    await saveInvoiceItem(
      owner,
      OWNER,
      lineInput(SOURCE.derivedSubtotal, {
        id: id("861"),
        sku: "S-1",
        description: "Derived subtotal, line one",
        quantity: 2,
        unitPrice: 10,
        totalPrice: 20,
      }),
    );
    now = await state();
    assert.equal(now.invoice.subtotal, 30);
    assert.deepEqual(now.header.subtotal, {
      value: 30,
      confidence: 60,
      source: "Derived",
      reviewed: false,
    });
    assert.equal(now.invoice.total_amount, 37);
    assert.equal(now.needsReview, false);
  },
);

test("printed subtotal and total are untouched by any line change", { skip }, async () => {
  const state = () => totals(INVOICE.printed, SOURCE.printed);
  const original = await state();
  await saveInvoiceItem(
    owner,
    OWNER,
    lineInput(SOURCE.printed, {
      id: id("871"),
      sku: "P-1",
      description: "Printed totals, line one",
      quantity: 5,
      unitPrice: 10,
      totalPrice: 50,
    }),
  );
  await deleteInvoiceItem(
    owner,
    OWNER,
    itemKeyInput.parse({ organizationId: ORG, sourceFileId: SOURCE.printed, id: id("872") }),
  );
  await saveInvoiceItem(
    owner,
    OWNER,
    lineInput(SOURCE.printed, {
      sku: "P-3",
      description: "Added line",
      quantity: 1,
      unitPrice: 7,
      totalPrice: 7,
    }),
  );
  const { error } = await owner
    .from("invoice_items")
    .update({ total_price: 1 })
    .eq("id", id("871"));
  assert.equal(error, null);
  assert.equal(await refreshDerivedInvoiceTotals(owner, ORG, SOURCE.printed), false);
  assert.deepEqual(await state(), original);
  assert.deepEqual(
    [
      original.invoice.subtotal,
      original.invoice.total_amount,
      original.header.subtotal.source,
      original.header.total.source,
    ],
    [30, 37, "Parser", "Parser"],
  );
});

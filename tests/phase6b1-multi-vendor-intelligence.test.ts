// Phase 6B.1 Multi-Vendor Intelligence: wording, response contracts, the data layer, the
// rendered sections, banned terminology, deep links and the migration's static guarantees.
import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import ts from "typescript";
import { createElement, type ComponentType } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import {
  SEVERAL_SKUS_TEXT,
  detailSchema,
  differenceText,
  lastPurchasedText,
  listSchema,
  lowerComparableText,
  priceSearchSchema,
  recencyText,
  requestContextSchema,
  sameSkuChangeText,
  sourceLabel,
  summarySchema,
  type PriceEvidence,
  type PriceList,
  type PriceListRow,
  type PriceSummary,
  type ProductVendorHistory,
} from "../src/price-intelligence/vendor-intelligence.ts";
import {
  getPriceIntelligenceSummary,
  getProductVendorHistory,
  getSupplyRequestPriceContext,
  listPriceIntelligenceProducts,
} from "../src/price-intelligence/data.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const migration = read(
  "../supabase/migrations/20261123120000_phase6b1_multi_vendor_intelligence.sql",
);
const migrationCode = migration.replace(/--[^\n]*/g, "");
const behavior = read("../supabase/tests/phase6b1_multi_vendor_behavior.sql");

const sectionsPath = new URL(
  "../src/components/price-intelligence/PriceIntelligenceSections.tsx",
  import.meta.url,
);
const compiled = ts.transpileModule(readFileSync(sectionsPath, "utf8"), {
  compilerOptions: { jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.CommonJS },
}).outputText;
const ui: Record<string, ComponentType<Record<string, unknown>>> = {};
new Function("require", "exports", compiled)(createRequire(sectionsPath), ui);
const html = (component: string, props: Record<string, unknown>) =>
  renderToStaticMarkup(createElement(ui[component], props));

const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const org = uuid(1);

const evidence = (overrides: Partial<PriceEvidence> = {}): PriceEvidence => ({
  observationId: uuid(901),
  vendorId: uuid(301),
  vendorName: "Henry Schein",
  vendorProductId: uuid(401),
  sku: "398-0145",
  documentType: "INVOICE",
  documentNumber: "52103732",
  invoiceNumber: "52103732",
  dateBasis: "invoice_date",
  purchaseDate: "2026-11-13",
  ageDays: 10,
  recency: "recent",
  quantity: 3,
  unitOfMeasure: "BX",
  unitValid: true,
  packageSize: null,
  price: 6.23,
  lineAmount: 18.69,
  invoiceId: uuid(501),
  invoiceItemId: uuid(601),
  lineNumber: 1,
  ...overrides,
});

const row = (overrides: Partial<PriceListRow> = {}): PriceListRow => ({
  productId: uuid(201),
  productName: "Ammex Black PF Nitrile Glove X-Large",
  state: "insufficient_identity",
  stale: false,
  identityIssue: "multiple_skus",
  observationCount: 2,
  vendorsObserved: 1,
  lastPurchase: evidence(),
  priorSameSku: null,
  changeAmount: null,
  changePercent: null,
  lowestComparable: null,
  comparableAlternative: null,
  differencePerUnit: null,
  comparableVendorCount: 0,
  comparisonWithheld: null,
  signals: [],
  ...overrides,
});

const summary = (): PriceSummary => ({
  organizationId: org,
  currencyCode: "USD",
  asOf: "2026-11-23",
  productCount: 74,
  observationCount: 81,
  vendorCount: 1,
  staleCount: 40,
  states: {
    insufficient_identity: 5,
    one_purchase: 67,
    single_vendor: 2,
    comparable: 0,
    missing_package_details: 0,
    incompatible_units: 0,
  },
  signals: {
    lower_comparable_price_other_vendor: 0,
    same_sku_price_increased: 0,
    price_data_stale: 40,
    package_details_missing: 0,
    multiple_vendors_not_comparable: 0,
  },
  vendors: [{ vendorId: uuid(301), vendorName: "Henry Schein", lastPurchaseProductCount: 74 }],
  coverage: {
    postedObservationCount: 81,
    excludedNonUsdCount: 0,
    excludedMissingPriceCount: 0,
    orderConfirmationCount: 6,
    datedByPostingCount: 6,
    missingPackageCount: 81,
    missingOrMalformedUnitCount: 1,
  },
});

const list = (rows: PriceListRow[] = [row()]): PriceList => ({
  organizationId: org,
  currencyCode: "USD",
  asOf: "2026-11-23",
  sort: "recent",
  filter: "all",
  vendorId: null,
  rows,
  scanned: rows.length,
  nextCursor: null,
  exhausted: true,
});

const detail = (overrides: Partial<ProductVendorHistory> = {}): ProductVendorHistory => ({
  organizationId: org,
  productId: uuid(201),
  productName: "Ammex Black PF Nitrile Glove X-Large",
  currencyCode: "USD",
  asOf: "2026-11-23",
  viewerIsOwner: true,
  canOpenSourceDocument: true,
  state: "insufficient_identity",
  stale: false,
  identityIssue: "multiple_skus",
  observationCount: 2,
  vendorsObserved: 1,
  lastPurchase: evidence(),
  priorSameSku: null,
  changeAmount: null,
  changePercent: null,
  lowestComparable: null,
  comparableAlternative: null,
  differencePerUnit: null,
  comparableVendorCount: 0,
  comparisonWithheld: null,
  signals: [],
  vendors: [
    {
      vendorId: uuid(301),
      vendorName: "Henry Schein",
      skus: [
        { sku: "398-0144", observed: true, mapped: true },
        { sku: "398-0145", observed: true, mapped: true },
      ],
      lastPurchase: {
        observationId: uuid(901),
        sku: "398-0145",
        price: 6.23,
        unitOfMeasure: "BX",
        unitValid: true,
        packageSize: null,
        purchaseDate: "2026-11-13",
        dateBasis: "invoice_date",
        ageDays: 10,
        recency: "recent",
        documentType: "INVOICE",
        documentNumber: "52103732",
        invoiceId: uuid(501),
        lineNumber: 1,
      },
      priorSameSku: null,
      purchaseCount: 2,
      firstPurchaseDate: "2026-11-13",
      lastPurchaseDate: "2026-11-13",
      comparisonStatus: "last_purchase",
      checks: null,
    },
  ],
  vendorLimit: 25,
  identity: {
    issue: "multiple_skus",
    skus: [
      {
        vendorId: uuid(301),
        vendorName: "Henry Schein",
        sku: "398-0144",
        observed: true,
        mapped: true,
      },
      {
        vendorId: uuid(301),
        vendorName: "Henry Schein",
        sku: "398-0145",
        observed: true,
        mapped: true,
      },
    ],
  },
  observations: [
    {
      observationId: uuid(901),
      vendorId: uuid(301),
      vendorName: "Henry Schein",
      sku: "398-0145",
      documentType: "INVOICE",
      documentNumber: "52103732",
      dateBasis: "invoice_date",
      purchaseDate: "2026-11-13",
      ageDays: 10,
      recency: "recent",
      quantity: 3,
      unitOfMeasure: "BX",
      unitValid: true,
      packageSize: null,
      price: 6.23,
      lineAmount: 18.69,
      invoiceId: uuid(501),
      invoiceItemId: uuid(601),
      lineNumber: 1,
    },
  ],
  nextCursor: null,
  coverage: { postedObservationCount: 2, excludedNonUsdCount: 0, excludedMissingPriceCount: 0 },
  ...overrides,
});

// ---------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------

test("recency wording: none to 90 days, months from 91, Stale after 180", () => {
  assert.equal(recencyText(90, "recent"), null);
  assert.equal(recencyText(91, "aging"), "Purchased 3 months ago");
  assert.equal(recencyText(180, "aging"), "Purchased 6 months ago");
  assert.equal(recencyText(181, "stale"), "Stale");
});

test("same-SKU change wording is history, never savings", () => {
  assert.equal(sameSkuChangeText(1, 9.0909), "Price increased +$1.00 (+9.1%)");
  assert.equal(sameSkuChangeText(-5, -20), "Price decreased −$5.00 (−20.0%)");
  assert.equal(sameSkuChangeText(0, 0), "No change");
  assert.equal(sameSkuChangeText(null, null), null);
  assert.equal(differenceText(1, "bx"), "+$1.00 per bx");
  assert.equal(differenceText(-1, "bx"), "−$1.00 per bx");
  assert.equal(differenceText(0, null), "Same price per unit");
});

test("source labels always name the document type and date basis", () => {
  assert.equal(
    sourceLabel("ORDER_CONFIRMATION", "posting_date"),
    "Order confirmation · Posting date",
  );
  assert.equal(sourceLabel("INVOICE", "invoice_date"), "Invoice · Invoice date");
  assert.equal(
    sourceLabel("UNKNOWN", "invoice_date"),
    "Document type not classified · Invoice date",
  );
});

test("request-review lines use the locked wording", () => {
  const p = {
    vendorName: "Henry Schein",
    price: 6.23,
    unitOfMeasure: "BX",
    purchaseDate: "2026-01-15",
  };
  assert.equal(
    lastPurchasedText(p),
    "Last purchased from Henry Schein at $6.23/BX on Jan 15, 2026",
  );
  assert.equal(
    lowerComparableText({ ...p, vendorName: "Vendor B", price: 9, unitOfMeasure: "bx" }),
    "Lower comparable purchase price from Vendor B: $9.00/bx on Jan 15, 2026",
  );
  assert.equal(SEVERAL_SKUS_TEXT, "Several SKUs recorded — view purchase history");
});

// ---------------------------------------------------------------------------
// Contracts
// ---------------------------------------------------------------------------

test("response schemas are strict and reject savings or unknown fields", () => {
  assert.equal(listSchema.safeParse(list()).success, true);
  assert.equal(summarySchema.safeParse(summary()).success, true);
  assert.equal(detailSchema.safeParse(detail()).success, true);
  assert.equal(
    listSchema.safeParse(list([{ ...row(), unitSavings: 1 } as PriceListRow])).success,
    false,
  );
  assert.equal(listSchema.safeParse(list([row({ state: "best_price" as never })])).success, false);
  assert.equal(detailSchema.safeParse({ ...detail(), recommendedVendor: uuid(1) }).success, false);
  assert.equal(
    requestContextSchema.safeParse({
      organizationId: org,
      requestId: uuid(701),
      currencyCode: "USD",
      asOf: "2026-11-23",
      items: [
        {
          itemId: uuid(711),
          productId: null,
          status: "unresolved",
          lastPurchase: null,
          lowerComparable: null,
        },
      ],
    }).success,
    true,
  );
});

test("deep-link search accepts UUIDs and drops anything else", () => {
  assert.equal(priceSearchSchema.parse({ priceProduct: uuid(201) }).priceProduct, uuid(201));
  const malformed = priceSearchSchema.parse({
    priceProduct: "1; drop table",
    priceInventoryItem: "x",
  });
  assert.equal(malformed.priceProduct, undefined);
  assert.equal(malformed.priceInventoryItem, undefined);
  assert.equal(
    priceSearchSchema.parse({ priceInventoryItem: uuid(601) }).priceInventoryItem,
    uuid(601),
  );
});

// ---------------------------------------------------------------------------
// Data layer
// ---------------------------------------------------------------------------

function mockDb(
  role: string | null = "admin",
  payload: unknown = list(),
  error: { code?: string; message: string } | null = null,
) {
  const calls: unknown[][] = [];
  const builder: Record<string, (...args: unknown[]) => unknown> = {
    select: () => builder,
    eq: (...args: unknown[]) => {
      calls.push(["eq", ...args]);
      return builder;
    },
    maybeSingle: async () => ({ data: role ? { role } : null, error: null }),
  };
  const client = {
    from: (table: string) => {
      calls.push(["from", table]);
      return builder;
    },
    rpc: async (name: string, args: unknown) => {
      calls.push(["rpc", name, args]);
      return { data: payload, error };
    },
  };
  return { db: client as unknown as SupabaseClient<Database>, calls };
}

test("data functions check membership before any RPC and call the 6B.1 RPCs only", async () => {
  const listed = mockDb("owner", list());
  await listPriceIntelligenceProducts(listed.db, "user", org, {
    sort: "product",
    filter: "comparable",
    vendorId: null,
    cursor: null,
  });
  assert.deepEqual(listed.calls.at(-1), [
    "rpc",
    "list_price_intelligence_products",
    {
      _organization_id: org,
      _sort: "product",
      _filter: "comparable",
      _vendor_id: null,
      _cursor: null,
      _limit: 50,
    },
  ]);
  const summed = mockDb("admin", summary());
  await getPriceIntelligenceSummary(summed.db, "user", org);
  assert.deepEqual(summed.calls.at(-1), [
    "rpc",
    "get_price_intelligence_summary",
    { _organization_id: org },
  ]);
  const detailed = mockDb("admin", detail());
  await getProductVendorHistory(detailed.db, "user", org, { inventoryItemId: uuid(601) });
  assert.deepEqual(detailed.calls.at(-1), [
    "rpc",
    "get_product_vendor_price_history",
    {
      _organization_id: org,
      _product_id: null,
      _inventory_item_id: uuid(601),
      _cursor: null,
      _limit: 50,
    },
  ]);
  for (const role of ["staff", null]) {
    const denied = mockDb(role);
    await assert.rejects(() => getPriceIntelligenceSummary(denied.db, "user", org), /Forbidden/);
    await assert.rejects(
      () => getSupplyRequestPriceContext(denied.db, "user", org, uuid(701)),
      /Forbidden/,
    );
    assert.equal(
      denied.calls.some((c) => c[0] === "rpc"),
      false,
    );
  }
});

test("data functions surface refusals and reject malformed payloads", async () => {
  await assert.rejects(
    () =>
      getPriceIntelligenceSummary(
        mockDb("owner", null, { code: "42501", message: "x" }).db,
        "user",
        org,
      ),
    /Forbidden/,
  );
  await assert.rejects(
    () =>
      getProductVendorHistory(
        mockDb("owner", null, { code: "P0002", message: "x" }).db,
        "user",
        org,
        { productId: uuid(2) },
      ),
    /no purchase history/,
  );
  await assert.rejects(() =>
    getPriceIntelligenceSummary(mockDb("owner", { productCount: "x" }).db, "user", org),
  );
});

// ---------------------------------------------------------------------------
// Rendered sections
// ---------------------------------------------------------------------------

test("the list shows the locked columns, filters and Load more, never savings", () => {
  const rendered = html("PriceIntelligenceList", {
    summary: summary(),
    rows: [
      row(),
      row({
        productId: uuid(202),
        productName: "Leukotape P",
        state: "single_vendor",
        identityIssue: null,
        changeAmount: 0,
        changePercent: 0,
        priorSameSku: evidence({ price: 7.29 }),
        lastPurchase: evidence({
          price: 7.29,
          unitOfMeasure: "RL",
          ageDays: 151,
          recency: "aging",
        }),
      }),
    ],
    filter: "all",
    sort: "recent",
    vendorId: null,
    canLoadMore: true,
  });
  for (const text of [
    "Product",
    "Last purchase vendor",
    "Last purchase price",
    "Vendors observed",
    "Same-SKU change",
    "Signal",
    "Status",
    "Insufficient identity",
    "Single vendor observed",
    "No change",
    "Purchased 5 months ago",
    "SKU 398-0145 · Invoice · Invoice date",
    "$6.23/BX",
    "Load more",
    "Lower comparable price elsewhere",
    "Same-SKU price increased",
  ])
    assert.ok(rendered.includes(text), text);
  assert.doesNotMatch(rendered, /saving|best price|current price|recommended/i);
});

test("order confirmations are labelled with their posting date", () => {
  const rendered = html("PriceIntelligenceList", {
    rows: [
      row({
        lastPurchase: evidence({ documentType: "ORDER_CONFIRMATION", dateBasis: "posting_date" }),
      }),
    ],
    filter: "all",
    sort: "recent",
    vendorId: null,
    canLoadMore: false,
  });
  assert.match(rendered, /Order confirmation · Posting date/);
  assert.doesNotMatch(rendered, /Load more/);
});

test("insufficient identity lists the SKUs and says prices are not compared", () => {
  const rendered = html("ProductVendorHistoryView", {
    history: detail(),
    observations: detail().observations,
    canLoadMore: false,
    onOpenDocument: () => {},
  });
  assert.match(
    rendered,
    /Several SKUs from one vendor are recorded under this product\. Prices\s+are not compared\./,
  );
  assert.match(rendered, /SKU 398-0144/);
  assert.match(rendered, /SKU 398-0145/);
  assert.match(rendered, /Not compared/);
  assert.doesNotMatch(rendered, /Lowest comparable purchase price/);
  assert.match(rendered, /Not recorded/);
  assert.match(rendered, /<button[^>]*>52103732<\/button>/);
});

test("admins see the source reference but no document action", () => {
  const admin = detail({ viewerIsOwner: false, canOpenSourceDocument: false });
  const rendered = html("ProductVendorHistoryView", {
    history: admin,
    observations: admin.observations,
    canLoadMore: false,
    onOpenDocument: () => {},
  });
  assert.match(rendered, /52103732/);
  assert.doesNotMatch(rendered, /<button[^>]*>52103732<\/button>/);
  assert.match(rendered, /Source documents can be opened by the organization owner/);
});

test("comparable history shows the lowest comparable purchase price and the difference", () => {
  const alt = evidence({
    vendorId: uuid(302),
    vendorName: "Vendor B",
    price: 9,
    unitOfMeasure: "bx",
    packageSize: "12/box",
  });
  const history = detail({
    state: "comparable",
    identity: null,
    identityIssue: null,
    vendorsObserved: 2,
    lastPurchase: evidence({ price: 10, unitOfMeasure: "bx", packageSize: "12/box" }),
    lowestComparable: alt,
    comparableAlternative: alt,
    differencePerUnit: 1,
    comparableVendorCount: 2,
    signals: ["lower_comparable_price_other_vendor"],
  });
  const rendered = html("ProductVendorHistoryView", {
    history,
    observations: [],
    canLoadMore: false,
  });
  assert.match(rendered, /Lowest comparable purchase price/);
  assert.match(rendered, /\$9\.00\/bx/);
  assert.match(rendered, /Price difference per comparable invoiced unit/);
  assert.match(rendered, /\+\$1\.00 per bx/);
  assert.match(rendered, /Lower recent comparable purchase price from another vendor/);
});

test("a structurally comparable stale pair is Comparable + Stale with numbers withheld", () => {
  const history = detail({
    state: "comparable",
    stale: true,
    identity: null,
    identityIssue: null,
    comparisonWithheld: "stale",
    signals: ["price_data_stale"],
  });
  const rendered = html("ProductVendorHistoryView", {
    history,
    observations: [],
    canLoadMore: false,
  });
  assert.match(rendered, /Comparable/);
  assert.match(rendered, /data-marker="stale"/);
  assert.match(rendered, /Withheld: a comparable purchase is more than 180 days old/);
  assert.doesNotMatch(rendered, /Price difference per comparable invoiced unit/);
});

test("a product with no purchase history says so", () => {
  const rendered = html("ProductVendorHistoryView", {
    history: detail({
      state: null,
      lastPurchase: null,
      observations: [],
      vendors: [],
      identity: null,
    }),
    observations: [],
    canLoadMore: false,
  });
  assert.match(rendered, /No purchase history/);
});

test("request review shows a read-only line per resolvable item", () => {
  const purchase = {
    observationId: uuid(901),
    vendorId: uuid(301),
    vendorName: "Henry Schein",
    sku: "L-1",
    price: 10,
    unitOfMeasure: "bx",
    packageSize: "12/box",
    purchaseDate: "2026-11-03",
    dateBasis: "invoice_date" as const,
    recency: "recent" as const,
    documentType: "INVOICE",
    documentNumber: "INV-1",
  };
  const withLower = html("RequestItemPriceContext", {
    item: {
      itemId: uuid(711),
      productId: uuid(201),
      status: "last_purchase",
      lastPurchase: purchase,
      lowerComparable: {
        ...purchase,
        observationId: undefined,
        recency: undefined,
        vendorName: "Vendor B",
        price: 9,
      },
    },
  });
  assert.match(withLower, /Last purchased from Henry Schein at \$10\.00\/bx on Nov 3, 2026/);
  assert.match(
    withLower,
    /Lower comparable purchase price from Vendor B: \$9\.00\/bx on Nov 3, 2026/,
  );
  assert.match(withLower, new RegExp(`href="/budget-purchasing\\?priceProduct=${uuid(201)}"`));
  const several = html("RequestItemPriceContext", {
    item: {
      itemId: uuid(713),
      productId: uuid(201),
      status: "several_skus",
      lastPurchase: null,
      lowerComparable: null,
    },
  });
  assert.match(several, /Several SKUs recorded — view purchase history/);
  assert.doesNotMatch(several, /\$/);
  for (const status of ["unresolved", "no_history"])
    assert.equal(
      html("RequestItemPriceContext", {
        item: {
          itemId: uuid(714),
          productId: null,
          status,
          lastPurchase: null,
          lowerComparable: null,
        },
      }),
      "",
    );
});

// ---------------------------------------------------------------------------
// Banned terminology, removed savings UX, integrations
// ---------------------------------------------------------------------------

const userFacing = [
  "../src/components/price-intelligence/PriceIntelligenceSections.tsx",
  "../src/components/price-intelligence/PriceIntelligencePanel.tsx",
  "../src/components/price-intelligence/ProductVendorHistory.tsx",
  "../src/price-intelligence/vendor-intelligence.ts",
  "../src/components/budget-purchasing/CommandCenterSections.tsx",
  "../src/components/budget-purchasing/BudgetPurchasingPage.tsx",
  "../src/budget-purchasing/command-center.ts",
  "../src/components/catalog/CatalogAdminPage.tsx",
  "../src/components/admin/supply-requests/AdminRequestDetail.tsx",
  "../src/components/inventory/workspace/ReplenishmentRowCard.tsx",
];

test("banned live-market and savings terms never return to Price Intelligence surfaces", () => {
  const banned =
    /current price|current vendor|current pricing|best price|market price|savings opportunit|unit savings|potential unit savings|recommended vendor|largest unit savings|90-day average|isSavingsOpportunity|bestAlternative/i;
  for (const path of userFacing) assert.doesNotMatch(read(path), banned, path);
});

test("Budget & Purchasing uses the keyset list, and the deep link is validated", () => {
  const page = read("../src/components/budget-purchasing/BudgetPurchasingPage.tsx");
  assert.match(page, /<PriceIntelligencePanel/);
  assert.doesNotMatch(page, /PriceIntelligenceTable|PriceEvidence|getPriceIntelligenceOverviewFn/);
  const route = read("../src/routes/_authenticated/budget-purchasing.tsx");
  assert.match(route, /validateSearch: priceSearchSchema/);
  const panel = read("../src/components/price-intelligence/PriceIntelligencePanel.tsx");
  assert.match(panel, /useInfiniteQuery/);
  assert.match(panel, /page\.exhausted \? undefined : page\.nextCursor/);
  assert.doesNotMatch(panel, /offset|productLimit|500/);
});

test("request review and Replenishment only link; neither assigns, orders or changes stock", () => {
  const route = read("../src/routes/_authenticated/supply-requests.tsx");
  assert.match(route, /getSupplyRequestPriceContextFn/);
  assert.match(route, /priceContext=\{priceContext\.data\}/);
  const card = read("../src/components/inventory/workspace/ReplenishmentRowCard.tsx");
  assert.match(card, /row\.category === "needs_purchasing"/);
  assert.match(card, /search=\{\{ priceInventoryItem: row\.inventoryItemId \}\}/);
  assert.match(card, /View purchase history/);
  const functions = read("../src/lib/price-intelligence.functions.ts");
  const data = read("../src/price-intelligence/data.ts");
  assert.doesNotMatch(functions + data, /\.insert\(|\.update\(|\.delete\(|service_role/);
});

test("staff never reach Price Intelligence", () => {
  for (const path of [
    "../src/components/app/StaffAppShell.tsx",
    "../src/routes/_authenticated/staff/request.tsx",
    "../src/routes/_authenticated/staff/requests.tsx",
  ])
    assert.doesNotMatch(read(path), /price-intelligence|PriceIntelligence|ProductVendorHistory/);
});

// ---------------------------------------------------------------------------
// Migration static guarantees (behaviour is proven by the SQL suite)
// ---------------------------------------------------------------------------

test("the migration adds no table, materialized view or write path", () => {
  assert.doesNotMatch(migrationCode, /CREATE (TABLE|MATERIALIZED VIEW|TEMP)/i);
  assert.doesNotMatch(migrationCode, /\b(INSERT INTO|UPDATE public\.|DELETE FROM)\b/i);
  assert.match(
    migration,
    /CREATE INDEX inventory_price_history_product_vendor_order_idx\s+ON public\.inventory_price_history \(\s*organization_id, product_id, vendor_id, purchase_date DESC, created_at DESC, id DESC\s*\)/,
  );
});

test("internal helpers are revoked from every client role; RPCs are owner/admin only", () => {
  for (const helper of [
    "price_unit_key(text)",
    "price_unit_is_valid(text)",
    "price_recency(date, date)",
    "price_catalog_unit_agrees(numeric, text, text)",
    "price_package_agreement(text, text, text, uuid, uuid)",
    "price_observation_rows(uuid, uuid[])",
    "price_product_anchors(uuid)",
    "price_product_state(uuid, uuid[], date)",
  ])
    assert.ok(
      migration.includes(
        `REVOKE ALL ON FUNCTION public.${helper} FROM PUBLIC, anon, authenticated, service_role;`,
      ),
      helper,
    );
  assert.equal(
    (migrationCode.match(/financial_assert_access\(_organization_id, false\)/g) ?? []).length,
    4,
  );
  assert.equal(
    (migrationCode.match(/is_org_admin\(_organization_id, auth\.uid\(\)\)/g) ?? []).length,
    2,
  );
});

test("old RPCs keep their keys and report no savings or average", () => {
  assert.match(migration, /'recentAverage', NULL,/);
  assert.match(migration, /'unitSavings', NULL/);
  assert.match(migration, /'excludedUnknownCurrencyCount', 0,/);
});

test("the SQL suite covers the production regressions and every rule", () => {
  for (const text of [
    "Ammex Large/X-Large: insufficient identity",
    "Eco-Flex colors: insufficient identity",
    "Leukotape: no change",
    "Mediproxen: dated by posting",
    "Protex: EA) never compares to EA",
    "two mapped SKUs, one purchased: insufficient identity",
    "catalog 200/box against an invoiced bt",
    "structurally comparable stale pair stays Comparable",
    "alternative at 181 days never ranks",
    "anchor at 181 days does not",
    "no duplicates across pages",
    "old overview: Ammex false increase gone",
    "admins cannot open source documents",
    "no business row changed after every call",
  ])
    assert.ok(behavior.includes(text), text);
});

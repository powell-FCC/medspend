import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import ts from "typescript";
import { createElement, type ComponentType } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import { renderToStaticMarkup } from "react-dom/server";
import {
  COMBINED_SCOPE,
  SETTLEMENT_ANCHOR,
  attentionItems,
  requestReviewLink,
  budgetStatus,
  budgetsOverlap,
  daysAgo,
  defaultScopeId,
  filterPriceRows,
  isPriceIncrease,
  isSavingsOpportunity,
  overviewSchema,
  priceOverviewSchema,
  scopeOptions,
  sortPriceRows,
  summarizeScope,
  utilizationRatio,
  utilizationSegments,
  type BudgetRow,
  type CommandCenterOverview,
  type PriceOverview,
  type PriceRow,
} from "../src/budget-purchasing/command-center.ts";
import {
  getBudgetLineage,
  getCommandCenterOverview,
  getPriceIntelligenceOverview,
} from "../src/budget-purchasing/data.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const migration = read(
  "../supabase/migrations/20261015120000_budget_purchasing_command_center.sql",
);
const behavior = read("../supabase/tests/budget_purchasing_command_center_behavior.sql");

// Render the real presentational sections with the existing Node test runner.
const sectionsPath = new URL(
  "../src/components/budget-purchasing/CommandCenterSections.tsx",
  import.meta.url,
);
const compiled = ts.transpileModule(readFileSync(sectionsPath, "utf8"), {
  compilerOptions: { jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.CommonJS },
}).outputText;
const ui: Record<string, ComponentType<Record<string, unknown>>> = {};
new Function("require", "exports", compiled)(createRequire(sectionsPath), ui);
const html = (component: string, props: Record<string, unknown>) =>
  renderToStaticMarkup(createElement(ui[component], props));

const org = "00000000-0000-4000-8000-000000000001";
const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const today = "2027-03-15";

const budget = (n: number, overrides: Partial<BudgetRow> = {}): BudgetRow => ({
  budgetId: uuid(100 + n),
  budgetName: `Budget ${n}`,
  periodStart: "2027-01-01",
  periodEnd: "2027-06-30",
  budgetAmount: 1000,
  actualSpend: 250,
  committedSpend: 70,
  availableAmount: 680,
  postedInvoiceCount: 2,
  activeCommitmentCount: 2,
  incompleteCommitmentCount: 0,
  settlementCandidateCount: 0,
  settlementCandidateAmount: 0,
  ...overrides,
});
const h1 = budget(1, { budgetName: "H1 2027" });
const h2 = budget(2, {
  budgetName: "H2 2027",
  periodStart: "2027-07-01",
  periodEnd: "2027-12-31",
  budgetAmount: 500,
  actualSpend: 100,
  committedSpend: 10,
  availableAmount: 390,
  postedInvoiceCount: 1,
  activeCommitmentCount: 1,
  incompleteCommitmentCount: 1,
});

const overview = (overrides: Partial<CommandCenterOverview> = {}): CommandCenterOverview => ({
  organizationId: org,
  viewerIsOwner: true,
  budgets: [h1, h2],
  attention: {
    awaitingApprovalCount: 2,
    commitmentsToSettleCount: 1,
    commitmentsToSettleAmount: 40,
    unpricedCommitmentCount: 1,
    invoiceReviewCount: 3,
  },
  settlementCandidates: [
    {
      requestId: uuid(602),
      requestStatus: "completed",
      committedAt: "2027-03-01T12:00:00Z",
      amount: 40,
      pricingStatus: "fully_priced",
      itemCount: 1,
      itemLabel: "Ankle brace",
    },
  ],
  settlementCandidateLimit: 25,
  recentPurchases: [
    {
      invoiceId: uuid(900),
      sourceFileId: uuid(901),
      vendorName: "Vendor A",
      invoiceNumber: "H1-200",
      spendDate: "2027-02-01",
      amount: 200,
    },
  ],
  ...overrides,
});

const priceRow = (n: number, overrides: Partial<PriceRow> = {}): PriceRow => ({
  productId: uuid(400 + n),
  productName: `Product ${n}`,
  comparability: "comparable",
  current: {
    observationId: uuid(500 + n),
    vendorId: uuid(301),
    vendorName: "Vendor A",
    price: 118,
    purchaseDate: "2027-02-25",
    invoiceId: uuid(600 + n),
    invoiceNumber: `INV-${n}`,
    quantity: 3,
    unitOfMeasure: "case",
    packageSize: "case of 12",
  },
  previous: {
    price: 104,
    purchaseDate: "2027-01-10",
    invoiceId: uuid(700 + n),
    invoiceNumber: `PREV-${n}`,
  },
  absoluteChange: 14,
  percentChange: 13.461538,
  recentAverage: {
    average: 111,
    observationCount: 2,
    windowStart: "2026-11-28",
    windowEnd: "2027-02-25",
  },
  bestAlternative: {
    vendorId: uuid(302),
    vendorName: "Vendor B",
    price: 106.2,
    purchaseDate: "2027-01-20",
    invoiceId: uuid(800 + n),
    invoiceNumber: `ALT-${n}`,
    unitOfMeasure: "case",
    packageSize: "case of 12",
    comparableVendorCount: 1,
  },
  unitSavings: 11.8,
  ...overrides,
});
const tape = priceRow(1, { productName: "KT Tape" });
const gauze = priceRow(2, {
  productName: "Gauze",
  current: {
    ...priceRow(2).current,
    vendorId: uuid(302),
    vendorName: "Vendor B",
    price: 20,
    purchaseDate: "2027-03-01",
  },
  previous: { price: 25, purchaseDate: "2027-02-01", invoiceId: uuid(702), invoiceNumber: null },
  absoluteChange: -5,
  percentChange: -20,
  bestAlternative: null,
  unitSavings: null,
});
const wrap = priceRow(3, {
  productName: "Wrap",
  comparability: "missing_unit_of_measure",
  current: {
    ...priceRow(3).current,
    unitOfMeasure: null,
    packageSize: null,
    price: 5,
    purchaseDate: "2027-01-05",
  },
  previous: null,
  absoluteChange: null,
  percentChange: null,
  recentAverage: null,
  bestAlternative: null,
  unitSavings: null,
});
const ice = priceRow(4, {
  productName: "Ice",
  previous: null,
  absoluteChange: null,
  percentChange: null,
  current: { ...priceRow(4).current, price: 10 },
  bestAlternative: { ...priceRow(4).bestAlternative!, price: 12 },
  unitSavings: null,
});
const prices = (rows: PriceRow[] = [tape, gauze, wrap, ice]): PriceOverview => ({
  organizationId: org,
  currencyCode: "USD",
  averageWindowDays: 90,
  productLimit: 500,
  productCount: rows.length,
  rows,
});

// ---------------------------------------------------------------------------
// Financial summary
// ---------------------------------------------------------------------------

test("a single-budget scope uses the canonical per-budget figures unchanged", () => {
  const scope = summarizeScope([h1, h2], h1.budgetId)!;
  assert.equal(scope.actualSpend, 250);
  assert.equal(scope.committedSpend, 70);
  assert.equal(scope.availableAmount, 680);
  assert.equal(
    scope.availableAmount,
    scope.budgetAmount - scope.actualSpend - scope.committedSpend,
  );
  assert.deepEqual(scope.budgetIds, [h1.budgetId]);
});

test("non-overlapping budgets combine by summing; available = budget − spent − committed", () => {
  const options = scopeOptions([h1, h2]);
  assert.ok(
    options.some(
      (o) =>
        o.id === COMBINED_SCOPE && o.periodStart === "2027-01-01" && o.periodEnd === "2027-12-31",
    ),
  );
  const combined = summarizeScope([h1, h2], COMBINED_SCOPE)!;
  assert.equal(combined.budgetAmount, 1500);
  assert.equal(combined.actualSpend, 350);
  assert.equal(combined.committedSpend, 80);
  assert.equal(combined.availableAmount, 1070);
  assert.equal(combined.incompleteCommitmentCount, 1);
  assert.equal(combined.postedInvoiceCount, 3);
});

test("overlapping budgets are never combined, because shared spend would be counted twice", () => {
  const annual = budget(3, {
    budgetName: "FY 2027",
    periodStart: "2027-01-01",
    periodEnd: "2027-12-31",
    budgetAmount: 1500,
    actualSpend: 350,
    committedSpend: 80,
    availableAmount: 1070,
  });
  assert.equal(budgetsOverlap([h1, annual]), true);
  assert.equal(budgetsOverlap([h1, h2]), false);
  assert.equal(
    scopeOptions([h1, annual]).some((o) => o.id === COMBINED_SCOPE),
    false,
  );
  assert.equal(summarizeScope([h1, annual], COMBINED_SCOPE), null);
});

test("default scope prefers the budget covering today, then the latest start", () => {
  assert.equal(defaultScopeId([h2, h1], today), h1.budgetId);
  assert.equal(defaultScopeId([h1, h2], "2028-01-01"), h2.budgetId);
  assert.equal(defaultScopeId([], today), null);
});

test("no budget means no financial summary rather than zero-dollar health", () => {
  assert.equal(summarizeScope([], null), null);
  assert.equal(summarizeScope([h1], uuid(999)), null);
  const empty = html("NoBudgetState", { action: createElement("button", null, "Create budget") });
  assert.match(empty, /No active budget/);
  assert.match(empty, /Create budget/);
  assert.doesNotMatch(empty, /\$0\.00/);
});

test("utilization uses spent + committed; zero budgets yield no ratio and over-budget bars stay in bounds", () => {
  assert.equal(utilizationRatio(h1), 0.32);
  assert.equal(utilizationRatio({ ...h1, budgetAmount: 0 }), null);
  const segments = utilizationSegments(h1);
  assert.deepEqual(
    [segments.spent, segments.committed, segments.available].map((v) => Number(v.toFixed(6))),
    [25, 7, 68],
  );
  const over = utilizationSegments({
    budgetAmount: 100,
    actualSpend: 150,
    committedSpend: 50,
    availableAmount: -100,
  });
  assert.equal(over.spent + over.committed + over.available, 100);
  assert.equal(over.available, 0);
  assert.deepEqual(
    utilizationSegments({ budgetAmount: 0, actualSpend: 0, committedSpend: 0, availableAmount: 0 }),
    { spent: 0, committed: 0, available: 0 },
  );
});

test("budget status flags over-budget and ≥ 90% utilization", () => {
  assert.equal(budgetStatus(h1), "ok");
  assert.equal(
    budgetStatus({ ...h1, actualSpend: 850, committedSpend: 50, availableAmount: 100 }),
    "warning",
  );
  assert.equal(
    budgetStatus({ ...h1, actualSpend: 950, committedSpend: 100, availableAmount: -50 }),
    "over",
  );
  assert.equal(
    budgetStatus({ ...h1, budgetAmount: 0, actualSpend: 0, committedSpend: 0, availableAmount: 0 }),
    "ok",
  );
});

// ---------------------------------------------------------------------------
// Needs attention
// ---------------------------------------------------------------------------

test("attention items use real counts, show amounts only when known, and link to existing workflows", () => {
  const items = attentionItems(overview(), today);
  const byKey = Object.fromEntries(items.map((item) => [item.key, item]));
  assert.equal(byKey.approvals.count, 2);
  assert.equal(byKey.approvals.amount, null, "pending requests have no deterministic amount");
  assert.deepEqual(
    [byKey.approvals.href, byKey.approvals.search],
    ["/supply-requests", { queue: "needsReview" }],
  );
  assert.equal(byKey.invoiceReview.count, 3);
  assert.equal(byKey.invoiceReview.href, "/invoices");
  assert.equal(byKey.commitmentsToSettle.amount, 40);
  assert.equal(byKey.commitmentsToSettle.href, SETTLEMENT_ANCHOR);
  assert.equal(byKey.unpricedCommitments.count, 1);
  assert.equal(byKey.budgetWarning.count, 0);
  for (const item of items)
    assert.ok(!/ordered|shipped|receiving|purchase order/i.test(item.label), item.label);
});

test("budget warnings consider only budgets covering today", () => {
  const hot = { ...h1, actualSpend: 900, committedSpend: 50, availableAmount: 50 };
  const pastOver = budget(5, {
    periodStart: "2026-01-01",
    periodEnd: "2026-12-31",
    availableAmount: -10,
    actualSpend: 1010,
    committedSpend: 0,
  });
  const warning = attentionItems(overview({ budgets: [hot, pastOver] }), today).find(
    (i) => i.key === "budgetWarning",
  )!;
  assert.equal(warning.count, 1);
  assert.match(warning.detail, /H1 2027|Budget 1/);
});

test("admins (not owners) get no invoice review item because invoice screens are owner-only", () => {
  const items = attentionItems(
    overview({
      viewerIsOwner: false,
      recentPurchases: null,
      attention: { ...overview().attention, invoiceReviewCount: null },
    }),
    today,
  );
  assert.equal(
    items.some((i) => i.key === "invoiceReview"),
    false,
  );
  const rendered = html("NeedsAttention", { items, invoiceDetailHidden: true });
  assert.match(rendered, /Invoice review is available to organization owners/);
});

// ---------------------------------------------------------------------------
// Price intelligence
// ---------------------------------------------------------------------------

test("filters classify increases and savings opportunities from the server comparison fields only", () => {
  assert.deepEqual([tape, gauze, wrap, ice].map(isPriceIncrease), [true, false, false, false]);
  assert.deepEqual([tape, gauze, wrap, ice].map(isSavingsOpportunity), [true, false, false, false]);
  assert.deepEqual(filterPriceRows([tape, gauze, wrap, ice], "all").length, 4);
  assert.deepEqual(
    filterPriceRows([tape, gauze, wrap, ice], "increases").map((r) => r.productName),
    ["KT Tape"],
  );
  assert.deepEqual(
    filterPriceRows([tape, gauze, wrap, ice], "savings").map((r) => r.productName),
    ["KT Tape"],
  );
  assert.deepEqual(
    filterPriceRows([tape, gauze, wrap, ice], "all", uuid(302)).map((r) => r.productName),
    ["Gauze"],
  );
});

test("no alternative or a more expensive alternative never fabricates savings", () => {
  assert.equal(isSavingsOpportunity(gauze), false);
  assert.equal(isSavingsOpportunity(ice), false);
  assert.equal(isSavingsOpportunity({ ...tape, unitSavings: 0 }), false);
});

test("sorts are deterministic and put missing values last", () => {
  const rows = [wrap, gauze, ice, tape];
  assert.deepEqual(
    sortPriceRows(rows, "increase").map((r) => r.productName),
    ["KT Tape", "Gauze", "Ice", "Wrap"],
  );
  assert.deepEqual(
    sortPriceRows(rows, "savings").map((r) => r.productName),
    ["KT Tape", "Gauze", "Ice", "Wrap"],
  );
  assert.deepEqual(
    sortPriceRows(rows, "recent").map((r) => r.productName),
    ["Gauze", "Ice", "KT Tape", "Wrap"],
  );
  assert.deepEqual(
    sortPriceRows(rows, "product").map((r) => r.productName),
    ["Gauze", "Ice", "KT Tape", "Wrap"],
  );
});

test("result schemas reject unexpected or malformed RPC payloads", () => {
  assert.equal(priceOverviewSchema.safeParse(prices()).success, true);
  assert.equal(
    priceOverviewSchema.safeParse({ ...prices(), rows: [{ ...tape, catalogListPrice: 1 }] })
      .success,
    false,
  );
  assert.equal(overviewSchema.safeParse(overview()).success, true);
  assert.equal(
    overviewSchema.safeParse({
      ...overview(),
      attention: { ...overview().attention, awaitingApprovalCount: -1 },
    }).success,
    false,
  );
  assert.equal(daysAgo("2027-02-25", today), "18 days ago");
  assert.equal(daysAgo("2027-03-14", today), "1 day ago");
});

// ---------------------------------------------------------------------------
// Data layer
// ---------------------------------------------------------------------------

function mockDb(
  role = "admin",
  payload: unknown = overview(),
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
  // Only the methods the data layer uses are implemented.
  return { db: client as unknown as SupabaseClient<Database>, calls };
}

test("server data functions check owner/admin membership before calling org-scoped RPCs", async () => {
  const { db, calls } = mockDb("admin");
  await getCommandCenterOverview(db, "user", org);
  assert.deepEqual(calls.at(-1), [
    "rpc",
    "get_budget_purchasing_overview",
    { _organization_id: org },
  ]);
  assert.ok(calls.some((c) => c[0] === "eq" && c[1] === "organization_id" && c[2] === org));
  for (const role of ["staff", null]) {
    const denied = mockDb(role as string);
    await assert.rejects(() => getCommandCenterOverview(denied.db, "user", org), /Forbidden/);
    await assert.rejects(() => getPriceIntelligenceOverview(denied.db, "user", org), /Forbidden/);
    assert.equal(
      denied.calls.some((c) => c[0] === "rpc"),
      false,
    );
  }
});

test("server data functions surface database refusals and reject malformed data", async () => {
  await assert.rejects(
    () =>
      getCommandCenterOverview(
        mockDb("owner", null, { code: "42501", message: "x" }).db,
        "user",
        org,
      ),
    /Forbidden/,
  );
  await assert.rejects(
    () =>
      getBudgetLineage(
        mockDb("owner", null, { code: "P0002", message: "x" }).db,
        "user",
        org,
        uuid(101),
      ),
    /no longer exists/,
  );
  await assert.rejects(() =>
    getPriceIntelligenceOverview(mockDb("owner", { rows: "nope" }).db, "user", org),
  );
  const { db, calls } = mockDb("owner", prices());
  assert.equal((await getPriceIntelligenceOverview(db, "user", org)).rows.length, 4);
  assert.deepEqual(calls.at(-1), [
    "rpc",
    "get_price_intelligence_overview",
    { _organization_id: org },
  ]);
});

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

test("loading and error states are explicit and retryable", () => {
  const loading = html("SectionLoading", { label: "Loading price intelligence…" });
  assert.match(loading, /role="status"/);
  assert.match(loading, /Loading price intelligence…/);
  const error = html("SectionError", {
    message: "Budget figures could not be loaded.",
    onRetry: () => {},
  });
  assert.match(error, /role="alert"/);
  assert.match(error, /Retry/);
});

test("financial summary renders budget, spent, committed, available and the utilization bar", () => {
  const rendered = html("FinancialSummary", {
    summary: summarizeScope([h1, h2], h1.budgetId),
    today,
  });
  for (const text of [
    "Budget",
    "Spent",
    "Committed",
    "Available",
    "$1,000.00",
    "$250.00",
    "$70.00",
    "$680.00",
    "32.0% used",
    "2 posted invoices",
    "Active / unreleased · 2 requests",
  ])
    assert.ok(rendered.includes(text), text);
  assert.match(rendered, /width:25%/);
  assert.doesNotMatch(rendered, /NaN|Infinity/);
});

test("financial summary discloses overage, unpriced commitments and out-of-period scope", () => {
  const over = {
    ...summarizeScope([h1], h1.budgetId)!,
    actualSpend: 900,
    committedSpend: 200,
    availableAmount: -100,
    incompleteCommitmentCount: 2,
  };
  const rendered = html("FinancialSummary", { summary: over, today: "2028-01-01" });
  assert.match(rendered, /exceed this budget by \$100\.00/);
  assert.match(rendered, /2 active commitments have unpriced items/);
  assert.match(rendered, /does not include today/);
  const zero = html("FinancialSummary", {
    summary: { ...over, budgetAmount: 0, actualSpend: 0, committedSpend: 0, availableAmount: 0 },
    today,
  });
  assert.match(zero, /Zero budget/);
  assert.doesNotMatch(zero, /NaN|Infinity/);
});

test("budget table shows per-budget spent, committed, available and utilization", () => {
  const rendered = html("BudgetTable", { budgets: [h1, h2], scopeBudgetIds: [h1.budgetId] });
  for (const text of [
    "H1 2027",
    "H2 2027",
    "$680.00",
    "$390.00",
    "32.0%",
    "22.0%",
    "On track",
    "in view",
    "unpriced",
  ])
    assert.ok(rendered.includes(text), text);
});

test("price intelligence table renders comparisons and filters to savings opportunities", () => {
  const all = html("PriceIntelligenceTable", { overview: prices(), today });
  for (const text of [
    "Price Intelligence",
    "KT Tape",
    "Vendor A",
    "$118.00",
    "$104.00",
    "+13.5%",
    "$111.00",
    '$106.20</span><span class="block truncate text-xs text-[#7a8592]">Vendor B',
    "$11.80",
    "/ case",
    "18 days ago",
    "Unit unknown",
    "None known",
    "never catalog list prices",
  ])
    assert.ok(all.includes(text), text);
  assert.equal((all.match(/data-product-id=/g) ?? []).length, 4);
  const savings = html("PriceIntelligenceTable", {
    overview: prices(),
    today,
    initialFilter: "savings",
  });
  assert.equal((savings.match(/data-product-id=/g) ?? []).length, 1);
  assert.match(savings, /aria-pressed="true"[^>]*>Savings opportunities/);
  const increases = html("PriceIntelligenceTable", {
    overview: prices([gauze, ice]),
    today,
    initialFilter: "increases",
  });
  assert.match(increases, /No items match price increases/);
  const empty = html("PriceIntelligenceTable", { overview: prices([]), today });
  assert.match(empty, /No posted purchase prices yet/);
});

test("selected price item exposes the supporting evidence", () => {
  const rendered = html("PriceEvidence", { row: tape, today });
  for (const text of [
    "Vendor A",
    "$118.00 / case",
    "invoice #INV-1",
    "case · case of 12",
    "$104.00",
    "invoice #PREV-1",
    "+$14.00",
    "+13.5%",
    "$111.00",
    "from 2 purchases",
    "Vendor B · $106.20 / case",
    "invoice #ALT-1",
    "$11.80 / case",
    "not independently verified",
  ])
    assert.ok(rendered.includes(text), text);
  const unitless = html("PriceEvidence", { row: wrap, today });
  assert.match(unitless, /did not record a unit of measure/);
  assert.match(unitless, /No earlier comparable purchase/);
});

test("budget lineage and recent purchasing link to existing invoice review routes; admins see no invoice detail", () => {
  const lineage = {
    budgetId: h1.budgetId,
    commitmentCount: 2,
    commitmentTotal: 70,
    listLimit: 50,
    settlementCandidateCount: 0,
    settlementCandidateTotal: 0,
    commitments: [
      {
        requestId: uuid(601),
        requestStatus: "approved",
        committedAt: "2027-02-10T12:00:00Z",
        amount: 30,
        pricingStatus: "fully_priced",
        itemCount: 2,
        itemLabel: "Tape",
        settlementCandidate: false,
      },
    ],
    postedInvoiceCount: 2,
    postedTotal: 250,
    postedInvoices: overview().recentPurchases,
  };
  const owner = html("BudgetLineagePanel", { budget: h1, lineage });
  assert.match(owner, /2 active commitments · \$70\.00/);
  assert.match(owner, /Tape \+ 1 more/);
  assert.match(owner, /2 posted invoices · \$250\.00/);
  assert.match(owner, new RegExp(`href="/invoices/${uuid(901)}"`));
  const admin = html("BudgetLineagePanel", {
    budget: h1,
    lineage: { ...lineage, postedInvoiceCount: null, postedTotal: null, postedInvoices: null },
  });
  assert.match(admin, /available to organization owners/);
  assert.doesNotMatch(admin, /H1-200/);
  const recent = html("RecentPurchasing", { purchases: overview().recentPurchases });
  assert.match(recent, /Vendor A/);
  assert.match(recent, /#H1-200/);
  assert.match(recent, /\$200\.00/);
});

// ---------------------------------------------------------------------------
// Settlement candidates (active commitments on received/completed requests)
// ---------------------------------------------------------------------------

const h1Settle = budget(1, {
  budgetName: "H1 2027",
  settlementCandidateCount: 1,
  settlementCandidateAmount: 40,
});
const renderSummary = (rows: BudgetRow[], scope: string, props: Record<string, unknown> = {}) =>
  html("FinancialSummary", { summary: summarizeScope(rows, scope), today, ...props });

test("settlement: no candidates renders the summary with no settlement warning", () => {
  const rendered = renderSummary([h1, h2], h1.budgetId);
  assert.doesNotMatch(rendered, /data-notice="settlement"|may need settlement/);
  const item = attentionItems(
    overview({
      attention: {
        ...overview().attention,
        commitmentsToSettleCount: 0,
        commitmentsToSettleAmount: 0,
      },
      settlementCandidates: [],
    }),
    today,
  ).find((i) => i.key === "commitmentsToSettle")!;
  assert.equal(item.prominent, false);
  assert.equal(item.amount, null);
});

test("settlement: a candidate in scope renders an operational warning with exact count and amount", () => {
  const rendered = renderSummary([h1Settle, h2], h1Settle.budgetId, {
    onReviewSettlement: () => {},
  });
  assert.match(rendered, /data-notice="settlement"/);
  assert.match(rendered, /\$40\.00 of commitments may need settlement/);
  assert.match(rendered, /1 request in Committed is already received or completed/);
  assert.match(rendered, /Available includes it, so it may be conservative/);
  assert.match(rendered, /Review commitments to settle/);
  assert.doesNotMatch(
    rendered,
    /data-notice="settlement"[^>]*(a83340|fff0f1)/,
    "warning is not error-styled",
  );
  // Candidates in another budget period do not warn about this one.
  assert.doesNotMatch(renderSummary([h1Settle, h2], h2.budgetId), /may need settlement/);
});

test("settlement: canonical Committed and Available are unchanged by the warning", () => {
  const scope = summarizeScope([h1Settle, h2], h1Settle.budgetId)!;
  assert.equal(scope.committedSpend, 70);
  assert.equal(scope.availableAmount, 680);
  assert.equal(
    scope.availableAmount,
    scope.budgetAmount - scope.actualSpend - scope.committedSpend,
  );
  const rendered = renderSummary([h1Settle, h2], h1Settle.budgetId);
  assert.match(rendered, />\$70\.00</);
  assert.match(rendered, />\$680\.00</);
  assert.doesNotMatch(rendered, /\$640\.00|\$720\.00|adjusted/i, "no netted or adjusted figure");
  assert.match(rendered, /Active \/ unreleased · 2 requests/);
});

test("settlement: wording never claims the commitment is confirmed duplicate spend or invoiced", () => {
  const texts = [
    renderSummary([h1Settle], h1Settle.budgetId, { onReviewSettlement: () => {} }),
    html("SettlementCandidatesPanel", {
      candidates: overview().settlementCandidates,
      count: 1,
      amount: 40,
      limit: 25,
    }),
    html("NeedsAttention", { items: attentionItems(overview(), today) }),
  ];
  for (const text of texts) {
    assert.doesNotMatch(
      text,
      /(is|are) (a )?duplicate|double[- ]count|has been invoiced|already invoiced|invoice exists|matched invoice/i,
    );
  }
  assert.match(texts[0], /not confirmed duplicate spend/);
  assert.match(texts[1], /does not match requests to invoices/);
});

test("settlement: the attention item leads, shows count and amount, and opens the settlement list", () => {
  const items = attentionItems(overview(), today);
  assert.equal(items[0].key, "commitmentsToSettle");
  assert.equal(items[0].prominent, true);
  const linked = html("NeedsAttention", { items });
  assert.match(linked, /data-attention="commitmentsToSettle" data-prominent="true"/);
  assert.match(linked, /1 request · \$40\.00/);
  assert.match(linked, /Received or completed requests whose commitments are still active/);
  assert.match(linked, new RegExp(`href="${SETTLEMENT_ANCHOR}"`));
  const withAction = html("NeedsAttention", { items, actions: { commitmentsToSettle: () => {} } });
  assert.match(withAction, /data-attention="commitmentsToSettle"[^>]*><button type="button"/);
});

test("settlement: each candidate links to its existing Request Inbox detail, where release is audited", () => {
  assert.deepEqual(requestReviewLink({ requestId: uuid(602) }), {
    to: "/supply-requests",
    search: { request: uuid(602) },
  });
  const panel = html("SettlementCandidatesPanel", {
    candidates: overview().settlementCandidates,
    count: 3,
    amount: 120,
    limit: 25,
  });
  assert.match(panel, /3 requests · \$120\.00/);
  assert.match(panel, new RegExp(`href="/supply-requests\\?request=${uuid(602)}"`));
  assert.match(panel, /Review &amp; release in Request Inbox/);
  assert.match(panel, /Showing the 1 oldest of 3/);
  assert.match(panel, /Nothing is released from this page/);
  const route = read("../src/routes/_authenticated/supply-requests.tsx");
  assert.match(route, /request: search\.request/);
  assert.match(route, /UUID\.test\(search\.request\)/);
  assert.match(
    route,
    /dashboard\.data\.queues\[key\]\.some\(\(request\) => request\.id === initialRequest\)/,
  );
});

test("settlement: budget drawer distinguishes active commitments from potential settlement candidates", () => {
  const lineage = {
    budgetId: h1.budgetId,
    commitmentCount: 2,
    commitmentTotal: 70,
    listLimit: 50,
    settlementCandidateCount: 1,
    settlementCandidateTotal: 40,
    commitments: [
      {
        requestId: uuid(602),
        requestStatus: "completed",
        committedAt: "2027-03-01T12:00:00Z",
        amount: 40,
        pricingStatus: "fully_priced",
        itemCount: 1,
        itemLabel: "Ankle brace",
        settlementCandidate: true,
      },
      {
        requestId: uuid(601),
        requestStatus: "approved",
        committedAt: "2027-02-10T12:00:00Z",
        amount: 30,
        pricingStatus: "fully_priced",
        itemCount: 1,
        itemLabel: "Tape",
        settlementCandidate: false,
      },
    ],
    postedInvoiceCount: null,
    postedTotal: null,
    postedInvoices: null,
  };
  const rendered = html("BudgetLineagePanel", { budget: h1Settle, lineage });
  assert.match(
    rendered,
    /Includes 1 request \(\$40\.00\) already received or completed: potential settlement candidates/,
  );
  assert.match(
    rendered,
    /data-settlement-candidate="true"[\s\S]*Potential settlement candidate[\s\S]*data-settlement-candidate="false"[\s\S]*Active commitment/,
  );
  assert.match(rendered, /stays in Committed until an admin releases it/);
  assert.match(rendered, /may or may not be in Spent yet/);
});

test("settlement: overlap handling is unchanged and combined scopes sum candidates only when disjoint", () => {
  const h2Settle = { ...h2, settlementCandidateCount: 2, settlementCandidateAmount: 15 };
  const combined = summarizeScope([h1Settle, h2Settle], COMBINED_SCOPE)!;
  assert.equal(combined.settlementCandidateCount, 3);
  assert.equal(combined.settlementCandidateAmount, 55);
  assert.equal(combined.availableAmount, 1070);
  const annual = budget(3, {
    periodStart: "2027-01-01",
    periodEnd: "2027-12-31",
    settlementCandidateCount: 3,
    settlementCandidateAmount: 55,
  });
  assert.equal(summarizeScope([h1Settle, annual], COMBINED_SCOPE), null);
});

test("settlement: viewing the dashboard cannot release or change commitments", async () => {
  for (const file of [
    "../src/components/budget-purchasing/BudgetPurchasingPage.tsx",
    "../src/components/budget-purchasing/CommandCenterSections.tsx",
    "../src/budget-purchasing/data.ts",
    "../src/lib/budget-purchasing.functions.ts",
  ]) {
    assert.doesNotMatch(
      read(file),
      /release_supply_request_commitment|releaseSupplyRequestCommitment|method: 'GET'/,
      file,
    );
  }
  const { db, calls } = mockDb("owner");
  await getCommandCenterOverview(db, "user", org);
  assert.deepEqual(
    calls.filter((c) => c[0] === "rpc").map((c) => c[1]),
    ["get_budget_purchasing_overview"],
  );
  assert.ok(behavior.includes("Viewing the dashboard changed commitment state"));
  for (const text of [
    "Per-budget settlement candidates are incorrect",
    "Settlement candidate list is incorrect",
    "Lineage settlement flags are incorrect",
  ])
    assert.ok(behavior.includes(text), text);
  assert.match(migration, /request\.status IN \('received', 'completed'\) AS settlement_candidate/);
});

// ---------------------------------------------------------------------------
// Wiring, security and SQL coverage
// ---------------------------------------------------------------------------

test("the migration is read-only, admin-gated, org-scoped and not anon-executable", () => {
  assert.doesNotMatch(migration, /\b(INSERT|UPDATE|DELETE|CREATE TABLE|ALTER TABLE|DROP)\b/);
  assert.equal(
    (migration.match(/STABLE\s+SECURITY DEFINER\s+SET search_path = public/g) ?? []).length,
    3,
  );
  assert.equal(
    (migration.match(/public\.is_org_admin\(_organization_id, auth\.uid\(\)\)/g) ?? []).length,
    3,
  );
  assert.equal((migration.match(/FROM PUBLIC, anon;/g) ?? []).length, 3);
  assert.match(
    migration,
    /CROSS JOIN LATERAL public\.get_budget_summary\(_organization_id, budget\.id\)/,
  );
  assert.match(migration, /history\.organization_id = _organization_id/);
  assert.match(migration, /invoice\.posted_at IS NOT NULL/);
  assert.match(migration, /invoice\.currency_code = 'USD'/);
  assert.doesNotMatch(migration, /catalog_|source_price|list_price|similarity\(|levenshtein/i);
});

test("the SQL behavior suite covers the financial, price and isolation requirements", () => {
  for (const text of [
    "H1 budget math is incorrect",
    "Overview diverges from get_budget_summary",
    "Attention counts are incorrect",
    "Budget lineage does not reconcile",
    "Admin overview visibility is incorrect",
    "Tape previous price or change is incorrect",
    "Tape 90-day average is incorrect",
    "Tape alternative or savings is incorrect",
    "Unit-less observations were compared",
    "More expensive alternative fabricated savings",
    "Other organization prices leaked",
    "Cross-organization budget lineage succeeded",
    "Empty organization state is incorrect",
  ])
    assert.ok(behavior.includes(text), text);
});

test("navigation replaces Budget with Budget & Purchasing and keeps the old URL working", () => {
  const shell = read("../src/components/app/AdminAppShell.tsx");
  assert.match(shell, /to: "\/budget-purchasing", label: "Budget & Purchasing", icon: Wallet/);
  assert.doesNotMatch(shell, /to: "\/budget",/);
  assert.match(
    read("../src/routes/_authenticated/budget.tsx"),
    /redirect\(\{ to: ["']\/budget-purchasing["']/,
  );
  assert.match(
    read("../src/routes/_authenticated/route.tsx"),
    /ADMIN_ROUTES = \["\/budget-purchasing", "\/budget",/,
  );
  assert.match(
    read("../src/components/budget-purchasing/BudgetPurchasingPage.tsx"),
    /!canAccessBudget\(active\.role\)/,
  );
  assert.match(
    read("../src/components/budget-purchasing/BudgetPurchasingPage.tsx"),
    /BudgetEditor/,
  );
  assert.equal(
    (
      read("../src/lib/budget-purchasing.functions.ts").match(
        /middleware\(\[requireSupabaseAuth\]\)/g,
      ) ?? []
    ).length,
    3,
  );
  const types = read("../src/integrations/supabase/types.ts");
  for (const fn of [
    "get_budget_purchasing_overview",
    "get_budget_lineage",
    "get_price_intelligence_overview",
  ])
    assert.match(types, new RegExp(`${fn}: \\{`));
});

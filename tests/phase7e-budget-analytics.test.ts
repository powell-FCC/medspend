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
  COVERAGE_STATEMENTS,
  approxRemainingLabel,
  commitmentCoverageLabel,
  coverageLines,
  cumulativeChartPoints,
  documentListSchema,
  documentTypeLabel,
  formatMonthLabel,
  formatUtcDay,
  paceLabel,
  removalConfirmation,
  removalInputError,
  signalDrill,
  signalLabel,
  spendSeriesSchema,
  spendSummarySchema,
  utcToday,
  type SpendSummary,
} from "../src/budget-analytics/spend.ts";
import { getSpendSummary, listSpendDocuments } from "../src/budget-analytics/data.ts";
import { postingBlockedReason } from "../src/invoice/deletion.ts";
import { utcToday as budgetUtcToday } from "../src/budget/budget.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const migration = read("../supabase/migrations/20261117120000_phase7e_budget_analytics.sql");
const behavior = read("../supabase/tests/phase7e_budget_analytics_behavior.sql");

const sectionsPath = new URL(
  "../src/components/budget-analytics/SpendSections.tsx",
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
const budgetId = "00000000-0000-4000-8000-000000000901";
const zero = { count: 0, amount: 0 };

// FC Cincinnati as of 2026-11-16 (production read-only audit), in the RPC's shape.
const fcc = (overrides: Partial<SpendSummary> = {}): SpendSummary =>
  spendSummarySchema.parse({
    organizationId: org,
    asOf: "2026-11-16",
    viewerIsOwner: true,
    scope: {
      kind: "budget",
      budgetId,
      budgetName: "Tape",
      budgetActive: true,
      from: "2026-01-01",
      to: "2026-12-31",
      budgetAmount: 50000,
    },
    budgets: [
      {
        budgetId,
        budgetName: "Tape",
        periodStart: "2026-01-01",
        periodEnd: "2026-12-31",
        budgetAmount: 50000,
      },
    ],
    spent: 20256.15,
    countedDocumentCount: 5,
    remaining: 29743.85,
    commitments: {
      open: {
        count: 3,
        pricedAmount: 36.78,
        fullyPriced: 0,
        partiallyPriced: 1,
        unpriced: 2,
        staleCount: 0,
      },
      receivedNotSettled: {
        count: 2,
        pricedAmount: 0,
        fullyPriced: 0,
        partiallyPriced: 0,
        unpriced: 2,
      },
      unexpectedCount: 0,
    },
    approxRemainingAfterOpenCommitments: 29707.07,
    pace: {
      state: "in_progress",
      elapsedPercent: 87.67,
      spentPercent: 40.51,
      gapPoints: -47.16,
      band: "behind",
    },
    burn: {
      monthStart: "2026-11-01",
      spentThisMonth: 77.93,
      trailingFrom: "2026-08-19",
      trailing90Days: 244.28,
      completeMonths: 10,
      monthsWithSpend: 3,
      averagePerCompleteMonth: null,
    },
    coverage: {
      countedDocuments: { count: 5, amount: 20256.15 },
      datedByPosting: { count: 2, amount: 244.28 },
      orderConfirmations: { count: 2, amount: 244.28 },
      typeUnknown: zero,
      typeMissing: zero,
      excludedCreditMemos: zero,
      excludedStatements: zero,
      excludedNonUsd: { count: 0 },
      legacyNoCurrency: { count: 5, amount: 20256.15 },
      componentDifferences: zero,
      components: { linesTotal: 18950.91, taxTotal: 1280.84, shippingTotal: 24.4, difference: 0 },
      linesCategorized: { categorized: 0, total: 10 },
      possibleDuplicates: zero,
      removedAfterPosting: zero,
      spendOutsideBudgets: zero,
    },
    signals: [
      { code: "open_commitments_unpriced", severity: "info", count: 3, amount: null },
      { code: "received_not_settled", severity: "info", count: 2, amount: 0 },
      { code: "dated_by_posting", severity: "info", count: 2, amount: 244.28 },
      { code: "order_confirmations_counted", severity: "info", count: 2, amount: 244.28 },
    ],
    ...overrides,
  });

// ---------------------------------------------------------------------------
// Wording and calendar helpers
// ---------------------------------------------------------------------------

test("UTC calendar: today and labels never use the browser's local day", () => {
  // 23:30 on Dec 31 in New York is Jan 1 UTC.
  const lateNewYork = new Date("2027-01-01T04:30:00Z");
  assert.equal(utcToday(lateNewYork), "2027-01-01");
  assert.equal(budgetUtcToday(lateNewYork), "2027-01-01");
  assert.equal(formatUtcDay("2026-10-12"), "Oct 12, 2026");
  assert.equal(formatMonthLabel("2026-01"), "Jan 26");
  assert.doesNotMatch(read("../src/budget/budget.ts"), /localToday|getFullYear\(\)/);
  assert.doesNotMatch(
    read("../src/components/budget-purchasing/BudgetPurchasingPage.tsx"),
    /localToday/,
  );
});

test("pace wording is neutral, banded at ±5 points and reference-only", () => {
  const pace = (gapPoints: number) => ({
    state: "in_progress" as const,
    elapsedPercent: 50,
    spentPercent: 50 + gapPoints,
    gapPoints,
    band: null,
  });
  assert.equal(paceLabel(pace(5)), "About even with an even pace");
  assert.equal(paceLabel(pace(-5)), "About even with an even pace");
  assert.equal(paceLabel(pace(5.01)), "Ahead of an even pace by 5.0 pts");
  assert.equal(paceLabel(pace(-47.16)), "Behind an even pace by 47.2 pts");
  assert.equal(
    paceLabel({
      state: "not_started",
      elapsedPercent: 0,
      spentPercent: 0,
      gapPoints: null,
      band: null,
    }),
    "This budget period has not started",
  );
  assert.equal(
    paceLabel({
      state: "ended",
      elapsedPercent: 100,
      spentPercent: 92.5,
      gapPoints: null,
      band: null,
    }),
    "Period ended · 92.5% of budget spent",
  );
  assert.equal(
    paceLabel({
      state: "no_amount",
      elapsedPercent: 40,
      spentPercent: null,
      gapPoints: null,
      band: null,
    }),
    "No budget amount to pace against",
  );
  assert.equal(paceLabel(null), null);
  for (const label of [paceLabel(pace(20)), paceLabel(pace(-20))])
    assert.doesNotMatch(label!, /over|under|bad|good|risk|target/i);
});

test("the approximate figure always carries coverage and never implies unpriced = $0", () => {
  const label = approxRemainingLabel(fcc())!;
  assert.match(label, /^≈ \$29,707\.07 after priced open commitments/);
  assert.match(label, /0 of 3 open commitments fully priced/);
  assert.match(label, /1 partly priced/);
  assert.match(label, /unpriced items not included/);
  const none = fcc({
    approxRemainingAfterOpenCommitments: null,
    commitments: {
      ...fcc().commitments,
      open: {
        count: 0,
        pricedAmount: 0,
        fullyPriced: 0,
        partiallyPriced: 0,
        unpriced: 0,
        staleCount: 0,
      },
    },
  });
  assert.equal(approxRemainingLabel(none), null);
  assert.equal(
    commitmentCoverageLabel({ count: 2, fullyPriced: 0, partiallyPriced: 0, unpriced: 2 }),
    "0 of 2 fully priced · 2 unpriced",
  );
  assert.equal(
    commitmentCoverageLabel({ count: 0, fullyPriced: 0, partiallyPriced: 0, unpriced: 0 }),
    "None",
  );
});

test("every signal has wording, and owner drill targets exist only where rows exist", () => {
  const summary = fcc();
  for (const signal of summary.signals) assert.ok(signalLabel(signal).length > 10, signal.code);
  assert.match(
    signalLabel({
      code: "pace_ahead",
      severity: "warning",
      count: null,
      amount: null,
      gapPoints: 12.34,
    }),
    /12\.3 pts ahead of an even pace \(more than 10 pts\)/,
  );
  assert.match(
    signalLabel({
      code: "order_confirmations_counted",
      severity: "info",
      count: 2,
      amount: 244.28,
    }),
    /may overlap a later invoice/,
  );
  assert.equal(signalDrill("dated_by_posting"), "dated_by_posting");
  assert.equal(signalDrill("spend_outside_budgets"), "outside_budgets");
  assert.equal(signalDrill("received_not_settled"), "commitments_received");
  assert.equal(signalDrill("pace_ahead"), null);
  assert.equal(signalDrill("budget_over"), null);
});

test("coverage lists every disclosure, zeros included, with NULL→USD and UTC stated", () => {
  const lines = coverageLines(fcc());
  assert.deepEqual(
    lines.map((l) => l.key),
    [
      "counted",
      "datedByPosting",
      "orderConfirmations",
      "typeUnknown",
      "typeMissing",
      "legacyNoCurrency",
      "componentDifferences",
      "possibleDuplicates",
      "excludedCreditMemos",
      "excludedStatements",
      "excludedNonUsd",
      "removedAfterPosting",
      "spendOutsideBudgets",
    ],
  );
  assert.equal(
    lines.find((l) => l.key === "legacyNoCurrency")!.label,
    "No currency recorded (treated as USD)",
  );
  assert.match(lines.find((l) => l.key === "typeUnknown")!.label, /Document type not classified/);
  const text = COVERAGE_STATEMENTS.join(" ");
  for (const phrase of [
    /organization-wide spending budget/,
    /not a category, team, location or cost center/,
    /treated as USD/,
    /UTC calendar days/,
    /not yet linked to requests/,
  ])
    assert.match(text, phrase);
  assert.equal(documentTypeLabel("UNKNOWN"), "Document type not classified");
  assert.equal(documentTypeLabel(null), "Document type not classified");
});

test("cumulative chart starts at zero on the first day, ends on the last, and carries an even-pace line", () => {
  const series = spendSeriesSchema.parse({
    from: "2026-01-01",
    to: "2026-01-10",
    total: 30,
    cumulative: [
      { date: "2026-01-03", amount: 10, documentCount: 1, cumulative: 10 },
      { date: "2026-01-05", amount: 20, documentCount: 1, cumulative: 30 },
    ],
    months: [{ month: "2026-01", monthStart: "2026-01-01", amount: 30, documentCount: 2 }],
  });
  const points = cumulativeChartPoints(series, 100);
  assert.deepEqual(
    points.map((p) => [p.date, p.cumulative]),
    [
      ["2026-01-01", 0],
      ["2026-01-03", 10],
      ["2026-01-05", 30],
      ["2026-01-10", 30],
    ],
  );
  assert.equal(points[0].even, 10);
  assert.equal(points.at(-1)!.even, 100);
  assert.ok(cumulativeChartPoints(series, null).every((p) => p.even === null));
});

test("removal input: reason length and typed confirmation follow the server rule", () => {
  assert.equal(removalConfirmation("  INV-20 "), "INV-20");
  assert.equal(removalConfirmation(null), "REMOVE");
  assert.match(
    removalInputError({ confirmation: "INV-20", reason: "short" }, "INV-20")!,
    /10 to 1000 characters/,
  );
  assert.match(
    removalInputError(
      { confirmation: "INV-2", reason: "Posted against the wrong vendor" },
      "INV-20",
    )!,
    /Type INV-20/,
  );
  assert.equal(
    removalInputError(
      { confirmation: " inv-20 ", reason: "Posted against the wrong vendor" },
      "INV-20",
    ),
    null,
  );
  assert.equal(
    removalInputError({ confirmation: "remove", reason: "Duplicate upload of a statement" }, null),
    null,
  );
});

test("credit memos and statements cannot be posted; every other type can", () => {
  assert.match(postingBlockedReason("CREDIT_MEMO")!, /Credit memos can't be posted yet/);
  assert.match(postingBlockedReason("STATEMENT")!, /never count as spend/);
  for (const type of ["INVOICE", "ORDER_CONFIRMATION", "PURCHASE_ORDER", "UNKNOWN", null])
    assert.equal(postingBlockedReason(type), null);
  const review = read("../src/components/invoice-processing/InvoiceReviewPage.tsx");
  assert.match(review, /Boolean\(postingBlockedReason\(data\.header\.documentType\)\)/);
  assert.match(
    read("../src/invoice/review-actions.ts"),
    /Credit memos can't be posted\|Statements are reference documents/,
  );
});

// ---------------------------------------------------------------------------
// Schemas and data layer
// ---------------------------------------------------------------------------

test("schemas reject unexpected keys and unknown signal codes", () => {
  assert.throws(() => spendSummarySchema.parse({ ...fcc(), availableAmount: 1 }));
  assert.throws(() =>
    spendSummarySchema.parse({
      ...fcc(),
      signals: [{ code: "forecast", severity: "info", count: 1, amount: 1 }],
    }),
  );
  assert.throws(() =>
    documentListSchema.parse({
      filter: "bogus",
      value: null,
      countsTowardSpent: true,
      totalCount: 0,
      totalAmount: 0,
      rows: [],
      nextCursor: null,
    }),
  );
});

function mockDb(
  role: string | null,
  payload: unknown,
  error: { code?: string; message: string } | null = null,
) {
  const calls: unknown[][] = [];
  const builder: Record<string, (...args: unknown[]) => unknown> = {
    select: () => builder,
    eq: () => builder,
    maybeSingle: async () => ({ data: role ? { role } : null, error: null }),
  };
  const client = {
    from: () => builder,
    rpc: async (name: string, args: unknown) => {
      calls.push(["rpc", name, args]);
      return { data: payload, error };
    },
  };
  return { db: client as unknown as SupabaseClient<Database>, calls };
}

test("data layer: membership first, exact RPC arguments, owner-only refusals explained", async () => {
  const { db, calls } = mockDb("admin", fcc());
  assert.equal((await getSpendSummary(db, "user", org, null)).spent, 20256.15);
  assert.deepEqual(calls[0], [
    "rpc",
    "get_financial_spend_summary",
    { _organization_id: org, _budget_id: null },
  ]);
  const staff = mockDb("staff", fcc());
  await assert.rejects(() => getSpendSummary(staff.db, "user", org, null), /Forbidden/);
  assert.equal(staff.calls.length, 0);
  const admin = mockDb("admin", null, {
    code: "42501",
    message: "Forbidden: owner access required",
  });
  await assert.rejects(
    () =>
      listSpendDocuments(admin.db, "user", org, {
        from: "2026-01-01",
        to: "2026-12-31",
        filter: "all",
        value: null,
        limit: 50,
        cursor: null,
      }),
    /Invoice-level detail is available to organization owners/,
  );
  await assert.rejects(() =>
    getSpendSummary(mockDb("owner", { spent: "x" }).db, "user", org, null),
  );
});

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

test("Spend headline: Budget, Spent, Remaining after posted spend, split commitments, pace and burn", () => {
  const rendered = html("SpendHeadline", { summary: fcc() });
  for (const text of [
    "$50,000.00",
    "$20,256.15",
    "$29,743.85",
    "After posted spend (Budget − Spent)",
    "Open commitments",
    "$36.78",
    "Received, not settled",
    "not subtracted",
    "≈ $29,707.07 after priced open commitments",
    "Unpriced commitment items are not $0",
    "Behind an even pace by 47.2 pts",
    "It is a reference, not a target",
    "Spent this month",
    "$77.93",
    "Trailing 90 days",
    "$244.28",
    "Needs 6 months with spend",
  ])
    assert.ok(rendered.includes(text), text);
  assert.doesNotMatch(rendered, /Available|forecast|projected/i);
  const over = html("SpendHeadline", { summary: fcc({ spent: 51000, remaining: -1000 }) });
  assert.match(over, /−\$1,000\.00/);
  assert.match(over, /Over budget · after posted spend/);
  assert.match(over, /a83340/);
});

test("scope line says organization-wide and attributed by invoice date; no-budget states calendar YTD", () => {
  const scoped = html("SpendScopeLine", { summary: fcc() });
  assert.match(scoped, /Tape/);
  assert.match(scoped, /Organization-wide · spend attributed by invoice date \(UTC\)/);
  const noBudget = html("SpendScopeLine", {
    summary: fcc({
      scope: {
        kind: "calendar_year_to_date",
        budgetId: null,
        budgetName: null,
        budgetActive: null,
        from: "2026-01-01",
        to: "2026-11-16",
        budgetAmount: null,
      },
      remaining: null,
      pace: null,
    }),
  });
  assert.match(noBudget, /No active budget · calendar year to date/);
  const headline = html("SpendHeadline", {
    summary: fcc({
      scope: {
        kind: "calendar_year_to_date",
        budgetId: null,
        budgetName: null,
        budgetActive: null,
        from: "2026-01-01",
        to: "2026-11-16",
        budgetAmount: null,
      },
      remaining: null,
      pace: null,
    }),
  });
  assert.doesNotMatch(headline, />Remaining<|>Budget</);
});

test("signals and coverage: owners get drill buttons, admins get none for document-level rows", () => {
  const owner = html("SpendSignals", { signals: fcc().signals, canDrill: true, onDrill: () => {} });
  assert.match(owner, /may overlap a later invoice/);
  assert.equal((owner.match(/>View</g) ?? []).length, 4);
  const admin = html("SpendSignals", {
    signals: fcc().signals,
    canDrill: false,
    onDrill: () => {},
  });
  // Commitment signals stay actionable for admins (request level); document ones do not.
  assert.equal((admin.match(/>View</g) ?? []).length, 2);
  assert.match(
    html("SpendSignals", { signals: [], canDrill: true, onDrill: () => {} }),
    /Nothing needs attention/,
  );
  const coverageOwner = html("CoveragePanel", {
    summary: fcc(),
    canDrill: true,
    onDrill: () => {},
  });
  assert.match(coverageOwner, /No currency recorded \(treated as USD\)/);
  assert.match(coverageOwner, /0 of 10/);
  assert.match(coverageOwner, /<button[^>]*>Dated by the UTC posting day/);
  const coverageAdmin = html("CoveragePanel", {
    summary: fcc(),
    canDrill: false,
    onDrill: () => {},
  });
  assert.doesNotMatch(coverageAdmin, /<button/);
});

test("vendor and product tables reconcile, compare prices only within a unit, and render without drill for admins", () => {
  const vendors = html("VendorSpendTable", {
    vendors: {
      totalSpend: 20256.15,
      vendorCount: 1,
      rows: [
        {
          vendorId: org,
          vendorName: "Henry Schein",
          spend: 20256.15,
          sharePercent: 100,
          documentCount: 5,
          averageDocument: 4051.23,
          largestDocument: 19054.88,
          firstSpendDate: "2026-01-02",
          lastSpendDate: "2026-11-03",
          orderConfirmationCount: 2,
        },
      ],
    },
  });
  assert.match(vendors, /Henry Schein/);
  assert.match(vendors, /includes 2 order confirmations/);
  assert.match(vendors, /disabled=""/);
  const products = html("ProductSpendTable", {
    products: {
      sort: "spend",
      productCount: 1,
      reconciliation: {
        linesTotal: 18950.91,
        taxTotal: 1280.84,
        shippingTotal: 24.4,
        difference: 0,
        spent: 20256.15,
      },
      rows: [
        {
          productId: org,
          productName: "Hivamat® Deep Oscillation® Unit",
          lineSpend: 17850,
          sharePercent: 94.19,
          lineCount: 1,
          documentCount: 1,
          vendorCount: 1,
          lastSpendDate: "2026-01-02",
          unitGroups: [
            {
              unitOfMeasure: "ea",
              packageSize: null,
              quantity: 1,
              lineCount: 1,
              minUnitPrice: 17850,
              maxUnitPrice: 17850,
            },
            {
              unitOfMeasure: "bx",
              packageSize: "12",
              quantity: 2,
              lineCount: 1,
              minUnitPrice: 40,
              maxUnitPrice: 50,
            },
          ],
        },
      ],
    },
  });
  assert.match(
    products,
    /Lines \$18,950\.91 \+ tax \$1,280\.84 \+ shipping \$24\.40 = Spent \$20,256\.15/,
  );
  assert.match(products, /1 × ea<span[^>]*> · \$17,850\.00/);
  assert.match(products, /2 × bx · 12<span[^>]*> · \$40\.00–\$50\.00/);
});

test("document drill-down states whether rows count toward Spent and shows every flag", () => {
  const list = html("DocumentListView", {
    list: documentListSchema.parse({
      filter: "excluded",
      value: null,
      countsTowardSpent: false,
      totalCount: 1,
      totalAmount: 25,
      rows: [
        {
          invoiceId: org,
          sourceFileId: null,
          vendorId: null,
          vendorName: "Vendor",
          documentType: "CREDIT_MEMO",
          typeStatus: "classified",
          documentNumber: "CM-1",
          invoiceDate: "2026-05-01",
          postedAt: "2026-05-02T12:00:00Z",
          spendDate: "2026-05-01",
          dateBasis: "invoice_date",
          amount: 25,
          amountBasis: "invoice_total",
          subtotal: 25,
          taxAmount: null,
          shippingAmount: null,
          linesTotal: 25,
          lineCount: 1,
          componentDifference: 0,
          currencyCode: "USD",
          currencyBasis: "usd",
          counted: false,
          exclusionReason: "credit_memo",
        },
      ],
      nextCursor: null,
    }),
    onOpen: () => {},
  });
  assert.match(list, /not counted in Spent/);
  assert.match(list, /excluded \(credit memo\)/);
});

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

test("Budget & Purchasing has Overview and Spend tabs; the Spend tab is owner/admin and owner-gates drill-down", () => {
  const page = read("../src/components/budget-purchasing/BudgetPurchasingPage.tsx");
  assert.match(page, /role="tablist"/);
  assert.match(page, /<SpendWorkspace organizationId=\{organizationId\} \/>/);
  assert.match(page, /canAccessBudget\(active\.role\)/);
  const workspace = read("../src/components/budget-analytics/SpendWorkspace.tsx");
  assert.match(workspace, /const isOwner = summary\.data\?\.viewerIsOwner \?\? false/);
  assert.match(workspace, /Invoice-level detail is available to organization owners/);
  assert.match(workspace, /enabled: isOwner/);
});

test("posted documents are removed with a reason and confirmation; the source file is never deleted", () => {
  const fns = read("../src/lib/invoice-history.functions.ts");
  const removal = fns.slice(
    fns.indexOf("export const removePostedDocumentFn"),
    fns.indexOf("export const listPurchaseHistoryFn"),
  );
  assert.match(removal, /remove_posted_financial_document/);
  assert.doesNotMatch(removal, /storage/);
  assert.match(fns, /reason: z\.string\(\)\.trim\(\)\.min\(10\)\.max\(1000\)/);
  const list = read("../src/components/invoice-history/InvoiceListPage.tsx");
  assert.match(list, /Remove posted document/);
  assert.match(
    list,
    /disabled=\{!selected \|\| pending \|\| !reasonValid \|\| !confirmationValid\}/,
  );
  assert.match(list, /source file is retained/);
});

test("the migration and behaviour suite cover the locked 7E decisions", () => {
  for (const pattern of [
    /CREATE TABLE public\.financial_document_removals/,
    /CREATE TRIGGER organization_budgets_no_overlap/,
    /CREATE TRIGGER invoices_posted_guard/,
    /CREATE TRIGGER invoice_items_posted_guard/,
    /Credit memos can''t be posted yet/,
    /AND public\.vendor_invoice_storage_deletable\(name\)/,
    /COALESCE\(invoice\.invoice_date, \(invoice\.posted_at AT TIME ZONE 'UTC'\)::date\)/,
    /WHEN _currency_code IS NULL OR btrim\(_currency_code\) = '' THEN 'legacy_usd'/,
    /_gap IS NOT NULL AND _gap > 10/,
  ])
    assert.match(migration, pattern);
  assert.doesNotMatch(migration, /forecast/i);
  for (const pattern of [
    /exactly 10 points ahead is not a signal/,
    /refused removals changed nothing/,
    /removed document PDF is retained/,
    /overview budget keys unchanged/,
  ])
    assert.match(behavior, pattern);
});

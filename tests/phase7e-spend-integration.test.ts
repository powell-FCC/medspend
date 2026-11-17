// Phase 7E API integration and benchmark: the Spend reads through a real PostgREST with signed
// user JWTs, via the same data layer the server functions use (src/budget-analytics/data.ts), so
// every RPC payload is parsed by the app's strict schemas. Fixture
// (supabase/tests/integration/phase7e_spend_fixture.sql): 50,000 documents and 250,000 lines in
// organization A, 1,000,000 lines in the database. Started by
// supabase/tests/run_phase7e_spend_integration.sh; skipped by a plain `npm test`.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import {
  getDocumentDetail,
  getSpendSeries,
  getSpendSummary,
  listCommitments,
  listProductLines,
  listProductSpend,
  listRemovals,
  listSpendDocuments,
  listVendorSpend,
} from "../src/budget-analytics/data.ts";
import { getCommandCenterOverview } from "../src/budget-purchasing/data.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7e_spend_integration.sh";

const id = (suffix: string) => `7e1c0000-0000-4000-8000-000000000${suffix}`;
const ORG = id("101");
const OTHER_ORG = id("102");
const BUDGET_MS = 500;

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

async function timed<T>(work: () => Promise<T>): Promise<[T, number]> {
  await work(); // warm the plan cache; time the second call
  const start = performance.now();
  const value = await work();
  return [value, performance.now() - start];
}
const sum = (values: number[]) => Math.round(values.reduce((a, b) => a + b, 0) * 100) / 100;
const round = (value: number) => Math.round(value * 100) / 100;

test(
  "summary at 250,000 lines: owner and admin agree, within budget, and reconcile",
  { skip },
  async () => {
    const [summary, ms] = await timed(() => getSpendSummary(admin, id("002"), ORG, null));
    assert.ok(ms < BUDGET_MS, `summary took ${ms.toFixed(0)} ms`);
    console.log(`# timing summary ${ms.toFixed(0)} ms`);
    assert.equal(summary.scope.budgetName, "FY 2026");
    assert.equal(summary.viewerIsOwner, false);
    const ownerView = await getSpendSummary(owner, id("001"), ORG, null);
    assert.equal(ownerView.viewerIsOwner, true);
    assert.equal(ownerView.spent, summary.spent);
    const c = summary.coverage;
    assert.equal(
      round(
        c.components.linesTotal +
          c.components.taxTotal +
          c.components.shippingTotal +
          c.components.difference,
      ),
      summary.spent,
    );
    assert.equal(summary.remaining, round(3000000 - summary.spent));
    assert.ok(c.datedByPosting.count > 0 && c.orderConfirmations.count === c.datedByPosting.count);
    assert.ok(c.typeUnknown.count > 0 && c.legacyNoCurrency.count > 0);
    assert.equal(summary.commitments.unexpectedCount, 0);
    assert.equal(
      summary.commitments.open.count + summary.commitments.receivedNotSettled.count,
      2000,
    );
    assert.equal(
      summary.burn.averagePerCompleteMonth !== null,
      true,
      "10 complete months with spend",
    );
  },
);

test(
  "series, vendors and products: every list sums to Spent for the budget year, within budget",
  { skip },
  async () => {
    const summary = await getSpendSummary(admin, id("002"), ORG, null);
    const { from, to } = summary.scope;
    const [series, seriesMs] = await timed(() => getSpendSeries(admin, id("002"), ORG, from, to));
    const [vendors, vendorMs] = await timed(() => listVendorSpend(admin, id("002"), ORG, from, to));
    const [products, productMs] = await timed(() =>
      listProductSpend(admin, id("002"), ORG, { from, to, sort: "spend", limit: 15, offset: 0 }),
    );
    for (const [name, ms] of [
      ["series", seriesMs],
      ["vendors", vendorMs],
      ["products", productMs],
    ] as const) {
      console.log(`# timing ${name} ${ms.toFixed(0)} ms`);
      assert.ok(ms < BUDGET_MS, `${name} took ${ms.toFixed(0)} ms`);
    }
    assert.equal(series.total, summary.spent);
    assert.equal(series.months.length, 12);
    assert.equal(sum(series.months.map((m) => m.amount)), summary.spent);
    assert.equal(vendors.totalSpend, summary.spent);
    assert.equal(vendors.vendorCount, 200);
    // The list shows the top 100 vendors; its total covers all of them.
    assert.equal(vendors.rows.length, 100);
    assert.ok(sum(vendors.rows.map((v) => v.spend)) < summary.spent);
    assert.ok(
      vendors.rows.every((v, i) => i === 0 || vendors.rows[i - 1].spend >= v.spend),
      "largest first",
    );
    const r = products.reconciliation;
    assert.equal(r.spent, summary.spent);
    assert.equal(round(r.linesTotal + r.taxTotal + r.shippingTotal + r.difference), summary.spent);
    assert.ok(products.productCount > 4000);
    for (const row of products.rows) {
      const keys = row.unitGroups.map((g) => `${g.unitOfMeasure?.toLowerCase()}|${g.packageSize}`);
      assert.equal(new Set(keys).size, keys.length, "ea and EA share one unit group");
    }
  },
);

test(
  "owner document drill-down pages to the headline; admins and staff are refused",
  { skip },
  async () => {
    const summary = await getSpendSummary(owner, id("001"), ORG, null);
    const { from, to } = summary.scope;
    let cursor: { spendDate: string; invoiceId: string } | null = null;
    let total = 0;
    let rows = 0;
    let pages = 0;
    do {
      const page = await listSpendDocuments(owner, id("001"), ORG, {
        from,
        to,
        filter: "month",
        value: "2026-03",
        limit: 200,
        cursor,
      });
      total += page.rows.reduce((a, d) => a + d.amount, 0);
      rows += page.rows.length;
      cursor = page.nextCursor;
      pages += 1;
      if (!cursor) {
        assert.equal(rows, page.totalCount);
        assert.equal(round(total), page.totalAmount);
        const march = (await getSpendSeries(owner, id("001"), ORG, from, to)).months.find(
          (m) => m.month === "2026-03",
        )!;
        assert.equal(page.totalAmount, march.amount);
      }
    } while (cursor && pages < 50);
    const [, docMs] = await timed(() =>
      listSpendDocuments(owner, id("001"), ORG, {
        from,
        to,
        filter: "all",
        value: null,
        limit: 50,
        cursor: null,
      }),
    );
    console.log(`# timing documents page ${docMs.toFixed(0)} ms`);
    assert.ok(docMs < BUDGET_MS);
    const first = (
      await listSpendDocuments(owner, id("001"), ORG, {
        from,
        to,
        filter: "all",
        value: null,
        limit: 1,
        cursor: null,
      })
    ).rows[0];
    const detail = await getDocumentDetail(owner, id("001"), ORG, first.invoiceId);
    assert.equal(detail.lines.length, 5);
    assert.equal(
      round(detail.lines.reduce((a, l) => a + (l.totalPrice ?? 0), 0)),
      first.linesTotal,
    );
    const productId = detail.lines[0].productId;
    const lines = await listProductLines(owner, id("001"), ORG, { productId, from, to });
    assert.ok(lines.totalCount > 0);
    assert.equal((await listRemovals(owner, id("001"), ORG)).totalCount, 0);
    await assert.rejects(
      () =>
        listSpendDocuments(admin, id("002"), ORG, {
          from,
          to,
          filter: "all",
          value: null,
          limit: 50,
          cursor: null,
        }),
      /Invoice-level detail is available to organization owners/,
    );
    await assert.rejects(() => getSpendSummary(staff, id("003"), ORG, null), /Forbidden/);
    await assert.rejects(() => getSpendSummary(otherOwner, id("004"), ORG, null), /Forbidden/);
  },
);

test(
  "commitments and the Command Center overview stay within budget; other organizations never leak",
  { skip },
  async () => {
    const [commitments, ms] = await timed(() =>
      listCommitments(admin, id("002"), ORG, {
        from: "2026-01-01",
        to: "2026-12-31",
        bucket: "open",
        limit: 50,
        offset: 0,
      }),
    );
    console.log(`# timing commitments ${ms.toFixed(0)} ms`);
    assert.ok(ms < BUDGET_MS);
    assert.equal(commitments.totalCount, 1000);
    const [overview, overviewMs] = await timed(() =>
      getCommandCenterOverview(owner, id("001"), ORG),
    );
    console.log(`# timing overview ${overviewMs.toFixed(0)} ms`);
    assert.ok(overviewMs < BUDGET_MS, `overview took ${overviewMs.toFixed(0)} ms`);
    assert.equal(overview.budgets.length, 5);
    const summary = await getSpendSummary(owner, id("001"), ORG, null);
    const fy2026 = overview.budgets.find((b) => b.budgetName === "FY 2026")!;
    assert.equal(fy2026.actualSpend, summary.spent, "Command Center and Spend tab agree");
    const other = await getSpendSummary(otherOwner, id("004"), OTHER_ORG, null);
    assert.equal(other.scope.kind, "calendar_year_to_date");
    assert.notEqual(other.spent, 0);
    assert.equal(other.commitments.open.count + other.commitments.receivedNotSettled.count, 0);
  },
);

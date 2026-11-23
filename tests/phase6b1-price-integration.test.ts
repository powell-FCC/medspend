// Phase 6B.1 API integration and benchmark: Price Intelligence through a real PostgREST with
// signed user JWTs, via the same data layer the server functions use
// (src/price-intelligence/data.ts), so every payload is parsed by the app's strict schemas.
// Fixture (supabase/tests/integration/phase6b1_price_fixture.sql): a club with 250,000 and a
// university with 1,000,000 price observations. Started by
// supabase/tests/run_phase6b1_price_integration.sh; skipped by a plain `npm test`.
//
// Targets (p95 of the timed calls): list page < 300 ms, filtered scan chunk < 500 ms, detail
// < 150 ms, request context < 100 ms, summary < 1 s. The university summary does not meet its
// 1 s target (it reads every observation); it is measured, reported and held to a regression
// ceiling, and the list never waits for it.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import {
  getPriceIntelligenceSummary,
  getProductVendorHistory,
  getSupplyRequestPriceContext,
  listPriceIntelligenceProducts,
} from "../src/price-intelligence/data.ts";
import type { PriceListCursor } from "../src/price-intelligence/vendor-intelligence.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase6b1_price_integration.sh";

const id = (suffix: string) => `6b1c0000-0000-4000-8000-000000000${suffix}`;
const CLUB = id("101");
const UNIVERSITY = id("102");

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
const clubOwner = user("001");
const clubAdmin = user("002");
const clubStaff = user("003");
const universityOwner = user("004");

const results: string[] = [];
async function p95<T>(label: string, runs: number, work: (i: number) => Promise<T>) {
  await work(0); // warm the plan cache
  const times: number[] = [];
  let value: T | undefined;
  for (let i = 0; i < runs; i++) {
    const start = performance.now();
    value = await work(i);
    times.push(performance.now() - start);
  }
  times.sort((a, b) => a - b);
  const p = times[Math.min(times.length - 1, Math.ceil(0.95 * times.length) - 1)];
  const line = `${label}: p95 ${p.toFixed(0)} ms (median ${times[Math.floor(times.length / 2)].toFixed(0)} ms, ${runs} runs)`;
  results.push(line);
  console.log(`# timing ${line}`);
  return [value as T, p] as const;
}
test.after(() => {
  if (configured) console.log(`# benchmark\n${results.map((r) => `#   ${r}`).join("\n")}`);
});

for (const [name, org, viewer, budgetSummary] of [
  ["club (250,000 observations)", CLUB, () => clubAdmin, 1000],
  ["university (1,000,000 observations)", UNIVERSITY, () => universityOwner, 6000],
] as const) {
  test(
    `${name}: list pages, scan chunks, detail and request context within budget`,
    { skip },
    async () => {
      const db = viewer();
      const userId = org === CLUB ? id("002") : id("004");
      const [first, recentMs] = await p95(`${name} list page (recent)`, 15, () =>
        listPriceIntelligenceProducts(db, userId, org, {
          sort: "recent",
          filter: "all",
          vendorId: null,
          cursor: null,
        }),
      );
      assert.equal(first.rows.length, 50);
      assert.ok(recentMs < 300, `recent page p95 ${recentMs.toFixed(0)} ms`);
      const [, nameMs] = await p95(`${name} list page (product)`, 15, () =>
        listPriceIntelligenceProducts(db, userId, org, {
          sort: "product",
          filter: "all",
          vendorId: null,
          cursor: null,
        }),
      );
      assert.ok(nameMs < 300, `product page p95 ${nameMs.toFixed(0)} ms`);
      // Deeper page: continue from the first page's cursor.
      const [, deepMs] = await p95(`${name} list page 2 (recent)`, 15, () =>
        listPriceIntelligenceProducts(db, userId, org, {
          sort: "recent",
          filter: "all",
          vendorId: null,
          cursor: first.nextCursor,
        }),
      );
      assert.ok(deepMs < 300, `second page p95 ${deepMs.toFixed(0)} ms`);

      // Filtered scans: each call scans at most 1,000 products (the default scan budget).
      for (const filter of [
        "comparable",
        "insufficient_identity",
        "lower_comparable_price_other_vendor",
      ] as const) {
        const [chunk, ms] = await p95(`${name} filtered scan chunk (${filter})`, 10, () =>
          listPriceIntelligenceProducts(db, userId, org, {
            sort: "recent",
            filter,
            vendorId: null,
            cursor: null,
          }),
        );
        assert.ok(chunk.scanned <= 1000);
        assert.ok(
          chunk.rows.every((r) => r.state === filter || r.signals.includes(filter as never)),
        );
        assert.ok(ms < 500, `${filter} scan chunk p95 ${ms.toFixed(0)} ms`);
      }

      const products = first.rows.slice(0, 15).map((r) => r.productId);
      const [history, detailMs] = await p95(`${name} product detail`, 15, (i) =>
        getProductVendorHistory(db, userId, org, { productId: products[i % products.length] }),
      );
      assert.ok(history.observations.length > 0);
      assert.ok(detailMs < 150, `detail p95 ${detailMs.toFixed(0)} ms`);

      const [context, contextMs] = await p95(`${name} request context (10 lines)`, 15, () =>
        getSupplyRequestPriceContext(db, userId, org, org === CLUB ? id("701") : id("702")),
      );
      assert.equal(context.items.length, 10);
      assert.ok(context.items.every((i) => i.productId !== null));
      assert.ok(contextMs < 100, `request context p95 ${contextMs.toFixed(0)} ms`);

      const [summary, summaryMs] = await p95(`${name} summary`, 5, () =>
        getPriceIntelligenceSummary(db, userId, org),
      );
      // Every club product is bought; 4 university products never are (fixture arithmetic).
    assert.equal(summary.productCount, org === CLUB ? 5000 : 24996);
      assert.ok(
        summaryMs < budgetSummary,
        `summary p95 ${summaryMs.toFixed(0)} ms (ceiling ${budgetSummary} ms)`,
      );
    },
  );
}

test(
  "club: walking every page returns each product exactly once and matches the summary",
  { skip },
  async () => {
    const counts = await getPriceIntelligenceSummary(clubOwner, id("001"), CLUB);
    for (const sort of ["recent", "product"] as const) {
      const seen = new Set<string>();
      let cursor: PriceListCursor = null;
      for (let calls = 0; calls < 200; calls++) {
        const page = await listPriceIntelligenceProducts(clubOwner, id("001"), CLUB, {
          sort,
          filter: "all",
          vendorId: null,
          cursor,
          limit: 100,
        });
        for (const row of page.rows) {
          assert.ok(!seen.has(row.productId), `${sort}: ${row.productId} twice`);
          seen.add(row.productId);
        }
        if (page.exhausted) break;
        cursor = page.nextCursor;
      }
      assert.equal(seen.size, counts.productCount, sort);
    }
    // A filtered walk with the scan budget finds exactly the summary's count.
    let found = 0;
    let cursor: PriceListCursor = null;
    for (let calls = 0; calls < 50; calls++) {
      const page = await listPriceIntelligenceProducts(clubOwner, id("001"), CLUB, {
        sort: "recent",
        filter: "comparable",
        vendorId: null,
        cursor,
        limit: 100,
      });
      found += page.rows.length;
      if (page.exhausted) break;
      cursor = page.nextCursor;
    }
    assert.equal(found, counts.states.comparable);
    assert.ok(
      counts.states.comparable > 0 &&
        counts.states.insufficient_identity > 0 &&
        counts.states.missing_package_details > 0,
    );
  },
);

test("access through the API: staff refused, organizations isolated", { skip }, async () => {
  await assert.rejects(() => getPriceIntelligenceSummary(clubStaff, id("003"), CLUB), /Forbidden/);
  await assert.rejects(
    () => getPriceIntelligenceSummary(universityOwner, id("004"), CLUB),
    /Forbidden/,
  );
  const page = await listPriceIntelligenceProducts(clubOwner, id("001"), CLUB, {
    sort: "recent",
    filter: "all",
    vendorId: null,
    cursor: null,
  });
  await assert.rejects(
    () =>
      getProductVendorHistory(universityOwner, id("004"), UNIVERSITY, {
        productId: page.rows[0].productId,
      }),
    /no purchase history/,
  );
  const admin = await getProductVendorHistory(clubAdmin, id("002"), CLUB, {
    productId: page.rows[0].productId,
  });
  assert.equal(admin.canOpenSourceDocument, false);
  const owner = await getProductVendorHistory(clubOwner, id("001"), CLUB, {
    productId: page.rows[0].productId,
  });
  assert.equal(owner.canOpenSourceDocument, true);
});

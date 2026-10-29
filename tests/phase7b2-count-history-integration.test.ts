// Phase 7B.2 API integration: the owner+admin count history reads through a real PostgREST
// with signed user JWTs, via the same read helpers the server functions use
// (src/inventory/workspace-reads.ts). PostgREST runs with the hosted default row cap (1000)
// and the fixture holds more count sessions than that. Started by
// supabase/tests/run_phase7b2_count_history_integration.sh; skipped by a plain `npm test`.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import { formatCorrectionSummary } from "../src/inventory/count-history.ts";
import {
  getCountSession,
  listAllWorkspaceLocations,
  listCountHistoryPage,
} from "../src/inventory/workspace-reads.ts";
import type { CountHistoryFilters, CountHistoryRow } from "../src/types/inventory-workspace.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
// This suite writes data. It only ever runs against a loopback address.
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7b2_count_history_integration.sh";

const id = (suffix: string) => `7b2c0000-0000-4000-8000-000000000${suffix}`;
const ORG = id("101");
const OTHER_ORG = id("102");
const HISTORICAL = 1200;
const REAL = 4;

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
const former = user("006");
const stranger = user("009");
const anon = configured ? clientFor({ role: "anon" }) : (null as never);

type Db = SupabaseClient<Database>;
const noFilters: CountHistoryFilters = {
  locationId: null,
  countedBy: null,
  changedOnly: false,
  submittedFrom: null,
  submittedBefore: null,
};
async function allHistory(
  db: Db,
  filters: Partial<CountHistoryFilters> = {},
  limit = 200,
  organizationId = ORG,
) {
  const rows: CountHistoryRow[] = [];
  let cursor: { submittedAt: string; id: string } | null = null;
  for (let pages = 0; pages < 1000; pages++) {
    const page = await listCountHistoryPage(db, {
      organizationId,
      ...noFilters,
      ...filters,
      cursor,
      limit,
    });
    rows.push(...page.rows);
    if (!page.nextCursor) return rows;
    cursor = page.nextCursor;
  }
  throw new Error("history paging did not finish");
}
async function locationNamed(name: string) {
  const found = (await listAllWorkspaceLocations(owner, ORG, "all")).find((l) => l.name === name);
  assert.ok(found, name);
  return found;
}
// The newest page: the four real counts, newest first, then historical ones.
const realCounts = async () =>
  (
    await listCountHistoryPage(owner, {
      organizationId: ORG,
      ...noFilters,
      cursor: null,
      limit: 10,
    })
  ).rows;

// ---------------------------------------------------------------------------------------
test("the API row cap is active and the owner's raw read is truncated", { skip }, async () => {
  const raw = await owner
    .from("inventory_count_sessions")
    .select("id", { count: "exact" })
    .eq("organization_id", ORG);
  assert.equal(raw.error, null);
  assert.equal(raw.data!.length, 1000, "PostgREST returned only the capped page");
  assert.equal(raw.count, HISTORICAL + REAL, "the organization really has more sessions");
});

test("owner and admin read identical, complete history across the row cap", { skip }, async () => {
  const ownerRows = await allHistory(owner);
  const adminRows = await allHistory(admin);
  assert.deepEqual(adminRows, ownerRows, "same contract and values for admin");
  assert.equal(ownerRows.length, HISTORICAL + REAL);
  assert.equal(
    new Set(ownerRows.map((row) => row.sessionId)).size,
    ownerRows.length,
    "no duplicates",
  );
  for (let i = 1; i < ownerRows.length; i++) {
    const [a, b] = [ownerRows[i - 1], ownerRows[i]];
    const ordered =
      a.submittedAt > b.submittedAt ||
      (a.submittedAt === b.submittedAt && a.sessionId > b.sessionId);
    assert.ok(ordered, `newest first, then id descending, at ${i}`);
  }
  assert.deepEqual(Object.keys(ownerRows[0]).sort(), [
    "changedCount",
    "correctionSummary",
    "countedBy",
    "countedByName",
    "lineCount",
    "locationActive",
    "locationId",
    "locationName",
    "sessionId",
    "submittedAt",
  ]);
  // Every page size walks the same order, including the shared-timestamp pair.
  for (const size of [1000, 137, 7]) {
    const walk = await allHistory(admin, {}, Math.min(size, 200));
    assert.deepEqual(
      walk.map((row) => row.sessionId),
      ownerRows.map((row) => row.sessionId),
      `page size ${size}`,
    );
  }
  const pair = ownerRows.filter((row) =>
    ["7b2c0000-0000-4000-8000-0000000a0600", "7b2c0000-0000-4000-8000-0000000a0601"].includes(
      row.sessionId,
    ),
  );
  assert.equal(pair.length, 2);
  assert.equal(pair[0].submittedAt, pair[1].submittedAt, "the pair shares a timestamp");
  assert.equal(pair[0].sessionId, "7b2c0000-0000-4000-8000-0000000a0601", "id descending");
});

test(
  "staff, other organizations, former members, non-members and anon are refused",
  { skip },
  async () => {
    const [first] = await realCounts();
    const calls: Array<
      [string, (db: Db) => PromiseLike<{ error: { message: string } | null; status: number }>]
    > = [
      [
        "list_inventory_count_history",
        (db) => db.rpc("list_inventory_count_history", { _organization_id: ORG }),
      ],
      [
        "get_inventory_count_session",
        (db) =>
          db.rpc("get_inventory_count_session", {
            _organization_id: ORG,
            _count_session_id: first.sessionId,
          }),
      ],
    ];
    for (const [name, call] of calls) {
      for (const db of [owner, admin])
        assert.equal((await call(db)).error, null, `${name} allowed`);
      for (const db of [staff, former, otherOwner, otherAdmin, stranger]) {
        const result = await call(db);
        assert.match(result.error?.message ?? "", /owner or admin access required/, name);
        assert.equal(result.status, 403, `${name} is a 403`);
      }
      assert.match((await call(anon)).error?.message ?? "", /permission denied/, `${name} anon`);
    }
  },
);

test("organizations are isolated by list and by id", { skip }, async () => {
  const other = await allHistory(otherAdmin, {}, 200, OTHER_ORG);
  assert.equal(other.length, 1);
  assert.equal(other[0].locationName, "Other Cabinet");
  const ours = await allHistory(admin);
  assert.ok(!ours.some((row) => row.sessionId === other[0].sessionId));
  await assert.rejects(getCountSession(admin, ORG, other[0].sessionId), /Count not found/);
  await assert.rejects(
    getCountSession(otherAdmin, OTHER_ORG, ours[0].sessionId),
    /Count not found/,
  );
  assert.deepEqual(await allHistory(admin, { locationId: other[0].locationId }), []);
});

test(
  "raw count tables stay owner-only: admins and staff read nothing directly",
  { skip },
  async () => {
    for (const db of [admin, staff, former, stranger]) {
      for (const table of ["inventory_count_sessions", "inventory_count_lines"] as const) {
        const raw = await db.from(table).select("id").limit(5);
        assert.equal(raw.error, null, table);
        assert.deepEqual(raw.data, [], `${table} returns no rows`);
      }
    }
    const anonRaw = await anon.from("inventory_count_sessions").select("id").limit(1);
    assert.match(anonRaw.error?.message ?? "", /permission denied/);
  },
);

test(
  "list rows: who, where, counts and per-unit summaries; former member; archived now",
  { skip },
  async () => {
    const [formerRow, matched, bulk, mixed] = await realCounts();
    assert.deepEqual(
      [formerRow, matched, bulk, mixed].map((row) => [
        row.locationName,
        row.countedByName,
        row.lineCount,
        row.changedCount,
      ]),
      [
        ["Rehab", "Former member", 1, 1],
        ["Cabinet", "Integration Owner", 6, 0],
        ["Bulk Shelf", "Integration Staff", 1000, 100],
        ["Cabinet", "Integration Staff", 6, 5],
      ],
    );
    assert.equal(formerRow.countedBy, id("006"), "former member's id kept for filtering");
    assert.equal(
      formatCorrectionSummary(mixed.correctionSummary),
      "-0.25 bottle · +1 box · +1 each · -2 roll",
    );
    assert.deepEqual(
      mixed.correctionSummary.find((unit) => unit.unit === "each"),
      { unit: "each", changedLines: 2, netDelta: 1, increase: 4, decrease: -3 },
      "same unit grouped; incompatible units never summed",
    );
    assert.deepEqual(matched.correctionSummary, []);
    assert.equal(formatCorrectionSummary(bulk.correctionSummary), "-100 each");
    const closet = await allHistory(admin, {
      locationId: (await locationNamed("History Closet")).id,
    });
    assert.equal(closet.length, HISTORICAL);
    assert.ok(
      closet.every((row) => !row.locationActive),
      "archived now",
    );
  },
);

test(
  "server-side filters: location, person, date range and has-corrections",
  { skip },
  async () => {
    const cabinet = await locationNamed("Cabinet");
    assert.deepEqual(
      (await allHistory(admin, { locationId: cabinet.id })).map((row) => row.countedByName),
      ["Integration Owner", "Integration Staff"],
    );
    assert.equal((await allHistory(admin, { countedBy: id("006") })).length, 1);
    assert.equal((await allHistory(admin, { countedBy: id("003") })).length, HISTORICAL / 2 + 2);
    const changed = await allHistory(admin, { changedOnly: true });
    assert.equal(changed.length, HISTORICAL / 4 + 3);
    assert.ok(changed.every((row) => row.changedCount > 0));
    const range = await allHistory(admin, {
      submittedFrom: "2025-01-01T00:00:00Z",
      submittedBefore: "2025-01-02T00:00:00Z",
    });
    assert.equal(range.length, 24, "one day of hourly counts, end exclusive");
    const combined = await allHistory(admin, {
      countedBy: id("001"),
      changedOnly: true,
      submittedFrom: "2025-01-01T00:00:00Z",
      submittedBefore: "2025-01-02T00:00:00Z",
    });
    assert.equal(combined.length, 6, "hours 3, 7, 11, 15, 19, 23 (every fourth, owner)");
  },
);

test(
  "session detail: snapshots, zero-delta lines kept, changed first, archived now",
  { skip },
  async () => {
    const [, matched, bulk, mixed] = await realCounts();
    const ownerDetail = await getCountSession(owner, ORG, mixed.sessionId);
    const adminDetail = await getCountSession(admin, ORG, mixed.sessionId);
    assert.deepEqual(adminDetail, ownerDetail, "owner and admin get the same detail");
    const { lines, ...header } = adminDetail;
    assert.deepEqual(header, mixed, "detail header equals the list row");
    assert.deepEqual(
      lines.map((line) => [
        line.name,
        line.sku,
        line.unit,
        line.previousQuantity,
        line.countedQuantity,
        line.delta,
        line.itemArchivedNow,
      ]),
      [
        ["Itest Gauze", "GAUZE-1", "box", 4, 5, 1, false],
        ["Itest Prewrap", "PRE-1", "each", 5, 9, 4, false],
        ["Itest Saline", "SAL-1", "bottle", 2.5, 2.25, -0.25, false],
        ["Itest Tape", "TAPE-1", "roll", 6, 4, -2, false],
        ["Itest Wrap", null, "each", 6, 3, -3, false],
        ["Itest Archived Kit", "KIT-1", "each", 3, 3, 0, true],
      ],
      "count-time name/SKU/unit even after the tape was renamed to a case; kit archived now",
    );
    const zero = await getCountSession(admin, ORG, matched.sessionId);
    assert.equal(zero.lines.length, 6);
    assert.ok(zero.lines.every((line) => line.delta === 0));
    const big = await getCountSession(admin, ORG, bulk.sessionId);
    assert.equal(big.lines.length, 1000, "a 1000-line count arrives whole in one JSON value");
    assert.ok(
      big.lines.slice(0, 100).every((line) => line.delta === -1),
      "corrections first",
    );
    assert.ok(
      big.lines.slice(100).every((line) => line.delta === 0),
      "900 unchanged lines kept",
    );
  },
);

test(
  "counting is unchanged: staff count through the API and it appears first",
  { skip },
  async () => {
    const rehab = await locationNamed("Rehab");
    const page = await staff.rpc("get_inventory_count_location", {
      _organization_id: ORG,
      _inventory_location_id: rehab.id,
    });
    assert.equal(page.error, null);
    const items = (
      page.data as { items: Array<{ inventoryItemId: string; version: number; quantity: string }> }
    ).items;
    const submit = (key: string) =>
      staff.rpc("submit_inventory_count", {
        _organization_id: ORG,
        _inventory_location_id: rehab.id,
        _idempotency_key: key,
        _lines: items.map((item) => ({
          inventoryItemId: item.inventoryItemId,
          observedVersion: item.version,
          countedQuantity: item.quantity,
        })),
      });
    const saved = await submit("itest-api-count");
    assert.equal(saved.error, null);
    const summary = saved.data as { sessionId: string; changedCount: number; replayed: boolean };
    assert.equal(summary.changedCount, 0);
    assert.equal(summary.replayed, false);
    const replay = await submit("itest-api-count");
    assert.equal((replay.data as { replayed: boolean }).replayed, true, "idempotent replay");
    const stale = await submit("itest-api-stale");
    assert.match(
      stale.error?.message ?? "",
      /Inventory changed while you were counting/,
      "stale protection",
    );
    const [first] = await realCounts();
    assert.equal(first.sessionId, summary.sessionId);
    assert.equal(first.countedByName, "Integration Staff");
    const detail = await getCountSession(admin, ORG, summary.sessionId);
    assert.deepEqual(
      detail.lines.map((line) => [line.name, line.unit, line.delta]),
      [["Itest Renamed Tape", "case", 0]],
      "a new count snapshots the item as it is now",
    );
    // Staff still cannot reach the history of the count they just made.
    assert.match(
      (
        await staff.rpc("get_inventory_count_session", {
          _organization_id: ORG,
          _count_session_id: summary.sessionId,
        })
      ).error?.message ?? "",
      /owner or admin access required/,
    );
  },
);

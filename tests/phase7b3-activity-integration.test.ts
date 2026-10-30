// Phase 7B.3 API integration: the owner+admin transfer and manual adjustment history reads
// through a real PostgREST with signed user JWTs, via the same read helpers the server
// functions use (src/inventory/workspace-reads.ts). PostgREST runs with the hosted default
// row cap (1000) and the fixture holds more transfers and more adjustments than that. Started
// by supabase/tests/run_phase7b3_activity_integration.sh; skipped by a plain `npm test`.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import {
  listAdjustmentHistoryPage,
  listAllWorkspaceLocations,
  listCountHistoryPage,
  listTransferHistoryPage,
} from "../src/inventory/workspace-reads.ts";
import type {
  ActivityCursor,
  AdjustmentFilters,
  AdjustmentHistoryRow,
  TransferHistoryRow,
} from "../src/types/inventory-workspace.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
// This suite reads a fixture database. It only ever runs against a loopback address.
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7b3_activity_integration.sh";

const id = (suffix: string) => `7b3c0000-0000-4000-8000-000000000${suffix}`;
const ORG = id("101");
const OTHER_ORG = id("102");
const HISTORICAL = 1200;
const REAL_TRANSFERS = 3;
const REAL_ADJUSTMENTS = 2;
const RECEIPTS = 600;
const COUNT_CORRECTIONS = 1;

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
const noFilters: AdjustmentFilters = {
  locationId: null,
  itemId: null,
  createdBy: null,
  createdFrom: null,
  createdBefore: null,
  reason: null,
};
async function allTransfers(
  db: Db,
  filters: Partial<AdjustmentFilters> = {},
  limit = 200,
  organizationId = ORG,
) {
  const rows: TransferHistoryRow[] = [];
  let cursor: ActivityCursor | null = null;
  for (let pages = 0; pages < 1000; pages++) {
    const page = await listTransferHistoryPage(db, {
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
  throw new Error("transfer paging did not finish");
}
async function allAdjustments(
  db: Db,
  filters: Partial<AdjustmentFilters> = {},
  limit = 200,
  organizationId = ORG,
) {
  const rows: AdjustmentHistoryRow[] = [];
  let cursor: ActivityCursor | null = null;
  for (let pages = 0; pages < 1000; pages++) {
    const page = await listAdjustmentHistoryPage(db, {
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
  throw new Error("adjustment paging did not finish");
}
async function locationNamed(name: string) {
  const found = (await listAllWorkspaceLocations(owner, ORG, "all")).find((l) => l.name === name);
  assert.ok(found, name);
  return found;
}
const newestFirst = (rows: Array<{ createdAt: string }>, ids: string[]) =>
  rows.every((row, i) => {
    if (i === 0) return true;
    const prev = rows[i - 1];
    return (
      prev.createdAt > row.createdAt || (prev.createdAt === row.createdAt && ids[i - 1] > ids[i])
    );
  });

// ---------------------------------------------------------------------------------------
test("the API row cap is active and the owner's raw reads are truncated", { skip }, async () => {
  const transfers = await owner
    .from("inventory_transfers")
    .select("id", { count: "exact" })
    .eq("organization_id", ORG);
  assert.equal(transfers.error, null);
  assert.equal(transfers.data!.length, 1000, "PostgREST returned only the capped page");
  assert.equal(transfers.count, HISTORICAL + REAL_TRANSFERS);
  const adjustments = await owner
    .from("inventory_adjustments")
    .select("id", { count: "exact" })
    .eq("organization_id", ORG);
  assert.equal(adjustments.data!.length, 1000);
  assert.equal(adjustments.count, HISTORICAL + REAL_ADJUSTMENTS + RECEIPTS + COUNT_CORRECTIONS);
});

test(
  "owner and admin read identical, complete transfer history across the row cap",
  { skip },
  async () => {
    const ownerRows = await allTransfers(owner);
    const adminRows = await allTransfers(admin);
    assert.deepEqual(adminRows, ownerRows, "same contract and values for admin");
    assert.equal(ownerRows.length, HISTORICAL + REAL_TRANSFERS);
    assert.equal(
      new Set(ownerRows.map((r) => r.transferId)).size,
      ownerRows.length,
      "no duplicates",
    );
    assert.ok(
      newestFirst(
        ownerRows,
        ownerRows.map((r) => r.transferId),
      ),
      "created_at DESC, id DESC",
    );
    // Paging is stable at other page sizes.
    for (const limit of [1000, 37])
      assert.deepEqual(
        (await allTransfers(admin, {}, Math.min(limit, 200))).map((r) => r.transferId),
        ownerRows.map((r) => r.transferId),
      );
    const pair = ownerRows.filter(
      (r) => r.transferId.endsWith("a0600") || r.transferId.endsWith("a0601"),
    );
    assert.equal(pair[0].createdAt, pair[1].createdAt, "the pair shares a timestamp");
    assert.equal(
      pair[0].transferId,
      "7b3c0000-0000-4000-8000-0000000a0601",
      "id descending breaks the tie",
    );
  },
);

test(
  "owner and admin read identical manual adjustment history; counts and receipts excluded",
  { skip },
  async () => {
    const ownerRows = await allAdjustments(owner);
    const adminRows = await allAdjustments(admin);
    assert.deepEqual(adminRows, ownerRows);
    assert.equal(ownerRows.length, HISTORICAL + REAL_ADJUSTMENTS, "more than the row cap");
    assert.ok(
      newestFirst(
        ownerRows,
        ownerRows.map((r) => r.adjustmentId),
      ),
    );
    assert.ok(ownerRows.every((r) => r.sourceType === "manual"));
    assert.ok(
      !ownerRows.some((r) => r.reason === "Physical count" || r.reason === "Invoice received"),
    );
    // The count's correction is still in count history.
    const counts = await listCountHistoryPage(admin, {
      organizationId: ORG,
      locationId: null,
      countedBy: null,
      changedOnly: true,
      submittedFrom: null,
      submittedBefore: null,
      cursor: null,
      limit: 10,
    });
    assert.equal(counts.rows.length, 1);
    assert.equal(counts.rows[0].locationName, "Training Room");
    assert.deepEqual(
      counts.rows[0].correctionSummary.map((u) => [u.unit, u.netDelta]),
      [["each", -2]],
    );
  },
);

test(
  "staff, other organizations, former members, non-members and anon are refused",
  { skip },
  async () => {
    const calls: Array<
      [string, (db: Db) => PromiseLike<{ error: { message: string } | null; status: number }>]
    > = [
      [
        "list_inventory_transfer_history",
        (db) => db.rpc("list_inventory_transfer_history", { _organization_id: ORG }),
      ],
      [
        "list_inventory_adjustment_history",
        (db) => db.rpc("list_inventory_adjustment_history", { _organization_id: ORG }),
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

test("organizations are isolated", { skip }, async () => {
  const otherTransfers = await allTransfers(otherAdmin, {}, 200, OTHER_ORG);
  const otherAdjustments = await allAdjustments(otherAdmin, {}, 200, OTHER_ORG);
  assert.equal(otherTransfers.length, 1);
  assert.equal(otherAdjustments.length, 1);
  assert.equal(otherTransfers[0].toLocationName, "Other Cabinet");
  const ours = await allTransfers(admin);
  assert.ok(!ours.some((r) => r.transferId === otherTransfers[0].transferId));
  assert.deepEqual(await allTransfers(admin, { locationId: otherTransfers[0].toLocationId }), []);
  assert.deepEqual(
    await allAdjustments(admin, { itemId: otherAdjustments[0].inventoryItemId }),
    [],
  );
});

test(
  "raw history tables stay owner-only: admins and staff read nothing directly",
  { skip },
  async () => {
    for (const db of [admin, staff, former, stranger, anon]) {
      for (const table of ["inventory_transfers", "inventory_adjustments"] as const) {
        const raw = await db.from(table).select("id").limit(5);
        // anon has no SELECT on transfers; on adjustments, RLS returns nothing.
        if (raw.error) assert.match(raw.error.message, /permission denied/, table);
        else assert.deepEqual(raw.data, [], `${table} returns no rows`);
      }
    }
  },
);

test(
  "transfer rows: item, from, to, quantity, who; former member; location both sides",
  { skip },
  async () => {
    const training = await locationNamed("Training Room");
    const unassigned = await locationNamed("Unassigned");
    // The fixture's real moves share one transaction timestamp; compare them by quantity.
    const newest = (await allTransfers(admin, { createdFrom: "2026-01-01T00:00:00Z" })).sort(
      (a, b) => b.quantity - a.quantity,
    );
    assert.deepEqual(
      newest.map((r) => [
        r.itemName,
        r.itemSku,
        r.itemUnit,
        r.quantity,
        r.fromLocationName,
        r.toLocationName,
        r.createdByName,
      ]),
      [
        [
          "Itest Elastic Wrap",
          "WRAP-4",
          "each",
          24,
          "Unassigned",
          "Training Room",
          "Integration Owner",
        ],
        [
          "Itest Elastic Wrap",
          "WRAP-4",
          "each",
          6,
          "Training Room",
          "Stadium",
          "Integration Owner",
        ],
        ["Itest Tape", "TAPE-1", "roll", 4, "Unassigned", "Stadium", "Former member"],
      ],
    );
    const atTraining = await allTransfers(admin, { locationId: training.id });
    assert.equal(
      atTraining.length,
      HISTORICAL + 2,
      "every historical move touches Training, plus in and out",
    );
    assert.ok(
      atTraining.some((r) => r.fromLocationId === training.id),
      "from side",
    );
    assert.ok(
      atTraining.some((r) => r.toLocationId === training.id),
      "to side",
    );
    const atUnassigned = await allTransfers(admin, { locationId: unassigned.id });
    assert.equal(atUnassigned.length, 2, "Unassigned participates in transfers");
    const byFormer = await allTransfers(admin, { createdBy: id("006") });
    assert.equal(byFormer.length, HISTORICAL / 4 + 1);
    assert.ok(byFormer.every((r) => r.createdByName === "Former member"));
    const tape = await allTransfers(admin, { itemId: id("502") });
    assert.equal(tape.length, HISTORICAL / 3 + 1);
    const day = await allTransfers(admin, {
      createdFrom: "2025-01-02T00:00:00Z",
      createdBefore: "2025-01-03T00:00:00Z",
    });
    assert.equal(day.length, 24, "half-open day");
  },
);

test(
  "adjustment rows: totals as stored, signed amounts, reason, location filters",
  { skip },
  async () => {
    const training = await locationNamed("Training Room");
    const real = await allAdjustments(admin, { createdFrom: "2026-01-01T00:00:00Z" });
    assert.deepEqual(
      real
        .sort((a, b) => a.adjustmentAmount - b.adjustmentAmount)
        .map((r) => [
          r.itemName,
          r.locationName,
          r.previousQuantity,
          r.adjustmentAmount,
          r.newQuantity,
          r.reason,
          r.createdByName,
        ]),
      [
        ["Itest Elastic Wrap", "Training Room", 30, -3, 27, "Damaged", "Integration Owner"],
        ["Itest Tape", "Stadium", 12, 2, 14, "Correction", "Former member"],
      ],
    );
    const zero = await allAdjustments(admin, { createdBefore: "2025-01-01T05:00:00Z" });
    assert.deepEqual(
      zero.map((r) => r.adjustmentAmount),
      [0, -1, 2, -1, 2],
      "zero, negative and positive amounts as stored",
    );
    const atTraining = await allAdjustments(admin, { locationId: training.id });
    assert.equal(atTraining.length, HISTORICAL / 2 + 1);
    assert.ok(!atTraining.some((r) => r.reason === "Physical count"));
    for (const reason of ["Manual adjustment", "Damaged", "Expired", "Correction"] as const) {
      const rows = await allAdjustments(admin, { reason });
      assert.ok(rows.length > 0 && rows.every((r) => r.reason === reason), reason);
    }
    const expired = await allAdjustments(admin, { reason: "Expired" });
    assert.equal(expired.length, HISTORICAL / 4);
    const byFormer = await allAdjustments(admin, { createdBy: id("006") });
    assert.equal(byFormer.length, HISTORICAL / 4 + 1);
    const physical = await admin.rpc("list_inventory_adjustment_history", {
      _organization_id: ORG,
      _reason: "Physical count",
    });
    assert.match(physical.error?.message ?? "", /Physical count corrections are shown in Counts/);
  },
);

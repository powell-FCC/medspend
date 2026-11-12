// Phase 7C integration: receiving destinations through the real server path, against a local
// Postgres (every migration applied) behind a real PostgREST, with supabase-js and signed JWTs.
// Started by supabase/tests/run_phase7c_receiving_integration.sh; skipped by `npm test`.
//
// Exercised for real: the destination list and receipt RPCs, Mark Received and Receive & Complete
// with and without a destination (an app loaded before this release), the closed generic receipt
// path, staff/admin receipt reads, the staff timeline built from them, the notification cycle with
// the in-memory fake provider, and inventory/invoice state before and after.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/integrations/supabase/types.ts";
import { FakeEmailProvider } from "../src/notifications/providers/fake.ts";
import {
  createServiceRoleClient,
  createSupabaseNotificationStore,
} from "../src/notifications/supabase-store.ts";
import { NOTIFICATION_SENDER } from "../src/notifications/templates.ts";
import { runNotificationCycle } from "../src/notifications/worker.ts";
import { parseReceiptSummaries } from "../src/supply-requests/receiving.ts";
import { buildStaffRequestTimeline } from "../src/supply-requests/staff-dashboard.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7c_receiving_integration.sh";

const id = (suffix: string) => `7c2f0000-0000-4000-8000-000000000${suffix}`;
const OWNER = id("001");
const ADMIN = id("002");
const STAFF = id("003");
const STAFF_TWO = id("004");
const WEST_OWNER = id("005");
const ORG = id("101");
const FIRST_TEAM = id("301");
const ACADEMY = id("302");
const OLD_CAGE = id("303");
const WEST_ROOM = id("304");
const STAFF_EMAIL = "itest-7c-3@example.invalid";

const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
function signToken(claims: Record<string, unknown>) {
  const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ ...claims, exp: Math.floor(Date.now() / 1000) + 3600 })}`;
  return `${body}.${createHmac("sha256", JWT_SECRET).update(body).digest("base64url")}`;
}
// Every call aborts after 5 s, so a hang fails fast instead of stalling the suite.
const stripRestPrefix: typeof fetch = (input, init) =>
  fetch(String(input instanceof Request ? input.url : input).replace("/rest/v1", ""), {
    ...init,
    signal: AbortSignal.timeout(5000),
  });
function clientFor(claims: Record<string, unknown>): SupabaseClient<Database> {
  return createClient<Database>(REST_URL, "local-publishable-key", {
    global: { headers: { Authorization: `Bearer ${signToken(claims)}` }, fetch: stripRestPrefix },
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });
}
const as = (sub: string) => clientFor({ role: "authenticated", sub });
const owner = configured ? as(OWNER) : (null as never);
const admin = configured ? as(ADMIN) : (null as never);
const staff = configured ? as(STAFF) : (null as never);
const staffTwo = configured ? as(STAFF_TWO) : (null as never);
const westOwner = configured ? as(WEST_OWNER) : (null as never);
const anon = configured ? clientFor({ role: "anon" }) : (null as never);
const service = configured
  ? createServiceRoleClient(REST_URL, signToken({ role: "service_role" }), stripRestPrefix)
  : (null as never);
const store = configured ? createSupabaseNotificationStore(service) : (null as never);
const rpc = (client: SupabaseClient<Database>, fn: string, args: Record<string, unknown>) =>
  client.rpc(fn as never, args as never);

async function must<T>(
  promise: PromiseLike<{ data: T; error: { message: string } | null }>,
): Promise<T> {
  const { data, error } = await promise;
  if (error) throw new Error(error.message);
  return data;
}
async function refused(
  promise: PromiseLike<{ error: { message: string } | null }>,
  pattern: RegExp,
) {
  const started = Date.now();
  const { error } = await promise;
  assert.ok(error, `expected an error matching ${pattern}`);
  assert.match(error.message, pattern);
  assert.ok(Date.now() - started < 2000, `the refusal took ${Date.now() - started} ms`);
}
async function submit(item: string) {
  return (await must(
    rpc(staff, "submit_supply_request", {
      _organization_id: ORG,
      _request_type: "reorder",
      _team_id: null,
      _location_id: null,
      _notes: null,
      _items: [{ freeTextItem: item, quantity: 2 }],
    }),
  )) as string;
}
async function request(requestId: string) {
  return must(service.from("supply_requests").select("*").eq("id", requestId).single());
}
async function approveAndOrder(requestId: string) {
  await must(
    rpc(admin, "approve_and_order_supply_request", {
      _organization_id: ORG,
      _request_id: requestId,
      _expected_updated_at: (await request(requestId)).updated_at,
    }),
  );
}
async function receipts(requestId: string) {
  return must(
    service
      .from("supply_request_receipts" as never)
      .select("*")
      .eq("supply_request_id", requestId),
  ) as Promise<
    {
      inventory_location_id: string;
      destination_name_snapshot: string;
      destination_kind: string;
      compound_action: string | null;
      supply_request_update_id: string;
    }[]
  >;
}
async function stockState() {
  const tables = [
    "inventory_items",
    "inventory_location_balances",
    "inventory_adjustments",
    "inventory_transfers",
    "invoices",
  ] as const;
  const rows = await Promise.all(
    tables.map((table) =>
      must(
        service
          .from(table as never)
          .select("*")
          .eq("organization_id", ORG),
      ),
    ),
  );
  return JSON.stringify(rows);
}
async function setProfile(profile: string) {
  await must(
    rpc(admin, "update_organization_request_workflow_settings", {
      _organization_id: ORG,
      _workflow_profile: profile,
    }),
  );
}

let stockBefore = "";

test(
  "destinations: admins list active locations of their organization, Unassigned last",
  { skip },
  async () => {
    stockBefore = await stockState();
    const list = (await must(
      rpc(admin, "list_receiving_destinations", { _organization_id: ORG }),
    )) as { id: string; name: string; kind: string }[];
    assert.deepEqual(
      list.map((d) => `${d.name}:${d.kind}`),
      ["Academy ATR:storage", "First Team ATR:storage", "Unassigned:unassigned"],
    );
    assert.equal(
      (
        (await must(
          rpc(owner, "list_receiving_destinations", { _organization_id: ORG }),
        )) as unknown[]
      ).length,
      3,
    );
    await refused(
      rpc(staff, "list_receiving_destinations", { _organization_id: ORG }),
      /administrator access required/,
    );
    await refused(
      rpc(westOwner, "list_receiving_destinations", { _organization_id: ORG }),
      /administrator access required/,
    );
    await refused(
      rpc(anon, "list_receiving_destinations", { _organization_id: ORG }),
      /permission denied/,
    );
    await refused(admin.from("supply_request_receipts" as never).select("*"), /permission denied/);
  },
);

test(
  "an app loaded before this release is refused at once with a refresh message",
  { skip },
  async () => {
    const requestId = await submit("Old app receipt");
    await approveAndOrder(requestId);
    await refused(
      rpc(admin, "receive_and_complete_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
      }),
      /Refresh SportSpend and choose a receiving destination/,
    );
    await setProfile("detailed");
    await refused(
      rpc(admin, "receive_supply_request", { _organization_id: ORG, _request_id: requestId }),
      /Refresh SportSpend and choose a receiving destination/,
    );
    await refused(
      rpc(admin, "transition_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _status: "received",
      }),
      /Use the receiving action to choose a receiving destination/,
    );
    assert.equal((await request(requestId)).status, "ordered");
    assert.equal((await receipts(requestId)).length, 0);
    await setProfile("lean");
  },
);

test(
  "Lean Receive & Complete records one destination; retries are safe; no email",
  { skip },
  async () => {
    const requestId = await submit("Lean receipt");
    await approveAndOrder(requestId);
    await refused(
      rpc(admin, "receive_and_complete_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _inventory_location_id: OLD_CAGE,
      }),
      /Old Cage is archived/,
    );
    await refused(
      rpc(admin, "receive_and_complete_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _inventory_location_id: WEST_ROOM,
      }),
      /receiving destination of this organization/,
    );
    const result = (await must(
      rpc(admin, "receive_and_complete_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _inventory_location_id: FIRST_TEAM,
        _staff_visible_note: "In the ATR fridge",
        _internal_note: "Internal: box 2",
      }),
    )) as { status: string; receipt: { destinationName: string } };
    assert.equal(result.status, "completed");
    assert.equal(result.receipt.destinationName, "First Team ATR");
    const retry = (await must(
      rpc(admin, "receive_and_complete_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _inventory_location_id: FIRST_TEAM,
      }),
    )) as { alreadyApplied: boolean };
    assert.equal(retry.alreadyApplied, true);
    await refused(
      rpc(owner, "receive_and_complete_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _inventory_location_id: ACADEMY,
      }),
      /already received to First Team ATR/,
    );
    const rows = await receipts(requestId);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].compound_action, "receive_and_complete");
    assert.equal(rows[0].destination_kind, "storage");

    // Staff: their own receipt by name (never the location id); timeline says where it went.
    const staffReceipts = (await must(
      rpc(staff, "list_supply_request_receipts", {
        _organization_id: ORG,
        _request_ids: [requestId],
      }),
    )) as Record<string, unknown>[];
    assert.equal(staffReceipts.length, 1);
    assert.equal(staffReceipts[0].inventory_location_id, null);
    assert.equal(staffReceipts[0].destination_name, "First Team ATR");
    assert.equal(
      (
        (await must(
          rpc(staffTwo, "list_supply_request_receipts", {
            _organization_id: ORG,
            _request_ids: [requestId],
          }),
        )) as unknown[]
      ).length,
      0,
    );
    const adminReceipts = (await must(
      rpc(admin, "list_supply_request_receipts", {
        _organization_id: ORG,
        _request_ids: [requestId],
      }),
    )) as Record<string, unknown>[];
    assert.equal(adminReceipts[0].inventory_location_id, FIRST_TEAM);
    const history = (await must(
      rpc(staff, "list_staff_supply_request_updates", {
        _organization_id: ORG,
        _request_ids: [requestId],
      }),
    )) as Record<string, string | null>[];
    assert.ok(history.every((row) => !("internal_note" in row)));
    const byUpdate = new Map(
      parseReceiptSummaries(staffReceipts).map((receipt) => [
        receipt.supplyRequestUpdateId,
        receipt,
      ]),
    );
    const timeline = buildStaffRequestTimeline(
      (await request(requestId)).created_at,
      history.map((row) => ({
        status_to: row.status_to as never,
        staff_visible_note: row.staff_visible_note,
        event_kind: row.event_kind,
        created_at: row.created_at as string,
        compound_action: row.compound_action as never,
        receiving_destination: byUpdate.get(row.id as string)?.destinationName ?? null,
        receiving_destination_kind: byUpdate.get(row.id as string)?.destinationKind ?? null,
      })),
      "lean",
    );
    assert.deepEqual(timeline.at(-1), {
      label: "Completed",
      occurredAt: timeline.at(-1)!.occurredAt,
      message: "In the ATR fridge",
      destination: "Delivered to First Team ATR",
    });

    // Notifications: approval only (submission goes to admins); nothing for receiving or completing.
    const provider = new FakeEmailProvider();
    await runNotificationCycle({
      store,
      provider,
      sender: NOTIFICATION_SENDER,
      appBaseUrl: "https://app.example.test",
      batchSize: 20,
      maxBatches: 50,
    });
    const toRequester = provider.sent
      .filter((message) => message.to === STAFF_EMAIL)
      .map((message) => message.subject);
    assert.ok(
      toRequester.length > 0 && toRequester.every((subject) => /approved/i.test(subject)),
      JSON.stringify(toRequester),
    );
    const events = (
      await must(
        service.from("notification_events").select("event_type").eq("entity_id", requestId),
      )
    )
      .map((row) => row.event_type)
      .sort();
    assert.deepEqual(events, ["request_approved", "request_submitted"]);
  },
);

test(
  "Detailed Mark Received records the destination at receipt; Complete asks for none",
  { skip },
  async () => {
    await setProfile("detailed");
    const requestId = await submit("Detailed receipt");
    await must(
      rpc(admin, "decide_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _decision: "approved",
        _expected_updated_at: (await request(requestId)).updated_at,
      }),
    );
    await must(
      rpc(admin, "transition_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _status: "ordered",
      }),
    );
    const unassigned = (
      (await must(rpc(admin, "list_receiving_destinations", { _organization_id: ORG }))) as {
        id: string;
        kind: string;
      }[]
    ).find((d) => d.kind === "unassigned")!.id;
    const received = (await must(
      rpc(admin, "receive_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _inventory_location_id: unassigned,
      }),
    )) as { status: string; receipt: { destinationKind: string } };
    assert.equal(received.status, "received");
    assert.equal(received.receipt.destinationKind, "unassigned");
    const again = (await must(
      rpc(admin, "receive_supply_request", { _organization_id: ORG, _request_id: requestId }),
    )) as { alreadyApplied: boolean };
    assert.equal(again.alreadyApplied, true);
    await refused(
      rpc(admin, "receive_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _inventory_location_id: ACADEMY,
      }),
      /already received to Unassigned/,
    );
    await must(
      rpc(admin, "transition_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _status: "completed",
      }),
    );
    const rows = await receipts(requestId);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].compound_action, null);
    await refused(
      rpc(staff, "receive_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _inventory_location_id: ACADEMY,
      }),
      /administrator access required/,
    );
    await setProfile("lean");
  },
);

test("receiving changed no inventory or invoice row", { skip }, async () => {
  assert.equal(await stockState(), stockBefore);
});

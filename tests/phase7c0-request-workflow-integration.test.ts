// Phase 7C.0 integration: request workflow profiles through the real server path, against a local
// Postgres (every migration applied) behind a real PostgREST, with supabase-js and signed JWTs.
// Started by supabase/tests/run_phase7c0_workflow_integration.sh; skipped by `npm test`.
//
// Exercised for real: the settings RPCs (Admin Settings and the member profile read), the request
// RPCs the app's server functions call (submit, decide, Approve & Order, Mark Received, Receive &
// Complete, plain transitions), the staff history projection, and the notification cycle
// (src/notifications/worker.ts over the service-role store) with the in-memory fake provider.
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
import { buildStaffRequestTimeline } from "../src/supply-requests/staff-dashboard.ts";
import { parseCompoundAction } from "../src/supply-requests/workflow-profiles.ts";

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase7c0_workflow_integration.sh";

const id = (suffix: string) => `7c0f0000-0000-4000-8000-000000000${suffix}`;
const OWNER = id("001");
const ADMIN = id("002");
const STAFF = id("003");
const STAFF_TWO = id("004");
const WEST_OWNER = id("005");
const ORG = id("101");
const WEST = id("102");
const STAFF_EMAIL = "itest-7c0-3@example.invalid";

const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
function signToken(claims: Record<string, unknown>) {
  const body = `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ ...claims, exp: Math.floor(Date.now() / 1000) + 3600 })}`;
  return `${body}.${createHmac("sha256", JWT_SECRET).update(body).digest("base64url")}`;
}
const stripRestPrefix: typeof fetch = (input, init) =>
  fetch(String(input instanceof Request ? input.url : input).replace("/rest/v1", ""), init);
function clientFor(claims: Record<string, unknown> | null): SupabaseClient<Database> {
  return createClient<Database>(REST_URL, "local-publishable-key", {
    global: {
      headers: claims ? { Authorization: `Bearer ${signToken(claims)}` } : {},
      fetch: stripRestPrefix,
    },
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
  const { error } = await promise;
  assert.ok(error, `expected an error matching ${pattern}`);
  assert.match(error.message, pattern);
}
async function submit(item: string, client: SupabaseClient<Database> = staff) {
  return must(
    client.rpc("submit_supply_request", {
      _organization_id: ORG,
      _request_type: "reorder",
      _team_id: null,
      _location_id: null,
      _notes: null,
      _items: [{ freeTextItem: item, quantity: 1 }],
    } as never),
  ) as Promise<string>;
}
async function request(requestId: string) {
  return must(service.from("supply_requests").select("*").eq("id", requestId).single());
}
async function history(requestId: string) {
  return must(
    service
      .from("supply_request_updates")
      .select("status_to,compound_action,staff_visible_note,internal_note,created_at")
      .eq("supply_request_id", requestId)
      .order("created_at")
      .order("status_to"),
  );
}
async function events(requestId: string) {
  const rows = await must(
    service.from("notification_events").select("event_type").eq("entity_id", requestId),
  );
  return rows.map((row) => row.event_type).sort();
}
async function cycle(provider: FakeEmailProvider) {
  return runNotificationCycle({
    store,
    provider,
    sender: NOTIFICATION_SENDER,
    appBaseUrl: "https://app.example.test",
    batchSize: 10,
    maxBatches: 50,
  });
}
// Phase 7C: every receipt names a receiving destination; these tests use Unassigned.
async function unassigned(): Promise<string> {
  const destinations = (await must(
    admin.rpc("list_receiving_destinations" as never, { _organization_id: ORG } as never),
  )) as { id: string; kind: string }[];
  const found = destinations.find((destination) => destination.kind === "unassigned");
  assert.ok(found, "Unassigned destination");
  return found.id;
}
const setProfile = (client: SupabaseClient<Database>, profile: string, organizationId = ORG) =>
  must(
    client.rpc("update_organization_request_workflow_settings", {
      _organization_id: organizationId,
      _workflow_profile: profile,
    }),
  );

test(
  "settings: no row is Detailed; admins change it; staff, outsiders and anon cannot",
  { skip },
  async () => {
    const initial = (await must(
      owner.rpc("get_organization_request_workflow_settings", { _organization_id: ORG }),
    )) as Record<string, unknown>;
    assert.equal(initial.workflowProfile, "detailed");
    assert.equal(initial.updatedAt, null);
    assert.equal(
      await must(staff.rpc("get_request_workflow_profile", { _organization_id: ORG })),
      "detailed",
    );

    await refused(
      staff.rpc("update_organization_request_workflow_settings", {
        _organization_id: ORG,
        _workflow_profile: "lean",
      }),
      /administrator access required/,
    );
    await refused(
      staff.rpc("get_organization_request_workflow_settings", { _organization_id: ORG }),
      /administrator access required/,
    );
    await refused(
      westOwner.rpc("update_organization_request_workflow_settings", {
        _organization_id: ORG,
        _workflow_profile: "lean",
      }),
      /administrator access required/,
    );
    await refused(
      westOwner.rpc("get_request_workflow_profile", { _organization_id: ORG }),
      /Not a member/,
    );
    await refused(
      anon.rpc("get_request_workflow_profile", { _organization_id: ORG }),
      /permission denied/,
    );
    await refused(
      admin.rpc("update_organization_request_workflow_settings", {
        _organization_id: ORG,
        _workflow_profile: "express",
      }),
      /Choose Lean, Standard or Detailed/,
    );
    await refused(
      admin.from("organization_request_workflow_settings" as never).select("*"),
      /permission denied/,
    );

    const saved = (await setProfile(admin, "standard")) as Record<string, unknown>;
    assert.equal(saved.workflowProfile, "standard");
    assert.equal(
      await must(staffTwo.rpc("get_request_workflow_profile", { _organization_id: ORG })),
      "standard",
    );
    assert.equal(
      await must(westOwner.rpc("get_request_workflow_profile", { _organization_id: WEST })),
      "detailed",
    );
  },
);

test(
  "Lean Approve & Order: canonical rows, commitment, one Approved email, safe retry",
  { skip },
  async () => {
    await must(
      service.rpc("set_organization_notification_sending", {
        _organization_id: ORG,
        _enabled: true,
      }),
    );
    // A request approved under Standard stays approved after the switch to Lean.
    const before = await submit("Approved under Standard");
    await must(
      admin.rpc("decide_supply_request", {
        _organization_id: ORG,
        _request_id: before,
        _decision: "approved",
        _expected_updated_at: (await request(before)).updated_at,
      }),
    );
    await setProfile(owner, "lean");
    assert.equal((await request(before)).status, "approved");

    const requestId = await submit("Lean ankle tape");
    const version = (await request(requestId)).updated_at;
    const result = (await must(
      admin.rpc("approve_and_order_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _expected_updated_at: version,
        _staff_visible_note: "Ordered, arriving Tuesday",
        _internal_note: "PO 77",
      }),
    )) as Record<string, unknown>;
    assert.equal(result.status, "ordered");
    assert.equal(result.compoundAction, "approve_and_order");
    assert.equal(result.alreadyApplied, false);

    const rows = await history(requestId);
    assert.deepEqual(
      rows.map((row) => `${row.status_to}:${row.compound_action}`),
      ["under_review:approve_and_order", "approved:approve_and_order", "ordered:approve_and_order"],
    );
    assert.deepEqual(
      rows.map((row) => row.staff_visible_note),
      [null, null, "Ordered, arriving Tuesday"],
    );
    assert.equal(new Set(rows.map((row) => row.created_at)).size, 1);
    assert.ok((await request(requestId)).ordered_at);
    const commitment = await must(
      service
        .from("supply_request_commitments")
        .select("status")
        .eq("supply_request_id", requestId),
    );
    assert.deepEqual(
      commitment.map((row) => row.status),
      ["active"],
    );
    assert.deepEqual(await events(requestId), ["request_approved", "request_submitted"]);

    // Double tap: the second call is alreadyApplied and writes nothing.
    const retry = (await must(
      admin.rpc("approve_and_order_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _expected_updated_at: version,
      }),
    )) as Record<string, unknown>;
    assert.equal(retry.alreadyApplied, true);
    assert.equal((await history(requestId)).length, 3);

    const provider = new FakeEmailProvider();
    await cycle(provider);
    await cycle(provider);
    const toRequester = provider.sent.filter((message) => message.to === STAFF_EMAIL);
    const approvals = toRequester.filter((message) => /approved/i.test(message.subject));
    // One approval email for this request, plus the one for the request approved under Standard.
    assert.equal(approvals.length, 2, JSON.stringify(toRequester.map((m) => m.subject)));
    assert.equal(
      toRequester.filter((message) => /order|review|receiv|complet/i.test(message.subject)).length,
      0,
    );
    assert.equal((await events(requestId)).filter((type) => type === "request_approved").length, 1);

    // The staff timeline shows the bundle as one step with its note; staff never see internal notes.
    const staffRows = await must(
      staff.rpc("list_staff_supply_request_updates", {
        _organization_id: ORG,
        _request_ids: [requestId],
      }),
    );
    assert.equal(staffRows.length, 3);
    assert.ok(staffRows.every((row) => !("internal_note" in row)));
    const timeline = buildStaffRequestTimeline(
      (await request(requestId)).created_at,
      staffRows.map((row) => ({
        ...row,
        compound_action: parseCompoundAction(row.compound_action),
      })),
      "lean",
    );
    assert.deepEqual(
      timeline.map((item) => [item.label, item.message]),
      [
        ["Submitted", null],
        ["Approved & ordered", "Ordered, arriving Tuesday"],
      ],
    );
  },
);

test(
  "stale Approve & Order is refused immediately (no PostgREST retry) and writes nothing",
  { skip },
  async () => {
    const requestId = await submit("Lean stale");
    const started = Date.now();
    await refused(
      admin.rpc("approve_and_order_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _expected_updated_at: "2000-01-01T00:00:00Z",
      }),
      /changed while you were reviewing it/,
    );
    assert.ok(Date.now() - started < 3000, `refusal took ${Date.now() - started} ms`);
    assert.equal((await request(requestId)).status, "submitted");
    assert.equal((await history(requestId)).length, 0);
    await refused(
      staff.rpc("approve_and_order_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _expected_updated_at: (await request(requestId)).updated_at,
      }),
      /administrator access required/,
    );
    await refused(
      westOwner.rpc("approve_and_order_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _expected_updated_at: (await request(requestId)).updated_at,
      }),
      /administrator access required/,
    );
  },
);

test(
  "Receive & Complete: received_at, marked rows, no email; older requests stay actionable",
  { skip },
  async () => {
    const [ordered] = await must(
      service
        .from("supply_requests")
        .select("id")
        .eq("organization_id", ORG)
        .eq("status", "ordered"),
    );
    const result = (await must(
      admin.rpc("receive_and_complete_supply_request", {
        _organization_id: ORG,
        _request_id: ordered.id,
        _staff_visible_note: "In the cage",
        _inventory_location_id: await unassigned(),
      } as never),
    )) as Record<string, unknown>;
    assert.equal(result.status, "completed");
    assert.equal(result.compoundAction, "receive_and_complete");
    assert.ok((await request(ordered.id)).received_at);
    const rows = await history(ordered.id);
    assert.deepEqual(
      rows
        .slice(-2)
        .map((row) => `${row.status_to}:${row.compound_action}:${row.staff_visible_note}`),
      ["received:receive_and_complete:null", "completed:receive_and_complete:In the cage"],
    );
    const retry = (await must(
      admin.rpc("receive_and_complete_supply_request", {
        _organization_id: ORG,
        _request_id: ordered.id,
      }),
    )) as Record<string, unknown>;
    assert.equal(retry.alreadyApplied, true);

    const provider = new FakeEmailProvider();
    await cycle(provider);
    assert.equal(provider.sent.filter((message) => message.to === STAFF_EMAIL).length, 0);
    assert.deepEqual(await events(ordered.id), ["request_approved", "request_submitted"]);

    // The request approved under Standard: Mark Ordered (plain) still works in Lean.
    const [approved] = await must(
      service
        .from("supply_requests")
        .select("id")
        .eq("organization_id", ORG)
        .eq("status", "approved"),
    );
    await must(
      admin.rpc("transition_supply_request", {
        _organization_id: ORG,
        _request_id: approved.id,
        _status: "ordered",
      }),
    );
    assert.equal((await request(approved.id)).status, "ordered");
    assert.equal((await history(approved.id)).at(-1)?.compound_action, null);
  },
);

test(
  "profile gating: Standard refuses Approve & Order; Detailed refuses both; Mark Received works",
  { skip },
  async () => {
    await setProfile(admin, "standard");
    const requestId = await submit("Standard request");
    await refused(
      admin.rpc("approve_and_order_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _expected_updated_at: (await request(requestId)).updated_at,
      }),
      /Approve & Order is not enabled/,
    );
    await must(
      admin.rpc("decide_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _decision: "approved",
        _expected_updated_at: (await request(requestId)).updated_at,
      }),
    );
    await must(
      admin.rpc("transition_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _status: "ordered",
      }),
    );

    await setProfile(admin, "detailed");
    await refused(
      admin.rpc("receive_and_complete_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
      }),
      /Receive & Complete is not enabled/,
    );
    const received = (await must(
      admin.rpc("receive_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _inventory_location_id: await unassigned(),
      } as never),
    )) as Record<string, unknown>;
    assert.equal(received.status, "received");
    const again = (await must(
      admin.rpc("receive_supply_request", { _organization_id: ORG, _request_id: requestId }),
    )) as Record<string, unknown>;
    assert.equal(again.alreadyApplied, true);
    await refused(
      staff.rpc("receive_supply_request", { _organization_id: ORG, _request_id: requestId }),
      /administrator access required/,
    );
    assert.deepEqual(
      (await history(requestId)).map((row) => `${row.status_to}:${row.compound_action}`),
      ["under_review:null", "approved:null", "ordered:null", "received:null"],
    );
  },
);

test("provenance cannot be forged through the API", { skip }, async () => {
  const [row] = await must(
    service.from("supply_request_updates").select("id").not("compound_action", "is", null).limit(1),
  );
  await refused(
    admin.from("supply_request_updates").update({ compound_action: null }).eq("id", row.id),
    /Compound action provenance is written only by the request workflow/,
  );
});

test(
  "digest stays canonical: no transient entries, genuinely approved requests listed",
  { skip },
  async () => {
    await setProfile(admin, "lean");
    const bundled = await submit("Digest bundled");
    await must(
      admin.rpc("approve_and_order_supply_request", {
        _organization_id: ORG,
        _request_id: bundled,
        _expected_updated_at: (await request(bundled)).updated_at,
      }),
    );
    await setProfile(admin, "standard");
    const genuine = await submit("Digest genuinely approved");
    await must(
      admin.rpc("decide_supply_request", {
        _organization_id: ORG,
        _request_id: genuine,
        _decision: "approved",
        _expected_updated_at: (await request(genuine)).updated_at,
      }),
    );
    await setProfile(admin, "lean");
    const digest = (await must(
      service.rpc("notification_approver_digest_content", {
        _organization_id: ORG,
        _now: new Date().toISOString(),
        _threshold_days: 7,
      }),
    )) as { sections: Record<string, { items: { requestId: string }[] }> };
    assert.deepEqual(
      digest.sections.approvedNotOrdered.items.map((item) => item.requestId),
      [genuine],
    );
    assert.equal(digest.sections.underReview.items.length, 0);
  },
);

// Review fix: a stale Approve or Decline must answer at once with the non-retryable stale-screen
// error. SQLSTATE 40001 made PostgREST retry the call indefinitely (the request hung). The client
// here aborts after 5 s and the test after 20 s, so a regression fails fast instead of hanging.
const timedClient = (sub: string) =>
  createClient<Database>(REST_URL, "local-publishable-key", {
    global: {
      headers: { Authorization: `Bearer ${signToken({ role: "authenticated", sub })}` },
      fetch: (input, init) =>
        stripRestPrefix(input, { ...init, signal: AbortSignal.timeout(5000) }),
    },
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });

for (const [label, decision, note] of [
  ["Approve", "approved", null],
  ["Decline", "denied", "Use the stock in the cage"],
] as const) {
  test(
    `stale ${label} through PostgREST answers immediately with 55000 and writes nothing`,
    { skip, timeout: 20000 },
    async () => {
      const requestId = await submit(`Stale ${label}`);
      const seen = (await request(requestId)).updated_at;
      // The requester changes the request after the admin opened it.
      await must(
        staff.rpc("update_submitted_supply_request", {
          _organization_id: ORG,
          _request_id: requestId,
          _request_type: "reorder",
          _team_id: null,
          _location_id: null,
          _notes: "Changed after review opened",
          _items: [{ freeTextItem: `Stale ${label}`, quantity: 3 }],
        } as never),
      );
      assert.notEqual((await request(requestId)).updated_at, seen);
      const started = Date.now();
      const { error } = await timedClient(ADMIN).rpc("decide_supply_request", {
        _organization_id: ORG,
        _request_id: requestId,
        _decision: decision,
        ...(note ? { _staff_visible_note: note } : {}),
        _expected_updated_at: seen,
      });
      const elapsed = Date.now() - started;
      assert.ok(error, "the stale decision must be refused");
      assert.equal(
        error.code,
        "55000",
        `expected the non-retryable stale-screen code, got ${error.code}: ${error.message}`,
      );
      assert.match(error.message, /This request changed while you were reviewing it/);
      assert.ok(elapsed < 2000, `stale ${label} took ${elapsed} ms`);
      assert.equal((await request(requestId)).status, "submitted");
      assert.deepEqual(
        (await history(requestId)).map((row) => row.status_to),
        [null],
      );
      assert.deepEqual(await events(requestId), ["request_submitted"]);
      assert.equal(
        (
          await must(
            service
              .from("supply_request_commitments")
              .select("id")
              .eq("supply_request_id", requestId),
          )
        ).length,
        0,
      );
      // The refreshed screen decides normally.
      await must(
        admin.rpc("decide_supply_request", {
          _organization_id: ORG,
          _request_id: requestId,
          _decision: decision,
          ...(note ? { _staff_visible_note: note } : {}),
          _expected_updated_at: (await request(requestId)).updated_at,
        }),
      );
      assert.equal((await request(requestId)).status, decision);
    },
  );
}

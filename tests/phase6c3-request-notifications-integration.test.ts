// Phase 6C.3 integration: request notifications through the real server path, against a local
// Postgres (every migration applied) behind a real PostgREST, with supabase-js and signed JWTs.
// Started by supabase/tests/run_phase6c3_notifications_integration.sh; skipped by `npm test`.
//
// Exercised for real: the request RPCs the app's server functions call (submit, requester edit
// and cancel, admin decision, lifecycle transitions), the settings RPCs with RLS and role
// switching, and the notification cycle (src/notifications/worker.ts) over the service-role
// store (src/notifications/supabase-store.ts) with a locally signed service-role JWT.
// Stand-in: the email provider (in-memory FakeEmailProvider; nothing is sent anywhere).
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

const REST_URL = process.env.MEDSPEND_ITEST_REST_URL ?? "";
const JWT_SECRET = process.env.MEDSPEND_ITEST_JWT_SECRET ?? "";
const configured = Boolean(REST_URL && JWT_SECRET);
if (configured && !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(REST_URL)) {
  throw new Error(`Refusing to run integration tests against a non-local address: ${REST_URL}`);
}
const skip = configured ? false : "needs supabase/tests/run_phase6c3_notifications_integration.sh";

const id = (suffix: string) => `6c3e0000-0000-4000-8000-000000000${suffix}`;
const OWNER = id("001");
const ADMIN = id("002");
const STAFF = id("003");
const STAFF_TWO = id("004");
const INACTIVE_ADMIN = id("005");
const ADMIN_TWO = id("006");
const WEST_OWNER = id("007");
const WEST_STAFF = id("008");
const ORG = id("101");
const WEST = id("102");
const TAPE = id("601");
const email = (n: number) => `itest-6c3-${n}@example.invalid`;
const APP = "https://app.example.test";

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
const westStaff = configured ? as(WEST_STAFF) : (null as never);
// The worker's client, exactly as the scheduled handler builds it (service-role key).
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
async function submit(
  client: SupabaseClient<Database>,
  organizationId: string,
  items: unknown[],
  notes: string | null = null,
) {
  return must(
    client.rpc("submit_supply_request", {
      _organization_id: organizationId,
      _request_type: "reorder",
      _team_id: null as unknown as string,
      _location_id: null as unknown as string,
      _notes: notes as unknown as string,
      _items: items as never,
    }),
  ) as Promise<string>;
}
async function updatedAt(requestId: string) {
  const row = await must(
    service.from("supply_requests").select("updated_at").eq("id", requestId).single(),
  );
  return row.updated_at;
}
async function decide(
  requestId: string,
  decision: "approved" | "denied",
  staffNote?: string,
  internalNote?: string,
  organizationId = ORG,
  client = admin,
) {
  return must(
    client.rpc("decide_supply_request", {
      _organization_id: organizationId,
      _request_id: requestId,
      _decision: decision,
      _expected_updated_at: await updatedAt(requestId),
      ...(staffNote ? { _staff_visible_note: staffNote } : {}),
      ...(internalNote ? { _internal_note: internalNote } : {}),
    } as never),
  );
}
async function transition(
  requestId: string,
  status: string,
  staffNote?: string,
  internalNote?: string,
) {
  return must(
    admin.rpc("transition_supply_request", {
      _organization_id: ORG,
      _request_id: requestId,
      _status: status,
      ...(staffNote ? { _staff_visible_note: staffNote } : {}),
      ...(internalNote ? { _internal_note: internalNote } : {}),
    } as never),
  );
}
async function cycle(provider: FakeEmailProvider, now?: Date) {
  return runNotificationCycle({
    store,
    provider,
    sender: NOTIFICATION_SENDER,
    appBaseUrl: APP,
    batchSize: 5,
    maxBatches: 50,
    ...(now ? { now: () => now } : {}),
  });
}
async function eventsFor(requestId: string) {
  return must(
    service.from("notification_events").select("*").eq("entity_id", requestId).order("event_type"),
  );
}
async function deliveriesFor(requestId: string) {
  const events = await eventsFor(requestId);
  if (events.length === 0) return [];
  return must(
    service
      .from("notification_deliveries")
      .select("*")
      .in(
        "event_id",
        events.map((event) => event.id),
      ),
  );
}
const sentTo = (provider: FakeEmailProvider) =>
  provider.sent.map((message) => `${message.to}|${message.subject}`).sort();
async function setDigest(
  client: SupabaseClient<Database>,
  organizationId: string,
  enabled: boolean,
  frequency = "daily",
  hour = 8,
  weekday = 1,
  timezone = "America/New_York",
) {
  return must(
    client.rpc("update_organization_notification_settings", {
      _organization_id: organizationId,
      _digest_enabled: enabled,
      _digest_frequency: frequency,
      _digest_send_hour: hour,
      _digest_weekday: weekday,
      _timezone: timezone,
    }),
  );
}

test(
  "master sending switch OFF: events recorded, nothing delivered, never replayed",
  { skip },
  async () => {
    // Digests are off for the immediate-notification tests (enabled in the digest test below).
    await setDigest(owner, ORG, false);
    await setDigest(westOwner, WEST, false, "daily", 8, 1, "America/Los_Angeles");
    const requestId = await submit(staff, ORG, [{ freeTextItem: "Before rollout", quantity: 1 }]);
    const provider = new FakeEmailProvider();
    const result = await cycle(provider);
    assert.equal(result.sent, 0);
    assert.equal(provider.attempts.length, 0);
    const [event] = await eventsFor(requestId);
    assert.equal(event.status, "suppressed");
    assert.equal(event.status_reason, "sending_disabled");
    assert.equal((await deliveriesFor(requestId)).length, 0);

    await must(
      service.rpc("set_organization_notification_sending", {
        _organization_id: ORG,
        _enabled: true,
      }),
    );
    await must(
      service.rpc("set_organization_notification_sending", {
        _organization_id: WEST,
        _enabled: true,
      }),
    );
    const later = new FakeEmailProvider();
    await cycle(later);
    assert.equal(
      later.attempts.length,
      0,
      "suppressed events are not sent after the switch turns on",
    );
  },
);

test(
  "new submission: one email to every active admin (owner membership included), never staff or the actor",
  { skip },
  async () => {
    const requestId = await submit(
      staff,
      ORG,
      [
        { productId: TAPE, quantity: 4 },
        { freeTextItem: "Knee sleeve", quantity: 2 },
        { freeTextItem: "Ice bags", quantity: 10 },
      ],
      "For the away trip",
    );
    const provider = new FakeEmailProvider();
    await cycle(provider);
    assert.deepEqual(sentTo(provider), [
      `${email(1)}|New supply request from Itest User 3`,
      `${email(2)}|New supply request from Itest User 3`,
      `${email(6)}|New supply request from Itest User 3`,
    ]);
    const message = provider.sent[0];
    assert.equal(message.from, "SportSpend <notifications@notify.sport-spend.com>");
    assert.match(message.text, /4 roll × Athletic Tape/);
    assert.match(message.text, /2 × Knee sleeve/);
    assert.match(message.text, /10 × Ice bags/);
    assert.match(message.text, /Note: For the away trip/);
    assert.match(message.text, new RegExp(`${APP}/supply-requests\\?request=${requestId}`));
    assert.equal(new Set(provider.sent.map((m) => m.idempotencyKey)).size, 3);

    // An admin's own submission goes to the other admins only.
    const own = new FakeEmailProvider();
    await submit(admin, ORG, [{ freeTextItem: "Admin own", quantity: 1 }]);
    await cycle(own);
    assert.deepEqual(own.sent.map((m) => m.to).sort(), [email(1), email(6)]);
  },
);

test(
  "approval and denial: exactly one outcome email each, replays add nothing, internal notes never sent",
  { skip },
  async () => {
    const approveId = await submit(staff, ORG, [{ freeTextItem: "Approve me", quantity: 1 }]);
    const denyId = await submit(staff, ORG, [{ freeTextItem: "Deny me", quantity: 1 }]);
    await cycle(new FakeEmailProvider());

    await decide(approveId, "approved", "On its way", "INTERNAL-APPROVE-SECRET");
    const updates = await must(
      service.from("supply_request_updates").select("status_to").eq("supply_request_id", approveId),
    );
    assert.deepEqual(updates.map((u) => u.status_to).sort(), ["approved", "under_review"]);
    await decide(denyId, "denied", "Use the stock in the <cage> first", "INTERNAL-DENY-SECRET");
    // Replays (double tap / retried request) are idempotent in the lifecycle and here.
    await must(
      admin.rpc("decide_supply_request", {
        _organization_id: ORG,
        _request_id: approveId,
        _decision: "approved",
        _expected_updated_at: await updatedAt(approveId),
      } as never),
    );
    await must(
      admin.rpc("decide_supply_request", {
        _organization_id: ORG,
        _request_id: denyId,
        _decision: "denied",
        _staff_visible_note: "again",
        _expected_updated_at: await updatedAt(denyId),
      } as never),
    );

    const provider = new FakeEmailProvider();
    await cycle(provider);
    assert.deepEqual(sentTo(provider), [
      `${email(3)}|Your supply request was approved`,
      `${email(3)}|Your supply request was denied`,
    ]);
    const denied = provider.sent.find((m) => m.subject.endsWith("denied"))!;
    assert.match(denied.text, /Reason: Use the stock in the <cage> first/);
    assert.match(denied.html, /Use the stock in the &lt;cage&gt; first/);
    assert.match(denied.text, new RegExp(`${APP}/staff/requests/${denyId}`));
    for (const message of provider.sent)
      assert.doesNotMatch(message.html + message.text, /INTERNAL-/);
    assert.doesNotMatch(
      provider.sent.find((m) => m.subject.endsWith("approved"))!.text,
      /Reason|On its way/,
    );

    const approvedEvents = (await eventsFor(approveId)).map((e) => e.event_type);
    assert.deepEqual(
      approvedEvents,
      ["request_approved", "request_submitted"],
      "no under-review event",
    );
    const again = new FakeEmailProvider();
    await cycle(again);
    assert.equal(again.attempts.length, 0, "nothing left to send");
  },
);

test(
  "approved -> ordered -> denied: one corrective denial; intermediate states send nothing",
  { skip },
  async () => {
    const reversalId = await submit(staff, ORG, [{ freeTextItem: "Reverse me", quantity: 1 }]);
    const lifecycleId = await submit(staff, ORG, [{ freeTextItem: "Full lifecycle", quantity: 1 }]);
    await cycle(new FakeEmailProvider());
    await decide(reversalId, "approved");
    await transition(lifecycleId, "under_review", "Looking into it");
    await decide(lifecycleId, "approved");
    const first = new FakeEmailProvider();
    await cycle(first);
    assert.deepEqual(sentTo(first), [
      `${email(3)}|Your supply request was approved`,
      `${email(3)}|Your supply request was approved`,
    ]);
    await transition(reversalId, "ordered", "Ordered");
    await transition(reversalId, "denied", "Vendor discontinued it", "INTERNAL-REVERSAL");
    await transition(lifecycleId, "ordered", "Ordered");
    await transition(lifecycleId, "received", "Arrived");
    await transition(lifecycleId, "completed", "Picked up");
    const second = new FakeEmailProvider();
    await cycle(second);
    assert.deepEqual(sentTo(second), [`${email(3)}|Your supply request was denied`]);
    assert.match(second.sent[0].text, /Reason: Vendor discontinued it/);
    assert.doesNotMatch(second.sent[0].text, /INTERNAL/);
    assert.deepEqual(
      (await deliveriesFor(reversalId))
        .filter((d) => d.audience === "requester")
        .map((d) => d.status),
      ["sent", "sent"],
    );
  },
);

test(
  "requester edit and cancellation send nothing beyond the submission notice",
  { skip },
  async () => {
    const editId = await submit(staff, ORG, [{ freeTextItem: "Edit me", quantity: 1 }]);
    const cancelId = await submit(staff, ORG, [{ freeTextItem: "Cancel me", quantity: 1 }]);
    const first = new FakeEmailProvider();
    await cycle(first);
    assert.equal(first.sent.length, 6, "two submission notices to three admins");
    await must(
      staff.rpc("update_submitted_supply_request", {
        _organization_id: ORG,
        _request_id: editId,
        _request_type: null as never,
        _team_id: null as never,
        _location_id: null as never,
        _notes: "edited",
        _items: [{ freeTextItem: "Edited line", quantity: 9 }] as never,
      }),
    );
    await must(
      staff.rpc("cancel_submitted_supply_request", {
        _organization_id: ORG,
        _request_id: cancelId,
      }),
    );
    const second = new FakeEmailProvider();
    await cycle(second);
    assert.equal(second.attempts.length, 0);
    assert.equal((await eventsFor(editId)).length, 1);
    assert.equal((await eventsFor(cancelId)).length, 1);
  },
);

test(
  "eligibility is rechecked at delivery: deactivated and demoted admins are skipped",
  { skip },
  async () => {
    const requestId = await submit(staff, ORG, [{ freeTextItem: "Recheck", quantity: 1 }]);
    await store.dispatchEvents(100);
    assert.equal((await deliveriesFor(requestId)).length, 3);
    await must(
      service
        .from("organization_memberships")
        .update({ role: "staff" })
        .eq("organization_id", ORG)
        .eq("user_id", ADMIN_TWO),
    );
    const provider = new FakeEmailProvider();
    await cycle(provider);
    assert.deepEqual(provider.sent.map((m) => m.to).sort(), [email(1), email(2)]);
    const skipped = (await deliveriesFor(requestId)).find(
      (d) => d.recipient_user_id === ADMIN_TWO,
    )!;
    assert.equal(skipped.status, "skipped");
    assert.equal(skipped.status_reason, "recipient_not_admin");
    await must(
      service
        .from("organization_memberships")
        .update({ role: "admin" })
        .eq("organization_id", ORG)
        .eq("user_id", ADMIN_TWO),
    );

    const second = await submit(staff, ORG, [{ freeTextItem: "Recheck two", quantity: 1 }]);
    await store.dispatchEvents(100);
    await must(
      service
        .from("organization_memberships")
        .update({ active: false })
        .eq("organization_id", ORG)
        .eq("user_id", ADMIN_TWO),
    );
    const after = new FakeEmailProvider();
    await cycle(after);
    assert.deepEqual(after.sent.map((m) => m.to).sort(), [email(1), email(2)]);
    assert.equal(
      (await deliveriesFor(second)).find((d) => d.recipient_user_id === ADMIN_TWO)!.status_reason,
      "recipient_inactive",
    );
    await must(
      service
        .from("organization_memberships")
        .update({ active: true })
        .eq("organization_id", ORG)
        .eq("user_id", ADMIN_TWO),
    );
    // The inactive admin never received anything at all.
    const never = await must(
      service.from("notification_deliveries").select("id").eq("recipient_user_id", INACTIVE_ADMIN),
    );
    assert.equal(never.length, 0);
  },
);

test(
  "provider failures: retry with backoff, then dead-letter; a sent delivery is never resent",
  { skip },
  async () => {
    const requestId = await submit(staffTwo, ORG, [
      { freeTextItem: "Flaky provider", quantity: 1 },
    ]);
    const provider = new FakeEmailProvider(["retryable", "reject", "success"]);
    const result = await cycle(provider);
    assert.equal(result.sent, 1);
    assert.equal(result.retrying, 1);
    assert.equal(result.dead, 1);
    const deliveries = await deliveriesFor(requestId);
    const byStatus = Object.fromEntries(deliveries.map((d) => [d.status, d]));
    assert.ok(
      byStatus.pending && byStatus.dead && byStatus.sent,
      JSON.stringify(deliveries.map((d) => d.status)),
    );
    assert.equal(byStatus.pending.attempts, 1);
    assert.equal(byStatus.pending.status_reason, "retry_scheduled");
    assert.ok(
      new Date(byStatus.pending.next_attempt_at).getTime() > Date.now() + 30_000,
      "backoff scheduled",
    );
    assert.equal(byStatus.dead.status_reason, "rejected");
    assert.equal(byStatus.sent.provider, "fake");
    assert.match(String(byStatus.sent.provider_message_id), /^fake-/);
    // Not due yet: nothing is retried immediately.
    const immediate = new FakeEmailProvider();
    await cycle(immediate);
    assert.equal(immediate.attempts.length, 0);
  },
);

test("concurrent workers never send the same delivery twice", { skip }, async () => {
  const ids = [];
  for (let n = 0; n < 6; n += 1)
    ids.push(
      await submit(n % 2 ? staff : staffTwo, ORG, [{ freeTextItem: `Burst ${n}`, quantity: 1 }]),
    );
  const a = new FakeEmailProvider();
  const b = new FakeEmailProvider();
  const c = new FakeEmailProvider();
  await Promise.all([cycle(a), cycle(b), cycle(c)]);
  const all = [...a.sent, ...b.sent, ...c.sent];
  assert.equal(all.length, 18, "6 submissions x 3 admins");
  assert.equal(new Set(all.map((m) => m.idempotencyKey)).size, 18, "no delivery sent twice");
  const deliveries = (await Promise.all(ids.map(deliveriesFor))).flat();
  assert.equal(deliveries.length, 18);
  assert.ok(deliveries.every((d) => d.status === "sent" && d.attempts === 1));
});

test(
  "sending boundary: events raised while OFF never send after enabling, even if the Worker never ran",
  { skip },
  async () => {
    await must(
      service.rpc("set_organization_notification_sending", {
        _organization_id: WEST,
        _enabled: false,
      }),
    );
    const whileOff = await submit(westStaff, WEST, [
      { freeTextItem: "Raised while OFF", quantity: 1 },
    ]);
    // No Worker run while OFF; the operator turns sending back ON first.
    await must(
      service.rpc("set_organization_notification_sending", {
        _organization_id: WEST,
        _enabled: true,
      }),
    );
    const provider = new FakeEmailProvider();
    await cycle(provider);
    assert.equal(
      provider.sent.filter((m) => m.to === email(7)).length,
      0,
      "no email for an event raised while sending was OFF",
    );
    const [event] = await eventsFor(whileOff);
    assert.equal(event.status, "suppressed");
    assert.equal(event.status_reason, "created_before_sending_enabled");
    assert.equal((await deliveriesFor(whileOff)).length, 0);
  },
);

test("organization boundary: the other organization's admins only", { skip }, async () => {
  await submit(westStaff, WEST, [{ freeTextItem: "West line", quantity: 1 }]);
  const provider = new FakeEmailProvider();
  await cycle(provider);
  assert.deepEqual(
    provider.sent.map((m) => m.to),
    [email(7)],
  );
  assert.match(provider.sent[0].html, /Notify West/);
});

test(
  "admin settings: owner and admin may edit, staff and other organizations may not; master switch untouched",
  { skip },
  async () => {
    const saved = (await setDigest(admin, ORG, true, "weekly", 7, 3, "America/Chicago")) as Record<
      string,
      unknown
    >;
    assert.equal(saved.digestFrequency, "weekly");
    assert.equal(saved.sendingEnabled, true);
    const read = (await must(
      owner.rpc("get_organization_notification_settings", { _organization_id: ORG }),
    )) as Record<string, unknown>;
    assert.equal(read.timezone, "America/Chicago");
    for (const [client, organizationId] of [
      [staff, ORG],
      [westOwner, ORG],
      [westStaff, WEST],
    ] as const) {
      const { error } = await client.rpc("update_organization_notification_settings", {
        _organization_id: organizationId,
        _digest_enabled: false,
        _digest_frequency: "daily",
        _digest_send_hour: 8,
        _digest_weekday: 1,
        _timezone: "UTC",
      });
      assert.match(String(error?.message), /Forbidden/);
    }
    const bad = await admin.rpc("update_organization_notification_settings", {
      _organization_id: ORG,
      _digest_enabled: true,
      _digest_frequency: "daily",
      _digest_send_hour: 8,
      _digest_weekday: 1,
      _timezone: "Mars/Phobos",
    });
    assert.match(String(bad.error?.message), /Choose a supported time zone/);
    const master = await admin.rpc("set_organization_notification_sending", {
      _organization_id: ORG,
      _enabled: false,
    });
    assert.ok(master.error, "admins cannot flip the master switch");
  },
);

test(
  "ordinary clients cannot read notification records, claim, mark, or read auth emails",
  { skip },
  async () => {
    for (const client of [owner, admin, staff]) {
      for (const table of [
        "notification_events",
        "notification_deliveries",
        "organization_notification_settings",
      ] as const) {
        const { error } = await client
          .from(table as never)
          .select("*")
          .limit(1);
        assert.match(String(error?.message), /permission denied/, table);
      }
      for (const [fn, args] of [
        ["claim_notification_deliveries", {}],
        ["dispatch_notification_events", {}],
        ["enqueue_due_notification_digests", {}],
        [
          "complete_notification_delivery",
          { _delivery_id: id("999"), _claim_token: id("998"), _outcome: "sent" },
        ],
      ] as const) {
        const { error } = await client.rpc(fn as never, args as never);
        assert.match(String(error?.message), /permission denied/, fn);
      }
    }
    const anon = clientFor({ role: "anon" });
    const { error } = await anon.rpc("get_organization_notification_settings", {
      _organization_id: ORG,
    });
    assert.match(String(error?.message), /permission denied/);
  },
);

test(
  "digest: organization-local schedule, mixed request states, one per period, preference and master switch",
  { skip },
  async () => {
    // Organization 101 in New York (daily 08:00), 102 in Los Angeles (daily 08:00).
    await setDigest(admin, ORG, true, "daily", 8, 1, "America/New_York");
    await setDigest(westOwner, WEST, true, "daily", 8, 1, "America/Los_Angeles");
    // Mixed states in organization 101: one ordered 10 days ago without receipt, one received.
    const orderedId = await submit(staff, ORG, [{ freeTextItem: "Long order", quantity: 1 }]);
    await decide(orderedId, "approved");
    await transition(orderedId, "ordered");
    await must(
      service
        .from("supply_requests")
        .update({ ordered_at: new Date(Date.now() - 10 * 86_400_000).toISOString() })
        .eq("id", orderedId),
    );
    const nyEight = new Date("2027-01-05T13:00:00Z"); // Tuesday 08:00 EST; 05:00 in Los Angeles
    const before = new FakeEmailProvider();
    await cycle(before, new Date("2027-01-05T12:59:00Z"));
    assert.equal(
      before.sent.filter((m) => /need/.test(m.subject)).length,
      0,
      "not before 08:00 local",
    );
    const provider = new FakeEmailProvider();
    const result = await cycle(provider, nyEight);
    assert.equal(result.digestsEnqueued, 1, "New York due, Los Angeles not yet");
    const digests = provider.sent.filter((m) => /need/.test(m.subject));
    assert.deepEqual(digests.map((m) => m.to).sort(), [email(1), email(2), email(6)]);
    assert.match(digests[0].text, /Awaiting review: \d+/);
    assert.match(digests[0].text, /Ordered, not yet received after 7 days: 1/);
    assert.doesNotMatch(digests[0].text, /Long order.*cancelled|budget|inventory/i);
    // Retries and overlapping workers in the same period add nothing.
    const retry = new FakeEmailProvider();
    // (15:00Z is 10:00 in New York and still 07:00 in Los Angeles.)
    await Promise.all([cycle(retry, nyEight), cycle(retry, new Date("2027-01-05T15:00:00Z"))]);
    assert.equal(retry.sent.filter((m) => /need/.test(m.subject)).length, 0);
    // Los Angeles at its own 08:00.
    const west = new FakeEmailProvider();
    await cycle(west, new Date("2027-01-05T16:00:00Z"));
    assert.deepEqual(
      west.sent.filter((m) => /need/.test(m.subject)).map((m) => m.to),
      [email(7)],
    );

    // Preference change: weekly on Wednesday; Thursday sends nothing, the next Wednesday sends.
    await setDigest(admin, ORG, true, "weekly", 8, 3, "America/New_York");
    const thursday = new FakeEmailProvider();
    await cycle(thursday, new Date("2027-01-07T13:00:00Z"));
    assert.equal(thursday.sent.filter((m) => /need/.test(m.subject)).length, 0);
    const wednesday = new FakeEmailProvider();
    await cycle(wednesday, new Date("2027-01-13T13:00:00Z"));
    assert.equal(wednesday.sent.filter((m) => /need/.test(m.subject)).length, 3);

    // Digest off, then master off: nothing.
    await setDigest(admin, ORG, false, "daily", 8, 1, "America/New_York");
    const off = new FakeEmailProvider();
    await cycle(off, new Date("2027-01-14T13:00:00Z"));
    assert.equal(off.sent.filter((m) => /need/.test(m.subject)).length, 0);
    await must(
      service.rpc("set_organization_notification_sending", {
        _organization_id: WEST,
        _enabled: false,
      }),
    );
    const westOff = new FakeEmailProvider();
    await cycle(westOff, new Date("2027-01-14T16:00:00Z"));
    assert.equal(westOff.attempts.length, 0, "master switch overrides the digest preference");
  },
);

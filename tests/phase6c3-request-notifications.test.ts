// Phase 6C.3: request notifications and approver digests. Templates (escaping, plain text, no
// internal notes), the Resend and fake adapters, runtime configuration (fail safe, no secrets
// in output), the delivery cycle against an in-memory store, settings parsing, the rendered
// admin Settings section, and structural checks of the migration, Worker trigger and wiring.
// Database behavior: supabase/tests/phase6c3_request_notifications_behavior.sql (+ race and
// mutation checks); the real RPC path with JWTs: run_phase6c3_notifications_integration.sh;
// the built Worker's scheduled() in workerd: scripts/worker-scheduled-check.sh.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import test, { after } from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { resolveNotificationConfig } from "../src/notifications/config.ts";
import {
  FakeEmailProvider,
  createSinkEmailProvider,
  isLoopbackUrl,
} from "../src/notifications/providers/fake.ts";
import { RESEND_API_URL, createResendProvider } from "../src/notifications/providers/resend.ts";
import { runScheduledNotifications } from "../src/notifications/scheduled.server.ts";
import {
  DEFAULT_NOTIFICATION_SETTINGS,
  SUPPORTED_TIMEZONES,
  digestScheduleSummary,
  formatSendHour,
  isSupportedTimezone,
  parseNotificationSettings,
} from "../src/notifications/settings.ts";
import {
  NOTIFICATION_SENDER,
  escapeHtml,
  renderNotificationEmail,
} from "../src/notifications/templates.ts";
import type {
  ClaimedDelivery,
  DigestNotificationContext,
  EmailMessage,
  NotificationStore,
  RequestNotificationContext,
} from "../src/notifications/types.ts";
import { runNotificationCycle } from "../src/notifications/worker.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const migration = read("supabase/migrations/20261110120000_phase6c3_request_notifications.sql");
const migrationCode = migration.replace(/--.*$/gm, "");
const functionBody = (name: string) => {
  const start = migration.indexOf(`CREATE FUNCTION public.${name}(`);
  assert.ok(start >= 0, name);
  return migration.slice(start, migration.indexOf("\n$$;", start));
};

// Bundle the Settings section for rendering BEFORE any test is registered (as in the 7B.5
// test): the runner can only start tests, and therefore only run the cleanup below, once the
// bundle is fully written and loaded. The directory is per process, so concurrent runs of this
// file cannot delete each other's bundle.
const cacheDir = join(root, `node_modules/.cache/phase6c3-notifications-test-${process.pid}`);
mkdirSync(cacheDir, { recursive: true });
const pending = "() => new Promise(() => {})";
const stubs: Record<string, string> = {
  "@tanstack/react-start": `export const useServerFn = (fn) => fn;`,
  "@/lib/notification-settings.functions": `export const getNotificationSettingsFn = ${pending}, updateNotificationSettingsFn = ${pending};`,
};
function resolveSource(base: string) {
  for (const candidate of [`${base}.ts`, `${base}.tsx`, join(base, "index.ts"), base]) {
    if (existsSync(candidate)) return candidate;
  }
  throw new Error(`Cannot resolve ${base}`);
}
const entry = join(cacheDir, "entry.tsx");
writeFileSync(
  entry,
  `
  import { createElement } from "react";
  import { renderToStaticMarkup } from "react-dom/server";
  import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
  export { NotificationSettingsForm, NotificationSettings } from "@/components/settings/NotificationSettings";
  export function render(component, props) {
    return renderToStaticMarkup(
      createElement(QueryClientProvider, { client: new QueryClient() }, createElement(component, props)));
  }
`,
);
const bundlePath = join(cacheDir, "bundle.cjs");
await build({
  entryPoints: [entry],
  bundle: true,
  format: "cjs",
  platform: "node",
  jsx: "automatic",
  packages: "external",
  outfile: bundlePath,
  logLevel: "silent",
  plugins: [
    {
      name: "notification-stubs",
      setup(pluginBuild) {
        pluginBuild.onResolve({ filter: /.*/ }, (args) => {
          if (args.path in stubs) return { path: args.path, namespace: "stub" };
          if (args.path.startsWith("@/"))
            return { path: resolveSource(join(root, "src", args.path.slice(2))) };
          return undefined;
        });
        pluginBuild.onLoad({ filter: /.*/, namespace: "stub" }, (args) => ({
          contents: stubs[args.path],
          loader: "jsx",
          resolveDir: root,
        }));
      },
    },
  ],
});
const ui = createRequire(import.meta.url)(bundlePath);
// Registered only after the bundle has been loaded into memory.
after(() => rmSync(cacheDir, { recursive: true, force: true }));
const render = (component: unknown, props: Record<string, unknown>) =>
  ui.render(component, props) as string;
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/&#x27;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ");

const APP = "https://app.example.test";
const NOW = new Date("2026-11-10T15:00:00Z");

const requestContext = (
  overrides: Partial<RequestNotificationContext> = {},
): RequestNotificationContext => ({
  organizationName: "FC Example",
  recipientName: "Ada Admin",
  audience: "approver",
  timezone: "America/New_York",
  requestId: "3a6d9272-9ec7-4777-b912-35962b9f2826",
  reference: "3A6D9272",
  requestType: "reorder",
  submittedAt: "2026-11-10T14:05:00Z",
  requesterName: "Sam Staff",
  items: {
    itemCount: 3,
    items: [
      { label: "Athletic Tape", quantity: 4, unit: "roll" },
      { label: "Knee sleeve", quantity: 2, unit: null },
      { label: "Ice bags", quantity: 10, unit: null },
    ],
  },
  requestNote: null,
  ...overrides,
});
const digestContext = (
  overrides: Partial<DigestNotificationContext> = {},
): DigestNotificationContext => ({
  organizationName: "FC Example",
  recipientName: "Ada Admin",
  audience: "approver",
  localDate: "2026-11-10",
  frequency: "daily",
  timezone: "America/New_York",
  digest: {
    totalCount: 4,
    thresholdDays: 7,
    sections: {
      awaitingReview: {
        count: 2,
        oldestAt: "2026-11-07T15:00:00Z",
        items: [
          {
            requestId: "r1",
            reference: "AAAA1111",
            requesterName: "Sam <Staff>",
            since: "2026-11-07T15:00:00Z",
            items: { itemCount: 2, items: [{ label: "Tape", quantity: 1, unit: null }] },
          },
        ],
      },
      underReview: { count: 0, oldestAt: null, items: [] },
      approvedNotOrdered: {
        count: 1,
        oldestAt: "2026-11-09T15:00:00Z",
        items: [
          {
            requestId: "r2",
            reference: "BBBB2222",
            requesterName: "Lee",
            since: "2026-11-09T15:00:00Z",
            items: { itemCount: 1, items: [{ label: "Gauze", quantity: 3, unit: "box" }] },
          },
        ],
      },
      orderedNotReceived: {
        count: 1,
        oldestAt: "2026-11-01T15:00:00Z",
        items: [
          {
            requestId: "r3",
            reference: "CCCC3333",
            requesterName: "Kim",
            since: "2026-11-01T15:00:00Z",
            items: { itemCount: 1, items: [{ label: "Ice", quantity: 1, unit: null }] },
          },
        ],
      },
    },
  },
  ...overrides,
});

// ------------------------------------------------------------------------------------------
// Templates
// ------------------------------------------------------------------------------------------
test("admin submission email: requester, items, submitted time, link, escaped", () => {
  const email = renderNotificationEmail(
    {
      eventType: "request_submitted",
      context: requestContext({
        requesterName: "Sam <script>alert(1)</script>",
        requestNote: "Need it <b>tonight</b> & weekend",
        items: {
          itemCount: 12,
          items: [{ label: 'Tape "Pro" <x>', quantity: 4, unit: "roll" }],
        },
      }),
    },
    { appBaseUrl: APP, now: NOW },
  );
  assert.equal(email.subject, "New supply request from Sam <script>alert(1)</script>");
  assert.doesNotMatch(email.html, /<script>/);
  assert.match(email.html, /Sam &lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(email.html, /Tape &quot;Pro&quot; &lt;x&gt;/);
  assert.match(email.html, /Need it &lt;b&gt;tonight&lt;\/b&gt; &amp; weekend/);
  assert.match(email.html, /and 11 more items/);
  assert.match(
    email.html,
    /href="https:\/\/app\.example\.test\/supply-requests\?request=3a6d9272-9ec7-4777-b912-35962b9f2826"/,
  );
  assert.match(email.html, /Nov 10, 2026, 9:05 AM EST/);
  assert.match(email.text, /4 roll × Tape "Pro" <x>/);
  assert.match(
    email.text,
    /Review request: https:\/\/app\.example\.test\/supply-requests\?request=/,
  );
  assert.match(email.text, /submitted a supply request \(3A6D9272\) on Nov 10, 2026, 9:05 AM EST/);
});

test("subjects and plain text never carry control characters or line breaks", () => {
  const email = renderNotificationEmail(
    {
      eventType: "request_submitted",
      context: requestContext({ requesterName: "Sam\r\nBcc: x@y" }),
    },
    { appBaseUrl: APP },
  );
  assert.doesNotMatch(email.subject, /[\r\n]/);
  assert.equal(email.subject, "New supply request from Sam Bcc: x@y");
});

test("approval email: simple outcome, reference, staff link, no notes", () => {
  const email = renderNotificationEmail(
    {
      eventType: "request_approved",
      context: requestContext({
        audience: "requester",
        recipientName: "Sam",
        staffVisibleNote: "should not show",
      }),
    },
    { appBaseUrl: APP },
  );
  assert.equal(email.subject, "Your supply request was approved");
  assert.match(email.text, /approved and is being processed/);
  assert.match(email.text, /Request 3A6D9272: Athletic Tape and 2 more/);
  assert.match(
    email.text,
    /View request: https:\/\/app\.example\.test\/staff\/requests\/3a6d9272-/,
  );
  assert.doesNotMatch(email.html + email.text, /should not show|Reason/);
  assert.doesNotMatch(email.text, /ordered|received|completed/i);
});

test("denial email: staff-visible reason when present, escaped; none otherwise", () => {
  const withReason = renderNotificationEmail(
    {
      eventType: "request_denied",
      context: requestContext({
        audience: "requester",
        staffVisibleNote: "Use the cage <b>stock</b> & ask",
      }),
    },
    { appBaseUrl: APP },
  );
  assert.equal(withReason.subject, "Your supply request was denied");
  assert.match(withReason.html, /Reason:<\/span> Use the cage &lt;b&gt;stock&lt;\/b&gt; &amp; ask/);
  assert.match(withReason.text, /Reason: Use the cage <b>stock<\/b> & ask/);
  const withoutReason = renderNotificationEmail(
    {
      eventType: "request_denied",
      context: requestContext({ audience: "requester", staffVisibleNote: null }),
    },
    { appBaseUrl: APP },
  );
  assert.doesNotMatch(withoutReason.text, /Reason/);
});

test("internal notes cannot reach a template: contexts never carry them", () => {
  // The claim function builds contexts; it never reads internal_note.
  assert.doesNotMatch(functionBody("claim_notification_deliveries"), /internal_note/);
  assert.match(functionBody("claim_notification_deliveries"), /staff_visible_note/);
  // Even if a stray field appeared, templates only render whitelisted fields.
  const email = renderNotificationEmail(
    {
      eventType: "request_denied",
      context: {
        ...requestContext({ audience: "requester" }),
        internalNote: "SECRET",
      } as RequestNotificationContext,
    },
    { appBaseUrl: APP },
  );
  assert.doesNotMatch(email.html + email.text, /SECRET/);
});

test("approver digest: actionable sections only, counts, oldest age, links, settings link", () => {
  const email = renderNotificationEmail(
    { eventType: "approver_digest", context: digestContext() },
    { appBaseUrl: APP, now: NOW },
  );
  assert.equal(email.subject, "4 supply requests need attention");
  assert.match(email.text, /Awaiting review: 2 \(oldest 3 days\)/);
  assert.match(email.text, /- and 1 more/);
  assert.doesNotMatch(email.text, /Under review/);
  assert.match(email.text, /Approved, not yet ordered: 1/);
  assert.match(email.text, /Ordered, not yet received after 7 days: 1 \(oldest 9 days\)/);
  assert.match(email.html, /queue=needsReview/);
  assert.match(email.html, /queue=awaitingOrder/);
  assert.match(email.html, /queue=awaitingDelivery/);
  assert.match(email.html, /Sam &lt;Staff&gt;/);
  assert.match(email.text, /Change digest settings: https:\/\/app\.example\.test\/settings/);
  assert.doesNotMatch(email.text, /budget|inventory/i);
  const one = renderNotificationEmail(
    {
      eventType: "approver_digest",
      context: digestContext({
        digest: { ...digestContext().digest, totalCount: 1 },
      }),
    },
    { appBaseUrl: APP, now: NOW },
  );
  assert.equal(one.subject, "1 supply request needs attention");
});

test("escapeHtml covers the five HTML metacharacters", () => {
  assert.equal(
    escapeHtml(`<a href="x">'&'</a>`),
    "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;",
  );
});

// ------------------------------------------------------------------------------------------
// Providers
// ------------------------------------------------------------------------------------------
const message: EmailMessage = {
  from: NOTIFICATION_SENDER,
  to: "ada@example.test",
  subject: "Subject",
  html: "<p>x</p>",
  text: "x",
  idempotencyKey: "notification-delivery-d1",
};

test("Resend adapter: HTTP API call, idempotency key, message id", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const provider = createResendProvider({
    apiKey: "re_test_secret_value",
    fetch: async (url, init) => {
      calls.push({ url: String(url), init: init! });
      return new Response(JSON.stringify({ id: "msg_123" }), { status: 200 });
    },
  });
  const result = await provider.send(message);
  assert.deepEqual(result, { ok: true, provider: "resend", messageId: "msg_123" });
  assert.equal(calls[0].url, RESEND_API_URL);
  const headers = new Headers(calls[0].init.headers);
  assert.equal(headers.get("authorization"), "Bearer re_test_secret_value");
  assert.equal(headers.get("idempotency-key"), "notification-delivery-d1");
  assert.deepEqual(JSON.parse(String(calls[0].init.body)), {
    from: "SportSpend <notifications@notify.sport-spend.com>",
    to: ["ada@example.test"],
    subject: "Subject",
    html: "<p>x</p>",
    text: "x",
  });
});

test("Resend adapter: classifies failures and never leaks the key", async () => {
  const cases: [number, boolean][] = [
    [500, true],
    [503, true],
    [429, true],
    [409, true],
    [422, false],
    [401, false],
    [403, false],
  ];
  for (const [status, retryable] of cases) {
    const provider = createResendProvider({
      apiKey: "re_test_secret_value",
      fetch: async () => new Response(JSON.stringify({ message: "nope" }), { status }),
    });
    const result = await provider.send(message);
    assert.equal(result.ok, false);
    if (!result.ok) {
      assert.equal(result.retryable, retryable, `status ${status}`);
      assert.equal(result.error, `HTTP ${status}: nope`);
      assert.doesNotMatch(JSON.stringify(result), /re_test_secret_value/);
    }
  }
  const network = await createResendProvider({
    apiKey: "re_test_secret_value",
    fetch: async () => {
      throw new TypeError("fetch failed re_test_secret_value");
    },
  }).send(message);
  assert.deepEqual(network, {
    ok: false,
    provider: "resend",
    retryable: true,
    error: "network error: TypeError",
  });
  const timeout = await createResendProvider({
    apiKey: "k",
    timeoutMs: 20,
    fetch: (_url, init) =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () =>
          reject(new DOMException("aborted", "AbortError")),
        );
      }),
  }).send(message);
  assert.deepEqual(timeout, {
    ok: false,
    provider: "resend",
    retryable: true,
    error: "timeout after 20 ms",
  });
  assert.throws(() => createResendProvider({ apiKey: "" }), /not configured/);
});

test("fake provider: success, rejection, retryable failure, timeout, recorded attempts", async () => {
  const fake = new FakeEmailProvider(["reject", "retryable", "timeout"]);
  assert.deepEqual(await fake.send(message), {
    ok: false,
    provider: "fake",
    retryable: false,
    error: "HTTP 422: invalid recipient",
  });
  assert.equal(((await fake.send(message)) as { retryable: boolean }).retryable, true);
  assert.equal(((await fake.send(message)) as { error: string }).error, "timeout after 10000 ms");
  assert.deepEqual(await fake.send(message), { ok: true, provider: "fake", messageId: "fake-1" });
  assert.equal(fake.sent.length, 1);
  assert.deepEqual(
    fake.attempts.map((attempt) => attempt.outcome),
    ["reject", "retryable", "timeout", "success"],
  );
});

test("sink provider: loopback only; endpoint reply decides the outcome", async () => {
  assert.equal(isLoopbackUrl("http://127.0.0.1:9999/sink"), true);
  assert.equal(isLoopbackUrl("http://localhost:1/x"), true);
  assert.equal(isLoopbackUrl("https://127.0.0.1/x"), false);
  assert.equal(isLoopbackUrl("http://example.com/x"), false);
  assert.throws(() => createSinkEmailProvider("https://api.resend.com/emails"), /loopback/);
  const replies = [
    { outcome: "success", id: "sink-1" },
    { outcome: "reject" },
    { outcome: "retryable" },
  ];
  const posted: unknown[] = [];
  const sink = createSinkEmailProvider("http://127.0.0.1:9/sink", async (_url, init) => {
    posted.push(JSON.parse(String(init?.body)));
    return new Response(JSON.stringify(replies.shift()), { status: 200 });
  });
  assert.deepEqual(await sink.send(message), { ok: true, provider: "fake", messageId: "sink-1" });
  assert.equal(((await sink.send(message)) as { retryable: boolean }).retryable, false);
  assert.equal(((await sink.send(message)) as { retryable: boolean }).retryable, true);
  assert.equal((posted[0] as EmailMessage).to, "ada@example.test");
});

// ------------------------------------------------------------------------------------------
// Configuration and the scheduled entry point (fail safe)
// ------------------------------------------------------------------------------------------
test("config: missing secrets are reported by name only", () => {
  const missing = resolveNotificationConfig({});
  assert.deepEqual(missing, {
    ok: false,
    reason: "notification bindings are not configured",
    missing: ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "RESEND_API_KEY"],
  });
  const fallback = resolveNotificationConfig(
    { SUPABASE_SERVICE_ROLE_KEY: "service-secret", RESEND_API_KEY: "re_secret" },
    "https://project.supabase.co",
  );
  assert.equal(fallback.ok, true);
  if (fallback.ok) {
    assert.equal(fallback.config.supabaseUrl, "https://project.supabase.co");
    assert.equal(fallback.config.appBaseUrl, "https://app.sport-spend.com");
    assert.deepEqual(fallback.config.provider, { kind: "resend", apiKey: "re_secret" });
  }
  assert.deepEqual(
    resolveNotificationConfig({
      SUPABASE_URL: "http://127.0.0.1:1",
      SUPABASE_SERVICE_ROLE_KEY: "k",
      NOTIFICATIONS_EMAIL_PROVIDER: "fake",
      NOTIFICATIONS_FAKE_EMAIL_ENDPOINT: "https://evil.example/sink",
    }),
    {
      ok: false,
      reason: "NOTIFICATIONS_FAKE_EMAIL_ENDPOINT must be a loopback http URL",
      missing: [],
    },
  );
  assert.equal(
    resolveNotificationConfig({
      SUPABASE_URL: "x",
      SUPABASE_SERVICE_ROLE_KEY: "k",
      NOTIFICATIONS_EMAIL_PROVIDER: "smtp",
    }).ok,
    false,
  );
});

test("scheduled run without secrets does nothing, makes no request and prints no values", async () => {
  const logs: string[] = [];
  let requests = 0;
  const outcome = await runScheduledNotifications(
    { SUPABASE_URL: "https://project.supabase.co", RESEND_API_KEY: "re_should_not_print" },
    {
      log: (line) => logs.push(line),
      fetch: async () => {
        requests += 1;
        return new Response("{}");
      },
    },
  );
  assert.deepEqual(outcome, {
    status: "skipped",
    reason: "notification bindings are not configured",
    missing: ["SUPABASE_SERVICE_ROLE_KEY"],
  });
  assert.equal(requests, 0);
  assert.deepEqual(logs, [
    "notifications: skipped (notification bindings are not configured: missing SUPABASE_SERVICE_ROLE_KEY)",
  ]);
  assert.doesNotMatch(logs.join("\n"), /re_should_not_print|supabase\.co/);
});

// ------------------------------------------------------------------------------------------
// Delivery cycle against an in-memory store
// ------------------------------------------------------------------------------------------
class MemoryStore implements NotificationStore {
  queue: ClaimedDelivery[][] = [];
  completions: Parameters<NotificationStore["completeDelivery"]>[0][] = [];
  failComplete = false;
  calls: string[] = [];
  async enqueueDueDigests() {
    this.calls.push("enqueue");
    return 1;
  }
  async dispatchEvents() {
    this.calls.push("dispatch");
    return 2;
  }
  async claimDeliveries(limit: number, lease: number) {
    this.calls.push(`claim:${limit}:${lease}`);
    return this.queue.shift() ?? [];
  }
  async completeDelivery(input: Parameters<NotificationStore["completeDelivery"]>[0]) {
    if (this.failComplete) throw new Error("database unavailable");
    this.completions.push(input);
    return input.outcome === "sent"
      ? "sent"
      : input.outcome === "retryable_failure"
        ? "pending"
        : "dead";
  }
}
const claimed = (id: string, overrides: Partial<ClaimedDelivery> = {}): ClaimedDelivery => ({
  deliveryId: id,
  claimToken: `token-${id}`,
  attempt: 1,
  channel: "email",
  eventType: "request_approved",
  recipientEmail: `${id}@example.test`,
  context: requestContext({ audience: "requester" }),
  ...overrides,
});

test("cycle: enqueue, dispatch, claim, render, send, record each outcome", async () => {
  const store = new MemoryStore();
  store.queue.push([claimed("a"), claimed("b"), claimed("c"), claimed("d")]);
  const provider = new FakeEmailProvider(["success", "retryable", "reject", "timeout"]);
  const result = await runNotificationCycle({
    store,
    provider,
    sender: NOTIFICATION_SENDER,
    appBaseUrl: APP,
    batchSize: 10,
  });
  assert.deepEqual(store.calls, ["enqueue", "dispatch", "claim:10:300"]);
  assert.deepEqual(result, {
    digestsEnqueued: 1,
    eventsDispatched: 2,
    claimed: 4,
    sent: 1,
    retrying: 2,
    dead: 1,
    staleClaims: 0,
    renderFailures: 0,
  });
  assert.deepEqual(
    store.completions.map((c) => [
      c.deliveryId,
      c.claimToken,
      c.outcome,
      c.provider,
      c.providerMessageId,
    ]),
    [
      ["a", "token-a", "sent", "fake", "fake-1"],
      ["b", "token-b", "retryable_failure", "fake", null],
      ["c", "token-c", "permanent_failure", "fake", null],
      ["d", "token-d", "retryable_failure", "fake", null],
    ],
  );
  assert.deepEqual(
    provider.attempts.map((attempt) => [
      attempt.message.to,
      attempt.message.idempotencyKey,
      attempt.message.from,
    ]),
    [
      ["a@example.test", "notification-delivery-a", NOTIFICATION_SENDER],
      ["b@example.test", "notification-delivery-b", NOTIFICATION_SENDER],
      ["c@example.test", "notification-delivery-c", NOTIFICATION_SENDER],
      ["d@example.test", "notification-delivery-d", NOTIFICATION_SENDER],
    ],
  );
});

test("cycle: keeps claiming full batches, stops on a short one, bounded by maxBatches", async () => {
  const store = new MemoryStore();
  store.queue.push([claimed("a"), claimed("b")], [claimed("c"), claimed("d")], [claimed("e")]);
  const result = await runNotificationCycle({
    store,
    provider: new FakeEmailProvider(),
    sender: NOTIFICATION_SENDER,
    appBaseUrl: APP,
    batchSize: 2,
  });
  assert.equal(result.sent, 5);
  const bounded = new MemoryStore();
  bounded.queue.push([claimed("a"), claimed("b")], [claimed("c"), claimed("d")]);
  const limited = await runNotificationCycle({
    store: bounded,
    provider: new FakeEmailProvider(),
    sender: NOTIFICATION_SENDER,
    appBaseUrl: APP,
    batchSize: 2,
    maxBatches: 1,
  });
  assert.equal(limited.claimed, 2);
});

test("cycle: an unrenderable delivery is dead-lettered, a recording failure leaves the lease", async () => {
  const store = new MemoryStore();
  store.queue.push([claimed("bad", { eventType: "mystery" as ClaimedDelivery["eventType"] })]);
  const provider = new FakeEmailProvider();
  const result = await runNotificationCycle({
    store,
    provider,
    sender: NOTIFICATION_SENDER,
    appBaseUrl: APP,
  });
  assert.equal(result.renderFailures, 1);
  assert.equal(store.completions[0].outcome, "permanent_failure");
  assert.match(String(store.completions[0].error), /render failed/);
  assert.equal(provider.attempts.length, 0);

  const failing = new MemoryStore();
  failing.failComplete = true;
  failing.queue.push([claimed("x")]);
  const logs: string[] = [];
  const outcome = await runNotificationCycle({
    store: failing,
    provider: new FakeEmailProvider(),
    sender: NOTIFICATION_SENDER,
    appBaseUrl: APP,
    log: (line) => logs.push(line),
  });
  assert.equal(outcome.sent, 0);
  assert.match(logs[0], /delivery x not recorded: database unavailable/);
});

// ------------------------------------------------------------------------------------------
// Settings
// ------------------------------------------------------------------------------------------
test("settings: defaults, parsing, labels and the explicit time zone list", () => {
  assert.deepEqual(DEFAULT_NOTIFICATION_SETTINGS, {
    sendingEnabled: false,
    digestEnabled: true,
    digestFrequency: "daily",
    digestSendHour: 8,
    digestWeekday: 1,
    timezone: "America/New_York",
    orderedReceiptThresholdDays: 7,
  });
  assert.deepEqual(parseNotificationSettings({ organizationId: "o" }), {
    organizationId: "o",
    ...DEFAULT_NOTIFICATION_SETTINGS,
    updatedAt: null,
  });
  assert.equal(formatSendHour(0), "12:00 AM");
  assert.equal(formatSendHour(8), "8:00 AM");
  assert.equal(formatSendHour(12), "12:00 PM");
  assert.equal(formatSendHour(23), "11:00 PM");
  assert.equal(
    digestScheduleSummary({
      digestEnabled: true,
      digestFrequency: "weekly",
      digestSendHour: 7,
      digestWeekday: 3,
      timezone: "America/Chicago",
    }),
    "Weekly on Wednesday at 7:00 AM Central Time (Chicago)",
  );
  assert.equal(
    digestScheduleSummary({
      digestEnabled: true,
      digestFrequency: "weekdays",
      digestSendHour: 8,
      digestWeekday: 1,
      timezone: "America/New_York",
    }),
    "Weekdays (Monday–Friday) at 8:00 AM Eastern Time (New York)",
  );
  assert.equal(
    digestScheduleSummary({ ...DEFAULT_NOTIFICATION_SETTINGS, digestEnabled: false }),
    "Off",
  );
  assert.equal(isSupportedTimezone("America/New_York"), true);
  assert.equal(isSupportedTimezone("Mars/Phobos"), false);
  for (const zone of SUPPORTED_TIMEZONES) {
    assert.doesNotThrow(
      () => new Intl.DateTimeFormat("en-US", { timeZone: zone.value }),
      zone.value,
    );
  }
});

test("Settings section: digest on/off, frequency, send time, time zone; sending switch read-only", () => {
  const settings = { organizationId: "o", ...DEFAULT_NOTIFICATION_SETTINGS, updatedAt: null };
  const html = render(ui.NotificationSettingsForm, { organizationId: "o", settings });
  const visible = text(html);
  assert.match(
    visible,
    /Email sending: Off — notifications are not emailed until sending is turned on/,
  );
  assert.match(visible, /Digest emails/);
  assert.match(
    html,
    /<option value="daily" selected="">Daily<\/option><option value="weekdays">Weekdays only<\/option><option value="weekly">Weekly<\/option>/,
  );
  assert.match(html, /<option value="8" selected="">8:00 AM<\/option>/);
  assert.match(
    html,
    /<option value="America\/New_York" selected="">Eastern Time \(New York\)<\/option>/,
  );
  assert.doesNotMatch(visible, /Monday/, "weekday picker only for Weekly");
  assert.match(
    visible,
    /Daily at 8:00 AM Eastern Time \(New York\)\. Sent only when requests need action\./,
  );
  assert.doesNotMatch(html, /sendingEnabled|name="sending/);
  assert.equal(
    (html.match(/type="checkbox"/g) ?? []).length,
    1,
    "only the digest toggle is editable",
  );

  const weekly = render(ui.NotificationSettingsForm, {
    organizationId: "o",
    settings: {
      ...settings,
      sendingEnabled: true,
      digestFrequency: "weekly",
      digestWeekday: 3,
      digestSendHour: 15,
    },
  });
  assert.match(text(weekly), /Email sending: On/);
  assert.match(weekly, /<option value="3" selected="">Wednesday<\/option>/);
  assert.match(text(weekly), /Weekly on Wednesday at 3:00 PM Eastern Time/);

  const off = render(ui.NotificationSettingsForm, {
    organizationId: "o",
    settings: { ...settings, digestEnabled: false },
  });
  assert.match(text(off), /Off/);
  assert.doesNotMatch(text(off), /Sent only when/);

  const loading = render(ui.NotificationSettings, { organizationId: "o" });
  assert.match(
    text(loading),
    /Notifications .*Admins get an email when a new supply request is submitted/,
  );
});

// ------------------------------------------------------------------------------------------
// Structure and wiring
// ------------------------------------------------------------------------------------------
test("Settings page: admins only (existing gate), section added after count cadence", () => {
  const page = read("src/routes/_authenticated/settings.tsx");
  assert.match(
    page,
    /if \(!active \|\| \(active\.role !== "owner" && active\.role !== "admin"\)\) return null;/,
  );
  assert.match(
    page,
    /<CountPolicySettings[\s\S]*\/>\s*<NotificationSettings organizationId=\{active\.organizationId\} \/>/,
  );
  assert.match(read("src/routes/_authenticated/route.tsx"), /"\/settings"/);
});

test("server functions: authenticated, validated, master switch not settable", () => {
  const source = read("src/lib/notification-settings.functions.ts");
  assert.equal((source.match(/\.middleware\(\[requireSupabaseAuth\]\)/g) ?? []).length, 2);
  assert.match(source, /timezone: z\.enum\(SUPPORTED_TIMEZONE_VALUES\)/);
  assert.match(source, /digestSendHour: z\.number\(\)\.int\(\)\.min\(0\)\.max\(23\)/);
  assert.doesNotMatch(source.replace(/\/\/.*$/gm, ""), /sending|service_role|client\.server/i);
});

test("migration: provider-neutral events, is_org_admin recipients, no role literals, service-role worker functions", () => {
  assert.doesNotMatch(migrationCode, /resend/i, "no provider names in the schema");
  assert.doesNotMatch(
    migrationCode,
    /ARRAY\['owner'|role = 'admin'|role IN \(/,
    "no literal role filters",
  );
  assert.match(
    functionBody("dispatch_notification_events"),
    /public\.is_org_admin\(_event\.organization_id, m\.user_id\)/,
  );
  assert.match(
    functionBody("claim_notification_deliveries"),
    /public\.is_org_admin\(_delivery\.organization_id, _delivery\.recipient_user_id\)/,
  );
  assert.match(functionBody("claim_notification_deliveries"), /FROM auth\.users u/);
  assert.match(functionBody("claim_notification_deliveries"), /FOR UPDATE SKIP LOCKED/);
  assert.match(functionBody("dispatch_notification_events"), /FOR UPDATE SKIP LOCKED/);
  for (const name of [
    "enqueue_due_notification_digests(timestamptz)",
    "dispatch_notification_events(integer, timestamptz)",
    "claim_notification_deliveries(integer, integer, timestamptz)",
    "set_organization_notification_sending(uuid, boolean)",
  ]) {
    assert.match(
      migration,
      new RegExp(
        `REVOKE ALL ON FUNCTION public\\.${name.replace(/[()]/g, "\\$&")} FROM PUBLIC, anon, authenticated;`,
      ),
    );
    assert.match(
      migration,
      new RegExp(
        `GRANT EXECUTE ON FUNCTION public\\.${name.replace(/[()]/g, "\\$&")} TO service_role;`,
      ),
    );
  }
  // Event capture triggers: one insert, no lookups.
  for (const name of [
    "capture_supply_request_submitted_notification",
    "capture_supply_request_decision_notification",
  ]) {
    const body = functionBody(name);
    assert.equal((body.match(/INSERT INTO/g) ?? []).length, 1);
    assert.doesNotMatch(body, /SELECT|auth\.|http|net\./i);
  }
  assert.match(migration, /FOR EACH ROW WHEN \(NEW\.status = 'submitted'\)/);
  assert.match(migration, /FOR EACH ROW WHEN \(NEW\.status_to IN \('approved', 'denied'\)\)/);
  assert.doesNotMatch(
    migrationCode,
    /CREATE (OR REPLACE )?FUNCTION public\.(decide_supply_request|transition_supply_request|apply_supply_request_transition|submit_supply_request|is_org_admin)\b/,
  );
  assert.doesNotMatch(migrationCode, /create\s+temp/i);
  assert.equal(migration.trimEnd().endsWith("COMMIT;"), true);
});

test("Worker: one repo-managed cron, scheduled hook wired through a Nitro plugin, lazy import", () => {
  const wrangler = read("wrangler.jsonc");
  assert.match(wrangler, /"triggers": \{\s*"crons": \["\*\/5 \* \* \* \*"\]\s*\}/);
  assert.equal(
    (wrangler.match(/\* \* \* \*/g) ?? []).length,
    1,
    "one cron expression for every organization",
  );
  assert.match(
    read("vite.config.ts"),
    /nitro: \{ plugins: \["\.\/src\/server\/notification-scheduler\.ts"\] \}/,
  );
  const plugin = read("src/server/notification-scheduler.ts");
  assert.match(plugin, /hooks\.hook\("cloudflare:scheduled"/);
  assert.match(plugin, /await import\("\.\.\/notifications\/scheduled\.server\.ts"\)/);
  assert.doesNotMatch(plugin, /^import .*notifications/m);
});

test("client code never imports server-only notification modules", () => {
  for (const path of [
    "src/components/settings/NotificationSettings.tsx",
    "src/lib/notification-settings.functions.ts",
    "src/notifications/settings.ts",
  ]) {
    assert.doesNotMatch(
      read(path),
      /scheduled\.server|supabase-store|providers\/resend|client\.server|worker"/,
      path,
    );
  }
});

test("migration: the master switch is a durable delivery boundary (no replay of OFF-period events)", () => {
  assert.match(migration, /sending_enabled_at timestamptz,/);
  assert.match(migration, /CHECK \(NOT sending_enabled OR sending_enabled_at IS NOT NULL\)/);
  assert.match(migration, /created_at timestamptz NOT NULL DEFAULT clock_timestamp\(\),/);
  const guard = functionBody("guard_notification_sending_boundary");
  assert.match(
    guard,
    /LOCK TABLE public\.notification_events IN SHARE ROW EXCLUSIVE MODE;\s+NEW\.sending_enabled_at := clock_timestamp\(\);/,
  );
  assert.match(guard, /NEW\.sending_enabled_at := OLD\.sending_enabled_at;/);
  assert.match(
    migration,
    /BEFORE INSERT OR UPDATE ON public\.organization_notification_settings\s+FOR EACH ROW EXECUTE FUNCTION public\.guard_notification_sending_boundary\(\);/,
  );
  assert.match(
    functionBody("dispatch_notification_events"),
    /IF _boundary IS NULL OR _event\.created_at < _boundary THEN[\s\S]*?'created_before_sending_enabled'/,
  );
  assert.match(
    functionBody("claim_notification_deliveries"),
    /ELSIF _settings\.sending_enabled_at IS NULL OR _event\.created_at < _settings\.sending_enabled_at THEN\s+_reason := 'created_before_sending_enabled';/,
  );
  assert.match(
    functionBody("enqueue_due_notification_digests"),
    /CONTINUE WHEN _settings\.sending_enabled_at IS NULL OR _slot < _settings\.sending_enabled_at;/,
  );
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.guard_notification_sending_boundary\(\) FROM PUBLIC, anon, authenticated, service_role;/,
  );
});

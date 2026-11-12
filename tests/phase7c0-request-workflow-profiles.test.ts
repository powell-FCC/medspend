// Phase 7C.0: configurable request workflow profiles. Pure workflow rules (queues, actions, staff
// presentation, history collapse), the migration's shape, the server functions, and the rendered
// Admin Settings section and queue tabs. Database behavior is proven by
// supabase/tests/phase7c0_request_workflow_profiles_behavior.sql, phase7c0_race_check.sh,
// phase7c0_mutation_check.sh and tests/phase7c0-request-workflow-integration.test.ts.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import test, { after } from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  SUPPLY_REQUEST_STATUSES,
  type SupplyRequestStatus,
} from "../src/supply-requests/lifecycle.ts";
import {
  buildStaffRequestTimeline,
  translateStaffRequestStatus,
} from "../src/supply-requests/staff-dashboard.ts";
import {
  ADMIN_QUEUE_ORDER,
  DEFAULT_REQUEST_WORKFLOW_PROFILE,
  REQUEST_WORKFLOW_PROFILES,
  REQUEST_WORKFLOW_PROFILE_OPTIONS,
  adminActionFeedback,
  adminQueueCardAction,
  adminPrimaryAction,
  collapseCompoundUpdates,
  parseCompoundAction,
  parseRequestWorkflowProfile,
  parseRequestWorkflowSettings,
  visibleAdminQueues,
  type RequestWorkflowProfile,
} from "../src/supply-requests/workflow-profiles.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const migration = read("supabase/migrations/20261112120000_phase7c0_request_workflow_profiles.sql");
const migrationCode = migration.replace(/--.*$/gm, "");
const between = (text: string, start: string, end: string) => {
  const from = text.indexOf(start);
  assert.ok(from >= 0, start);
  const to = text.indexOf(end, from + start.length);
  assert.ok(to >= 0, end);
  return text.slice(from, to);
};

// Bundle the UI for rendering BEFORE any test is registered (as in the 6C.3 test).
const cacheDir = join(root, `node_modules/.cache/phase7c0-workflow-test-${process.pid}`);
mkdirSync(cacheDir, { recursive: true });
const pending = "() => new Promise(() => {})";
const stubs: Record<string, string> = {
  "@tanstack/react-start": `export const useServerFn = (fn) => fn;`,
  "@/lib/request-workflow-settings.functions": `export const getRequestWorkflowSettingsFn = ${pending}, updateRequestWorkflowSettingsFn = ${pending};`,
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
  export { RequestWorkflowSettingsForm } from "@/components/settings/RequestWorkflowSettings";
  export { AdminQueueTabs } from "@/components/admin/supply-requests/AdminQueueTabs";
  export { AdminRequestCard } from "@/components/admin/supply-requests/AdminRequestCard";
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
      name: "workflow-stubs",
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
after(() => rmSync(cacheDir, { recursive: true, force: true }));
const render = (component: unknown, props: Record<string, unknown>) =>
  ui.render(component, props) as string;
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&#x27;/g, "'")
    .replace(/\s+/g, " ");

const emptySummary = {
  needsReview: 0,
  awaitingOrder: 0,
  awaitingDelivery: 0,
  readyForStaff: 0,
  completed: 0,
};
const OPEN: SupplyRequestStatus[] = [
  "submitted",
  "under_review",
  "approved",
  "ordered",
  "received",
];

// ---------------------------------------------------------------------------------------------
// Profiles and settings

test("three fixed profiles; anything else (and no row) is Detailed", () => {
  assert.deepEqual([...REQUEST_WORKFLOW_PROFILES], ["lean", "standard", "detailed"]);
  assert.equal(DEFAULT_REQUEST_WORKFLOW_PROFILE, "detailed");
  for (const value of [null, undefined, "", "LEAN", "custom", 3]) {
    assert.equal(parseRequestWorkflowProfile(value), "detailed");
  }
  assert.equal(parseRequestWorkflowProfile("lean"), "lean");
  assert.deepEqual(
    parseRequestWorkflowSettings({
      organizationId: "o",
      workflowProfile: "standard",
      updatedAt: null,
    }),
    { organizationId: "o", workflowProfile: "standard", updatedAt: null },
  );
  assert.throws(() => parseRequestWorkflowSettings(null));
});

test("profile copy: operational descriptions only, no status configuration", () => {
  const byValue = Object.fromEntries(
    REQUEST_WORKFLOW_PROFILE_OPTIONS.map((option) => [option.value, option]),
  );
  assert.equal(
    byValue.lean.description,
    "Fewer steps for integrated teams. Approval also marks the request ordered; receiving also completes it.",
  );
  assert.equal(
    byValue.standard.description,
    "Separate approval and ordering, with receiving and completion combined.",
  );
  assert.equal(
    byValue.detailed.description,
    "Full request workflow with separate approval, ordering, receiving, staff-ready and completion stages.",
  );
  assert.equal(byValue.lean.stages, "Needs Review → Awaiting Delivery → Completed");
  assert.equal(
    byValue.standard.stages,
    "Needs Review → Awaiting Order → Awaiting Delivery → Completed",
  );
  assert.equal(
    byValue.detailed.stages,
    "Needs Review → Awaiting Order → Awaiting Delivery → Ready for Staff → Completed",
  );
});

// ---------------------------------------------------------------------------------------------
// Queues

test("normal tabs per profile; Detailed keeps today's five", () => {
  assert.deepEqual(visibleAdminQueues("lean", emptySummary), [
    "needsReview",
    "awaitingDelivery",
    "completed",
  ]);
  assert.deepEqual(visibleAdminQueues("standard", emptySummary), [
    "needsReview",
    "awaitingOrder",
    "awaitingDelivery",
    "completed",
  ]);
  assert.deepEqual(visibleAdminQueues("detailed", emptySummary), [...ADMIN_QUEUE_ORDER]);
});

test("a hidden optional queue resurfaces while it holds requests, and the open queue stays reachable", () => {
  assert.deepEqual(visibleAdminQueues("lean", { ...emptySummary, awaitingOrder: 1 }), [
    "needsReview",
    "awaitingOrder",
    "awaitingDelivery",
    "completed",
  ]);
  assert.deepEqual(visibleAdminQueues("lean", { ...emptySummary, readyForStaff: 2 }), [
    "needsReview",
    "awaitingDelivery",
    "readyForStaff",
    "completed",
  ]);
  assert.deepEqual(visibleAdminQueues("standard", { ...emptySummary, readyForStaff: 1 }), [
    ...ADMIN_QUEUE_ORDER,
  ]);
  // A digest link to /supply-requests?queue=awaitingOrder after the queue emptied.
  assert.ok(visibleAdminQueues("lean", emptySummary, "awaitingOrder").includes("awaitingOrder"));
  // Required queues never hide.
  for (const profile of REQUEST_WORKFLOW_PROFILES) {
    for (const queue of ["needsReview", "awaitingDelivery", "completed"] as const) {
      assert.ok(visibleAdminQueues(profile, emptySummary).includes(queue), `${profile} ${queue}`);
    }
  }
});

// ---------------------------------------------------------------------------------------------
// Actions

test("primary actions by profile match the locked design", () => {
  const actions = (profile: RequestWorkflowProfile) =>
    Object.fromEntries(OPEN.map((status) => [status, adminPrimaryAction(profile, status)?.label]));
  assert.deepEqual(actions("lean"), {
    submitted: "Approve & Order",
    under_review: "Approve & Order",
    approved: "Mark Ordered",
    ordered: "Receive & Complete",
    received: "Complete Request",
  });
  assert.deepEqual(actions("standard"), {
    submitted: "Approve",
    under_review: "Approve",
    approved: "Mark Ordered",
    ordered: "Receive & Complete",
    received: "Complete Request",
  });
  assert.deepEqual(actions("detailed"), {
    submitted: "Approve",
    under_review: "Approve",
    approved: "Mark Ordered",
    ordered: "Mark Received",
    received: "Complete Request",
  });
});

test("no profile strands a request: every open status has an action whose result is a valid next state", () => {
  for (const profile of REQUEST_WORKFLOW_PROFILES) {
    for (const status of OPEN) {
      const action = adminPrimaryAction(profile, status);
      assert.ok(action, `${profile} ${status}`);
      const order = SUPPLY_REQUEST_STATUSES.indexOf(action.resultStatus);
      assert.ok(
        order > SUPPLY_REQUEST_STATUSES.indexOf(status),
        `${profile} ${status} moves forward`,
      );
    }
    for (const status of ["completed", "denied", "cancelled"] as const) {
      assert.equal(adminPrimaryAction(profile, status), null);
    }
  }
  assert.equal(adminPrimaryAction("lean", "submitted")?.kind, "approve_and_order");
  assert.equal(adminPrimaryAction("lean", "ordered")?.kind, "receive_and_complete");
  assert.equal(adminPrimaryAction("detailed", "ordered")?.kind, "mark_received");
  assert.match(adminActionFeedback("approve_and_order"), /approved and marked ordered/);
  assert.match(adminActionFeedback("decline"), /visible to staff/);
});

test("the drawer and route dispatch actions without adding confirmation dialogs", () => {
  const detail = read("src/components/admin/supply-requests/AdminRequestDetail.tsx");
  const route = read("src/routes/_authenticated/supply-requests.tsx");
  assert.match(detail, /adminPrimaryAction\(workflowProfile, request\.lifecycleStatus\)/);
  assert.match(
    detail,
    // Phase 7C: receiving actions also pass the chosen destination.
    /onTransition\(\s*declining \? "decline" : action\.kind,\s*staffMessage,\s*internalNote,\s*needsDestination \? destinationId : undefined,?\s*\)/,
  );
  assert.doesNotMatch(detail, /AlertDialog|window\.confirm|confirm\(/);
  const transition = between(route, "async function transition(", "async function release(");
  assert.match(
    transition,
    /action === "approve_and_order"\) \{\s+await approveAndOrder\(\{ data: \{ \.\.\.data, expectedUpdatedAt: selected\.updatedAt \} \}\)/,
  );
  // Phase 7C: both receiving actions send the destination through the same branch.
  assert.match(
    transition,
    /action === "mark_received" \|\| action === "receive_and_complete"\) \{[\s\S]*?await \(action === "mark_received" \? receive : receiveAndComplete\)\(\{ data: \{ \.\.\.data, inventoryLocationId \} \}\)/,
  );
  assert.match(route, /visibleAdminQueues\(workflowProfile, dashboard\.data\.summary, queue\)/);
  assert.match(route, /workflowProfile=\{workflowProfile\}/);
  const dashboard = read("src/routes/_authenticated/dashboard.tsx");
  assert.match(
    dashboard,
    /shown\.includes\("awaitingOrder"\) && <OperationMetric label="Awaiting Order"/,
  );
  assert.match(
    dashboard,
    /shown\.includes\("readyForStaff"\) && <OperationMetric label="Ready for Staff"/,
  );
});

// ---------------------------------------------------------------------------------------------
// Staff presentation and history

test("staff labels: Lean reads ordered as Approved & ordered; groups never change", () => {
  assert.equal(translateStaffRequestStatus("ordered", "lean").label, "Approved & ordered");
  assert.equal(translateStaffRequestStatus("ordered", "standard").label, "Ordered");
  assert.equal(translateStaffRequestStatus("ordered").label, "Ordered");
  for (const profile of REQUEST_WORKFLOW_PROFILES) {
    for (const status of SUPPLY_REQUEST_STATUSES) {
      assert.equal(
        translateStaffRequestStatus(status, profile).group,
        translateStaffRequestStatus(status).group,
      );
    }
  }
  // A genuinely received request is still "Ready" (the Ready section shows only when non-empty).
  assert.equal(translateStaffRequestStatus("received", "lean").group, "READY");
  const staffHome = read("src/routes/_authenticated/staff/index.tsx");
  assert.match(staffHome, /readyRequests\.length > 0 &&/);
});

const at = "2026-11-12T15:00:00.000Z";
const later = "2026-11-13T09:30:00.000Z";
const leanRows = [
  {
    status_to: "under_review" as const,
    staff_visible_note: null,
    event_kind: null,
    created_at: at,
    compound_action: "approve_and_order" as const,
  },
  {
    status_to: "approved" as const,
    staff_visible_note: null,
    event_kind: null,
    created_at: at,
    compound_action: "approve_and_order" as const,
  },
  {
    status_to: "ordered" as const,
    staff_visible_note: "Arriving Tuesday",
    event_kind: null,
    created_at: at,
    compound_action: "approve_and_order" as const,
  },
  {
    status_to: "received" as const,
    staff_visible_note: null,
    event_kind: null,
    created_at: later,
    compound_action: "receive_and_complete" as const,
  },
  {
    status_to: "completed" as const,
    staff_visible_note: "In the cage",
    event_kind: null,
    created_at: later,
    compound_action: "receive_and_complete" as const,
  },
];

test("a compound action is one timeline step with its final status and note", () => {
  assert.deepEqual(buildStaffRequestTimeline("2026-11-12T14:00:00.000Z", leanRows, "lean"), [
    { label: "Submitted", occurredAt: "2026-11-12T14:00:00.000Z", message: null },
    { label: "Approved & ordered", occurredAt: at, message: "Arriving Tuesday" },
    { label: "Completed", occurredAt: later, message: "In the cage" },
  ]);
  const steps = collapseCompoundUpdates(leanRows);
  assert.equal(steps.length, 2);
  assert.deepEqual(
    steps[0].canonicalRows.map((row) => row.status_to),
    ["under_review", "approved", "ordered"],
  );
  assert.deepEqual(
    steps[1].canonicalRows.map((row) => row.status_to),
    ["received", "completed"],
  );
});

test("ordinary transitions are never collapsed, even at the same instant", () => {
  const detailed = [
    {
      status_to: "under_review" as const,
      staff_visible_note: null,
      event_kind: null,
      created_at: at,
      compound_action: null,
    },
    {
      status_to: "approved" as const,
      staff_visible_note: "Approved",
      event_kind: null,
      created_at: at,
      compound_action: null,
    },
    {
      status_to: "ordered" as const,
      staff_visible_note: null,
      event_kind: null,
      created_at: later,
      compound_action: null,
    },
  ];
  assert.deepEqual(
    buildStaffRequestTimeline(at, detailed).map((item) => item.label),
    ["Submitted", "Under review", "Approved", "Ordered"],
  );
  // Two bundles of the same kind at different instants stay two steps.
  const twice = collapseCompoundUpdates([
    {
      status_to: "received" as const,
      compound_action: "receive_and_complete" as const,
      created_at: at,
    },
    {
      status_to: "completed" as const,
      compound_action: "receive_and_complete" as const,
      created_at: later,
    },
  ]);
  assert.equal(twice.length, 2);
  // Older rows without the field behave as before.
  assert.deepEqual(
    buildStaffRequestTimeline(at, [
      { status_to: "ordered", staff_visible_note: null, event_kind: null, created_at: at },
    ]).map((item) => item.label),
    ["Submitted", "Ordered"],
  );
  assert.equal(parseCompoundAction("approve_and_order"), "approve_and_order");
  assert.equal(parseCompoundAction("something"), null);
});

test("admin history collapses bundles but still names the canonical steps", () => {
  const detail = read("src/components/admin/supply-requests/AdminRequestDetail.tsx");
  assert.match(detail, /collapseCompoundUpdates\(updates\.map/);
  assert.match(detail, /COMPOUND_ACTION_LABELS\[update\.compound_action\]/);
  assert.match(detail, /Recorded as \{update\.canonicalRows\.map/);
  assert.match(detail, /Internal Note · Admins only/);
});

// ---------------------------------------------------------------------------------------------
// Server functions

test("server functions forward to the profile-enforcing RPCs; staff read the profile only", () => {
  const server = read("src/lib/supply-requests.functions.ts");
  const approve = between(
    server,
    "export const approveAndOrderSupplyRequestFn",
    "export const receiveSupplyRequestFn",
  );
  assert.match(approve, /requireAdmin\(context, data\.organizationId\)/);
  assert.match(approve, /rpc\("approve_and_order_supply_request"/);
  assert.match(approve, /_expected_updated_at: data\.expectedUpdatedAt/);
  const receive = between(
    server,
    "export const receiveSupplyRequestFn",
    "export const receiveAndCompleteSupplyRequestFn",
  );
  assert.match(receive, /rpc\("receive_supply_request"/);
  const complete = between(
    server,
    "export const receiveAndCompleteSupplyRequestFn",
    "export const getSupplyRequestBudgetImpactFn",
  );
  assert.match(complete, /rpc\("receive_and_complete_supply_request"/);
  for (const fn of [
    "getStaffDashboardFn",
    "getStaffRequestDetailFn",
    "getAdminSupplyRequestDashboardFn",
  ]) {
    const body = between(server, `export const ${fn}`, "\n  });\n");
    assert.match(body, /loadRequestWorkflowProfile\(context, data\.organizationId\)/, fn);
  }
  assert.match(server, /rpc\("get_request_workflow_profile"/);
  assert.match(
    server,
    /select\("id,status_from,status_to,internal_note,staff_visible_note,event_kind,created_at,compound_action"\)/,
  );
  const settings = read("src/lib/request-workflow-settings.functions.ts");
  assert.match(settings, /rpc\(\s*"get_organization_request_workflow_settings"/);
  assert.match(settings, /rpc\(\s*"update_organization_request_workflow_settings"/);
  assert.match(settings, /workflowProfile: z\.enum\(REQUEST_WORKFLOW_PROFILES\)/);
});

// ---------------------------------------------------------------------------------------------
// Migration shape

test("the migration is additive and leaves the lifecycle, notifications and digest untouched", () => {
  for (const name of [
    "apply_supply_request_transition",
    "transition_supply_request",
    "decide_supply_request",
    "capture_supply_request_decision_notification",
    "notification_approver_digest_content",
    "create_supply_request_commitment",
  ]) {
    assert.doesNotMatch(
      migrationCode,
      new RegExp(`(CREATE|DROP|ALTER) (OR REPLACE )?FUNCTION public\\.${name}\\(`),
      name,
    );
  }
  assert.deepEqual(
    [...migrationCode.matchAll(/DROP (FUNCTION|TABLE|TRIGGER|POLICY|INDEX) ([^;(]+)/g)].map((m) =>
      m[2].trim(),
    ),
    ["public.list_staff_supply_request_updates"],
  );
  assert.doesNotMatch(
    migrationCode,
    /ALTER TABLE public\.organizations|UPDATE public\.supply_requests|DELETE FROM|inventory_/,
  );
  assert.match(migrationCode, /CREATE TABLE public\.organization_request_workflow_settings/);
  assert.match(migrationCode, /CHECK \(workflow_profile IN \('lean', 'standard', 'detailed'\)\)/);
  assert.match(
    migrationCode,
    /REVOKE ALL ON public\.organization_request_workflow_settings FROM PUBLIC, anon, authenticated, service_role;/,
  );
  assert.match(migrationCode, /ADD COLUMN compound_action text/);
  assert.match(
    migration,
    /approval -> order \(for\s+-- approve_and_order\) and receipt -> completion \(for receive_and_complete\) durations are\s+-- intentionally 0/,
  );
  // Refusals never use 40001 (PostgREST retries serialization failures).
  assert.doesNotMatch(migrationCode, /'40001'/);
  // The compound actions reuse the existing machinery.
  const approve = between(
    migration,
    "CREATE FUNCTION public.approve_and_order_supply_request(",
    "\n$$;",
  );
  assert.match(
    approve,
    /PERFORM public\.decide_supply_request\(\s+_organization_id, _request_id, 'approved', NULL, NULL, _request\.updated_at/,
  );
  assert.match(
    approve,
    /public\.apply_supply_request_transition\(\s+_organization_id, _request_id, 'ordered', _internal_note, _staff_visible_note/,
  );
  const complete = between(
    migration,
    "CREATE FUNCTION public.receive_and_complete_supply_request(",
    "\n$$;",
  );
  assert.match(
    complete,
    /PERFORM public\.apply_supply_request_receipt\(_organization_id, _request_id, NULL, NULL\)/,
  );
  const receive = between(migration, "CREATE FUNCTION public.receive_supply_request(", "\n$$;");
  assert.match(
    receive,
    /public\.apply_supply_request_receipt\(_organization_id, _request_id, _internal_note, _staff_visible_note\)/,
  );
});

// ---------------------------------------------------------------------------------------------
// Rendered UI

test("Admin Settings renders the Request Workflow section with the three profiles", () => {
  const html = render(ui.RequestWorkflowSettingsForm, {
    organizationId: "00000000-0000-4000-8000-000000000001",
    settings: {
      organizationId: "00000000-0000-4000-8000-000000000001",
      workflowProfile: "lean",
      updatedAt: null,
    },
  });
  const content = text(html);
  for (const option of REQUEST_WORKFLOW_PROFILE_OPTIONS) {
    assert.ok(content.includes(option.label), option.label);
    assert.ok(content.includes(option.description), option.description);
  }
  assert.match(html, /checked="" value="lean"/);
  assert.equal((html.match(/checked=""/g) ?? []).length, 1);
  assert.match(content, /Requests already in progress keep their status/);
  assert.match(html, /<button[^>]*type="submit"[^>]*disabled=""/);
  const page = read("src/routes/_authenticated/settings.tsx");
  assert.match(page, /<RequestWorkflowSettings organizationId=\{active\.organizationId\} \/>/);
  // Settings is an admin route; staff never reach it.
  assert.match(
    read("src/routes/_authenticated/route.tsx"),
    /const ADMIN_ROUTES = \[[^\]]*"\/settings"/,
  );
});

test("queue tabs render only the profile's tabs", () => {
  const html = render(ui.AdminQueueTabs, {
    active: "needsReview",
    summary: emptySummary,
    queues: visibleAdminQueues("lean", emptySummary),
    onChange: () => {},
  });
  const content = text(html);
  assert.match(content, /Needs Review/);
  assert.match(content, /Awaiting Delivery/);
  assert.doesNotMatch(content, /Awaiting Order|Ready for Staff/);
  const all = text(
    render(ui.AdminQueueTabs, { active: "needsReview", summary: emptySummary, onChange: () => {} }),
  );
  assert.match(all, /Awaiting Order.*Ready for Staff/);
});

// ---------------------------------------------------------------------------------------------
// Queue cards (review fix): the card names the same action as the drawer

const cardRequest = (status: SupplyRequestStatus, profile: RequestWorkflowProfile) => ({
  id: "00000000-0000-4000-8000-000000000101",
  itemCount: 1,
  items: [
    {
      id: "i1",
      productId: null,
      inventoryItemId: null,
      vendorProductId: null,
      catalogVendorProductId: null,
      name: "Athletic tape",
      quantity: 2,
      unit: null,
    },
  ],
  itemName: "Athletic tape",
  quantity: 2,
  unit: null,
  requesterName: "Staff member",
  requesterEmail: null,
  team: null,
  location: null,
  requestTypeLabel: "Supply Request",
  queueGroup: "AWAITING_DELIVERY",
  statusLabel: "Ordered",
  nextAction: adminQueueCardAction(profile, status),
  lifecycleStatus: status,
  submittedAt: "2026-11-12T14:00:00.000Z",
  updatedAt: "2026-11-12T14:00:00.000Z",
  ageInDays: 0,
  staffNote: null,
  latestStaffMessage: null,
  latestInternalNote: null,
  latestUpdateAt: "2026-11-12T14:00:00.000Z",
  hasExistingProduct: false,
  isNewItem: true,
});
const cardButton = (status: SupplyRequestStatus, profile: RequestWorkflowProfile) => {
  const html = render(ui.AdminRequestCard, {
    request: cardRequest(status, profile),
    onOpen: () => {},
  });
  return [...html.matchAll(/<button[^>]*>([^<]*)<\/button>/g)].map((m) => m[1]).at(-1);
};

test("ordered queue card names Receive & Complete in Lean and Standard, Mark Received in Detailed", () => {
  assert.equal(cardButton("ordered", "lean"), "Receive &amp; Complete");
  assert.equal(cardButton("ordered", "standard"), "Receive &amp; Complete");
  assert.equal(cardButton("ordered", "detailed"), "Mark Received");
});

test("card and drawer agree for every open status in every profile; older requests keep a plain action", () => {
  for (const profile of REQUEST_WORKFLOW_PROFILES) {
    for (const status of ["approved", "ordered", "received"] as const) {
      assert.equal(
        adminQueueCardAction(profile, status),
        adminPrimaryAction(profile, status)?.label,
        `${profile} ${status}`,
      );
    }
    assert.equal(adminQueueCardAction(profile, "submitted"), "View Request");
    assert.equal(adminQueueCardAction(profile, "completed"), null);
  }
  // Resurfaced queues in Lean: an approved request still says Mark Ordered, a received one Complete Request.
  assert.equal(cardButton("approved", "lean"), "Mark Ordered");
  assert.equal(cardButton("received", "lean"), "Complete Request");
  assert.equal(cardButton("received", "standard"), "Complete Request");
  // The dashboard builds the card label from the profile, not the static translation.
  const server = read("src/lib/supply-requests.functions.ts");
  assert.match(server, /nextAction: adminQueueCardAction\(workflowProfile, lifecycleStatus\)/);
  assert.doesNotMatch(server, /nextAction: translation\.nextAction/);
});

// ---------------------------------------------------------------------------------------------
// Stale-screen SQLSTATE (review fix)

test("decide_supply_request stale screens return non-retryable 55000; nothing else in its body changes", () => {
  const fix = read("supabase/migrations/20261112110000_decide_stale_screen_sqlstate.sql");
  const original = read("supabase/migrations/20261009120000_phase6c_staff_request_forgiveness.sql");
  const body = (text: string, header: string) =>
    text
      .slice(text.indexOf(header), text.indexOf("\n$$;", text.indexOf(header)))
      .replace(/--.*$/gm, "")
      .replace(/\s+/g, " ");
  const before = body(original, "CREATE FUNCTION public.decide_supply_request(");
  const after = body(fix, "CREATE OR REPLACE FUNCTION public.decide_supply_request(");
  assert.equal(
    after.replace("CREATE OR REPLACE FUNCTION", "CREATE FUNCTION").replace("'55000'", "'40001'"),
    before,
  );
  assert.doesNotMatch(after, /'40001'/);
  assert.equal(fix.match(/^BEGIN;$/gm)?.length, 1);
  assert.equal(fix.match(/^COMMIT;$/gm)?.length, 1);
  assert.match(
    fix,
    /GRANT EXECUTE ON FUNCTION public\.decide_supply_request\(\s+uuid, uuid, public\.supply_request_status, text, text, timestamptz\s+\) TO authenticated;/,
  );
  // Sorts before 7C.0, so it can ship on its own or together with 7C.0.
  assert.ok(
    "20261112110000_decide_stale_screen_sqlstate.sql" <
      "20261112120000_phase7c0_request_workflow_profiles.sql",
  );
});

// Phase 6C.2: staff request cancellation. Pure lifecycle/status/recommendation logic,
// structural checks of the migrations and server function, and rendered staff states.
// Database behavior is covered by supabase/tests/phase6c2_staff_request_cancellation_behavior.sql.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  SUPPLY_REQUEST_STATUSES,
  canRequesterCancelSupplyRequest,
  canRequesterEditSupplyRequest,
  canTransitionSupplyRequest,
  requesterEditGuidance,
} from "../src/supply-requests/lifecycle.ts";
import {
  STAFF_OPEN_STATUSES,
  STAFF_PAST_STATUSES,
  buildStaffRequestTimeline,
  isStaffOpenRequest,
  isStaffPastRequest,
  summarizeStaffRequests,
  translateStaffRequestStatus,
} from "../src/supply-requests/staff-dashboard.ts";
import {
  buildAdminRequestDashboard,
  translateAdminRequestStatus,
} from "../src/supply-requests/admin-dashboard.ts";
import {
  QUICK_PICK_EXCLUDED_STATUSES,
  buildRequestAgainLines,
  type AvailabilityLookups,
} from "../src/supply-requests/staff-workspace.ts";
import {
  CANCEL_REQUEST_CONFIRMATION,
  EMPTY_EDIT_STATE,
  createCustomCartItem,
  editCompletion,
  removeCartItem,
} from "../src/supply-requests/staff-request-cart.ts";
import { cancelSubmittedSupplyRequestInputSchema } from "../src/supply-requests/validation.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const between = (source: string, start: string, end: string) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end}`);
  return source.slice(from, to);
};
const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

const statusMigration = read(
  "supabase/migrations/20261020120000_phase6c2_cancelled_request_status.sql",
);
const migration = read(
  "supabase/migrations/20261020120100_phase6c2_staff_request_cancellation.sql",
);
const migrationCode = migration.replace(/--.*$/gm, "");
const phase6cMigration = read(
  "supabase/migrations/20261009120000_phase6c_staff_request_forgiveness.sql",
);
const behavior = read("supabase/tests/phase6c2_staff_request_cancellation_behavior.sql");
const server = read("src/lib/supply-requests.functions.ts");
const workspaceServer = read("src/lib/staff-workspace.functions.ts");
const composer = read("src/routes/_authenticated/staff/request.tsx");
const staffDetail = read("src/routes/_authenticated/staff/requests.$id.tsx");
const cancelAction = read("src/components/staff/CancelRequestAction.tsx");
const commandCenter = read(
  "supabase/migrations/20261015120000_budget_purchasing_command_center.sql",
);
const types = read("src/integrations/supabase/types.ts");

const cancelFunction = between(
  migration,
  "CREATE FUNCTION public.cancel_submitted_supply_request",
  "REVOKE ALL ON FUNCTION public.cancel_submitted_supply_request",
);

// Bundle the staff UI before any test is registered, so cleanup cannot race the build.
const cacheDir = join(root, "node_modules/.cache/phase6c2-cancellation-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));

const stubs: Record<string, string> = {
  "@tanstack/react-router": `
    import { createElement } from "react";
    const t = () => globalThis.__staff;
    export const createFileRoute = () => (options) => ({ options, useParams: () => t().params });
    export const Link = ({ to, params, search, children, activeProps, ...rest }) =>
      createElement("a", { ...rest, href: String(to).replace("$id", params?.id ?? "") }, children);
    export const Outlet = () => createElement("div", { "data-outlet": true });
    export const useSearch = () => t().search;
    export const useNavigate = () => () => {};
    export const useRouter = () => ({ navigate: () => {} });
    export const useRouterState = ({ select }) => select({ location: { pathname: t().path } });
    export const useMatch = () => undefined;`,
  "@tanstack/react-query": `
    export const keepPreviousData = (value) => value;
    export const useQueryClient = () => ({ invalidateQueries: async () => {} });
    export const useQuery = (options) => ({
      data: undefined, isLoading: false, isError: false, isFetching: false, isSuccess: false,
      refetch: () => {}, ...globalThis.__staff.query(options.queryKey),
    });`,
  "@tanstack/react-start": `
    const builder = () => { const b = { middleware: () => b, inputValidator: () => b, validator: () => b, handler: (h) => h }; return b; };
    export const createServerFn = () => builder();
    export const createMiddleware = () => ({ server: () => ({}) });
    export const useServerFn = (fn) => fn;`,
  "@/integrations/supabase/auth-middleware": `export const requireSupabaseAuth = {};`,
  "@/integrations/supabase/client": `export const supabase = { auth: { signOut: async () => {} } };`,
  "@/hooks/use-active-org": `export const useActiveOrg = () => ({ active: globalThis.__staff.org, memberships: [], loading: false });`,
  // A closed dialog renders nothing; the real one is exercised in the browser harness.
  "@/components/ui/alert-dialog": `
    import { createElement } from "react";
    const passthrough = ({ children }) => createElement("div", null, children);
    export const AlertDialog = ({ open, children }) => (open ? createElement("div", { role: "alertdialog" }, children) : null);
    export const AlertDialogContent = passthrough, AlertDialogHeader = passthrough, AlertDialogFooter = passthrough,
      AlertDialogTitle = passthrough, AlertDialogDescription = passthrough;
    export const AlertDialogAction = ({ children, onClick }) => createElement("button", { onClick }, children);
    export const AlertDialogCancel = ({ children }) => createElement("button", null, children);`,
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
  import { StaffCartProvider } from "@/components/staff/StaffCartProvider";
  export { Route as Composer } from "@/routes/_authenticated/staff/request";
  export { Route as History } from "@/routes/_authenticated/staff/requests";
  export { Route as Detail } from "@/routes/_authenticated/staff/requests.$id";
  export function render(Component) {
    return renderToStaticMarkup(createElement(StaffCartProvider, null, createElement(Component)));
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
      name: "staff-stubs",
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

const org = {
  id: "m-1",
  organizationId: uuid(1),
  role: "staff",
  defaultTeamId: uuid(201),
  defaultLocationId: uuid(301),
  organizationName: "Henry Athletics",
};

function setStaff(options: {
  path: string;
  search?: Record<string, unknown>;
  params?: Record<string, string>;
  queries?: Record<string, unknown>;
}) {
  (globalThis as { __staff?: unknown }).__staff = {
    path: options.path,
    search: options.search ?? {},
    params: options.params ?? {},
    org,
    query: (key: unknown[]) => {
      const name = key.map(String).join(":");
      for (const [prefix, result] of Object.entries(options.queries ?? {})) {
        if (name.includes(prefix)) return result;
      }
      return {};
    },
  };
}

// ---------------------------------------------------------------------------
// Lifecycle

test("cancellation uses exactly the Phase 6C edit window", () => {
  for (const status of SUPPLY_REQUEST_STATUSES) {
    assert.equal(canRequesterCancelSupplyRequest(status), status === "submitted", status);
    assert.equal(canRequesterCancelSupplyRequest(status), canRequesterEditSupplyRequest(status));
  }
});

test("cancelled is terminal and no admin transition reaches it", () => {
  assert.ok(SUPPLY_REQUEST_STATUSES.includes("cancelled"));
  for (const status of SUPPLY_REQUEST_STATUSES) {
    assert.equal(canTransitionSupplyRequest(status, "cancelled"), false, status);
    assert.equal(canTransitionSupplyRequest("cancelled", status), false, status);
  }
  assert.equal(canRequesterEditSupplyRequest("cancelled"), false);
  assert.equal(
    requesterEditGuidance("cancelled"),
    "You cancelled this request. It will not be reviewed or fulfilled.",
  );
  // Denied and completed behavior is unchanged.
  assert.equal(requesterEditGuidance("denied"), null);
  assert.equal(requesterEditGuidance("completed"), null);
});

// ---------------------------------------------------------------------------
// Staff status, history and timeline

test("cancelled maps to the staff label Cancelled in its own terminal group", () => {
  assert.deepEqual(translateStaffRequestStatus("cancelled"), {
    label: "Cancelled",
    description: "You cancelled this request",
    group: "CANCELLED",
  });
  assert.equal(translateStaffRequestStatus("denied").label, "Declined");
  assert.equal(translateStaffRequestStatus("completed").label, "Completed");
});

test("cancelled requests are history, never in progress or ready", () => {
  assert.ok(!(STAFF_OPEN_STATUSES as readonly string[]).includes("cancelled"));
  assert.ok((STAFF_PAST_STATUSES as readonly string[]).includes("cancelled"));
  const cancelled = { statusGroup: translateStaffRequestStatus("cancelled").group };
  assert.equal(isStaffOpenRequest(cancelled), false);
  assert.equal(isStaffPastRequest(cancelled), true);
  for (const status of STAFF_OPEN_STATUSES) {
    assert.equal(
      isStaffOpenRequest({ statusGroup: translateStaffRequestStatus(status).group }),
      true,
    );
  }
  for (const status of ["completed", "denied"] as const) {
    assert.equal(
      isStaffPastRequest({ statusGroup: translateStaffRequestStatus(status).group }),
      true,
    );
  }
  assert.deepEqual(
    summarizeStaffRequests([{ statusGroup: "CANCELLED" }, { statusGroup: "ACTIVE" }] as Parameters<
      typeof summarizeStaffRequests
    >[0]),
    { activeRequests: 1, readyRequests: 0, completedRequests: 0 },
  );
  // The dashboard query and split use these, not a hand-written status list.
  const dashboardFn = between(
    server,
    "export const getStaffDashboardFn",
    "export const getStaffRequestDetailFn",
  );
  assert.match(dashboardFn, /\.in\("status", \[\.\.\.STAFF_PAST_STATUSES\]\)/);
  assert.match(dashboardFn, /requests\.filter\(isStaffOpenRequest\)/);
  assert.match(dashboardFn, /requests\.filter\(isStaffPastRequest\)/);
});

test("the timeline shows the stored cancellation event with its stored timestamp", () => {
  const timeline = buildStaffRequestTimeline("2026-10-17T15:00:00Z", [
    {
      status_to: null,
      staff_visible_note: null,
      event_kind: "requester_edited",
      created_at: "2026-10-17T16:00:00Z",
    },
    {
      status_to: "cancelled",
      staff_visible_note: null,
      event_kind: "requester_cancelled",
      created_at: "2026-10-18T09:30:00Z",
    },
  ]);
  assert.deepEqual(timeline, [
    { label: "Submitted", occurredAt: "2026-10-17T15:00:00Z", message: null },
    { label: "You edited this request", occurredAt: "2026-10-17T16:00:00Z", message: null },
    { label: "Request cancelled", occurredAt: "2026-10-18T09:30:00Z", message: null },
  ]);
  // Ordinary status updates keep their label and staff-visible message.
  assert.deepEqual(
    buildStaffRequestTimeline("2026-10-17T15:00:00Z", [
      {
        status_to: "denied",
        staff_visible_note: "Already in stock",
        event_kind: null,
        created_at: "2026-10-18T00:00:00Z",
      },
    ])[1],
    { label: "Declined", occurredAt: "2026-10-18T00:00:00Z", message: "Already in stock" },
  );
  // No event, no cancellation entry: nothing is inferred from the current status.
  assert.equal(buildStaffRequestTimeline("2026-10-17T15:00:00Z", []).length, 1);
});

// ---------------------------------------------------------------------------
// Frequent & Recent, Request again

test("cancelled requests are excluded from Frequent and Recent like declined ones", () => {
  assert.deepEqual([...QUICK_PICK_EXCLUDED_STATUSES], ["denied", "cancelled"]);
  const fn = between(
    workspaceServer,
    "export const getStaffQuickPicksFn",
    "export const getStaffRequestAgainFn",
  );
  // Excluded at the request query, so no line of a cancelled request is ever loaded.
  assert.match(
    fn,
    /\.not\("status", "in", `\(\$\{QUICK_PICK_EXCLUDED_STATUSES\.join\(","\)\}\)`\)/,
  );
  assert.ok(
    fn.indexOf("QUICK_PICK_EXCLUDED_STATUSES") < fn.indexOf('from("supply_request_items")'),
  );
});

test("Request again works from a cancelled request when its products remain requestable", () => {
  const fn = workspaceServer.slice(workspaceServer.indexOf("export const getStaffRequestAgainFn"));
  assert.doesNotMatch(fn, /status/, "Request again does not filter by status");
  const lookups: AvailabilityLookups = {
    products: new Map([
      [
        uuid(1),
        {
          id: uuid(1),
          name: "Tape",
          unit_of_measure: "roll",
          manufacturer: null,
          pack_size: null,
          active: true,
          staff_requestable: true,
        },
      ],
      [
        uuid(2),
        {
          id: uuid(2),
          name: "Old wrap",
          unit_of_measure: "roll",
          manufacturer: null,
          pack_size: null,
          active: false,
          staff_requestable: true,
        },
      ],
    ]),
    inventory: new Map(),
    catalog: new Map(),
    specifications: new Map(),
  };
  const line = (n: number, productId: string | null, name: string) => ({
    id: `line-${n}`,
    productId,
    inventoryItemId: null,
    vendorProductId: null,
    catalogVendorProductId: null,
    name,
    quantity: n,
    unit: null,
    freeTextItem: productId ? null : name,
  });
  const lines = buildRequestAgainLines(
    [line(1, uuid(1), "Tape"), line(2, uuid(2), "Old wrap"), line(3, null, "Knee sleeve")],
    lookups,
  );
  assert.deepEqual(
    lines.map((entry) => [entry.name, entry.availability.status, entry.quantity]),
    [
      ["Tape", "available", 1],
      ["Old wrap", "unavailable", 2],
      ["Knee sleeve", "custom", 3],
    ],
  );
  assert.equal(lines[0].selection?.productId, uuid(1));
});

// ---------------------------------------------------------------------------
// Admin

test("admin active queues exclude cancelled requests; history keeps them", () => {
  assert.deepEqual(translateAdminRequestStatus("cancelled"), {
    queueGroup: "COMPLETED",
    statusLabel: "Cancelled by requester",
    nextAction: null,
  });
  const make = (id: string, status: Parameters<typeof translateAdminRequestStatus>[0]) =>
    ({
      id,
      ...translateAdminRequestStatus(status),
      lifecycleStatus: status,
    }) as unknown as Parameters<typeof buildAdminRequestDashboard>[0][number];
  const dashboard = buildAdminRequestDashboard([
    make("a", "submitted"),
    make("b", "cancelled"),
    make("c", "denied"),
    make("d", "approved"),
  ]);
  assert.deepEqual(
    dashboard.queues.needsReview.map((request) => request.id),
    ["a"],
  );
  assert.deepEqual(
    dashboard.queues.awaitingOrder.map((request) => request.id),
    ["d"],
  );
  assert.deepEqual(
    dashboard.queues.completed.map((request) => request.id),
    ["b", "c"],
  );
  assert.equal(dashboard.summary.needsReview, 1);
  // The admin detail offers no action for a cancelled request.
  const adminDetail = read("src/components/admin/supply-requests/AdminRequestDetail.tsx");
  assert.doesNotMatch(between(adminDetail, "const primaryTransition", "};"), /cancelled/);
});

// ---------------------------------------------------------------------------
// Edit experience

test("removing the final edit line leads to cancellation, never an empty save", () => {
  const one = [createCustomCartItem("k1", "Ankle brace", 1)];
  assert.equal(editCompletion(one), "save");
  assert.equal(editCompletion(removeCartItem(one, "k1")), "cancel_only");
  assert.equal(EMPTY_EDIT_STATE.title, "No items left in this request.");
  assert.match(EMPTY_EDIT_STATE.body, /can't be saved without items/);
  assert.match(EMPTY_EDIT_STATE.body, /cancel it/);
  assert.deepEqual(CANCEL_REQUEST_CONFIRMATION, {
    title: "Cancel this request?",
    body: "This request will no longer be reviewed or fulfilled. It will remain in your request history.",
    confirm: "Cancel request",
    keep: "Keep request",
  });
  // The save path still refuses an empty cart, and the save button renders only with items.
  const submit = between(
    composer,
    "function submit(event: React.FormEvent)",
    "async function confirmSubmit()",
  );
  assert.match(submit, /if \(items\.length === 0 \|\| busy\) return;/);
  assert.match(composer, /\{hasItems && \(\s+<div className="sticky/);
  assert.doesNotMatch(composer, /Add an item to save your changes/);
});

test("edit-while-submitted still saves through the Phase 6C RPC", () => {
  const save = between(composer, "async function saveChanges()", "if (submittedRequestId)");
  assert.match(save, /await updateFn\(/);
  assert.match(save, /items: items\.map\(toSubmissionItem\)/);
  assert.match(server, /rpc\("update_submitted_supply_request"/);
});

test("cancellation requires an explicit, destructive confirmation", () => {
  assert.match(cancelAction, /<AlertDialog open=\{open\}/);
  assert.match(cancelAction, /CANCEL_REQUEST_CONFIRMATION\.title/);
  assert.match(cancelAction, /CANCEL_REQUEST_CONFIRMATION\.keep/);
  assert.match(cancelAction, /bg-\[#b42318\]/, "destructive styling");
  // The mutation runs only from the dialog's confirm action, once per tap.
  const trigger = between(cancelAction, '<button\n        type="button"', "</button>");
  assert.doesNotMatch(trigger, /cancelFn/);
  const confirm = between(cancelAction, "async function confirmCancel", "\n  return (");
  assert.match(confirm, /event\.preventDefault\(\)/);
  assert.match(confirm, /if \(cancelling\.current\) return;/);
  assert.match(confirm, /await cancelFn\(\{ data: \{ organizationId, requestId \} \}\)/);
  assert.match(confirm, /invalidateQueries\(\{ queryKey: \["me", organizationId\] \}\)/);
  assert.doesNotMatch(cancelAction, /window\.confirm|confirm\(/);
});

test("cancel is offered from request detail and both edit states, only when allowed", () => {
  assert.match(staffDetail, /request\.data\.canCancel && active && \(\s+<CancelRequestAction/);
  assert.match(
    composer,
    /const showCancelFromEdit = isEditMode && !!editingRequest\?\.canCancel && !!active;/,
  );
  assert.equal((composer.match(/<CancelRequestAction/g) ?? []).length, 2);
  assert.match(composer, /\{showCancelFromEdit && hasItems && \(/);
  assert.match(composer, /\{editIsEmpty && \(/);
  // After cancelling from edit mode the requester lands on the (now cancelled) request.
  assert.match(
    composer,
    /navigate\(\{ to: "\/staff\/requests\/\$id", params: \{ id: editingRequest!\.id \} \}\)/,
  );
  assert.match(server, /canCancel: canRequesterCancelSupplyRequest\(lifecycleStatus\)/);
});

// ---------------------------------------------------------------------------
// Server function and migrations

test("the server function delegates to the canonical RPC with only the request id", () => {
  const fn = between(
    server,
    "export const cancelSubmittedSupplyRequestFn",
    "export const listMyRequestsFn",
  );
  assert.match(fn, /requireSupabaseAuth/);
  assert.match(fn, /cancelSubmittedSupplyRequestInputSchema\.parse\(d\)/);
  assert.match(fn, /requireMembership\(context, data\.organizationId\)/);
  assert.match(
    fn,
    /rpc\("cancel_submitted_supply_request", \{\s+_organization_id: data\.organizationId,\s+_request_id: data\.requestId,\s+\}\)/,
  );
  assert.doesNotMatch(fn, /\.from\(|\.update\(|\.delete\(|requested_by|userId/);
  assert.deepEqual(Object.keys(cancelSubmittedSupplyRequestInputSchema.shape).sort(), [
    "organizationId",
    "requestId",
  ]);
  assert.throws(() =>
    cancelSubmittedSupplyRequestInputSchema.parse({ organizationId: "x", requestId: uuid(1) }),
  );
  assert.match(types, /cancel_submitted_supply_request: \{/);
  assert.match(types, /\| "denied"\n\s+\| "cancelled"/);
});

test("the status migration only appends the enum value, outside the RPC transaction", () => {
  const code = statusMigration.replace(/--.*$/gm, "").trim();
  assert.equal(
    code,
    "ALTER TYPE public.supply_request_status ADD VALUE IF NOT EXISTS 'cancelled';",
  );
  assert.doesNotMatch(migrationCode, /ALTER TYPE/);
  assert.match(migrationCode, /^\s*BEGIN;[\s\S]*COMMIT;\s*$/);
});

test("the migration is additive: no row rewrite, deletion, or unrelated object change", () => {
  assert.doesNotMatch(migrationCode, /DELETE FROM|TRUNCATE|DROP (TABLE|FUNCTION|POLICY|TRIGGER)/i);
  assert.doesNotMatch(
    migrationCode,
    /UPDATE public\.supply_requests\s+SET status = 'cancelled'\s+WHERE status/,
  );
  assert.equal((migrationCode.match(/DROP CONSTRAINT/g) ?? []).length, 1);
  assert.match(migrationCode, /DROP CONSTRAINT supply_request_updates_event_kind_check/);
  assert.equal((migrationCode.match(/CREATE (OR REPLACE )?FUNCTION/g) ?? []).length, 2);
  assert.doesNotMatch(
    migrationCode,
    /POLICY|GRANT .* ON TABLE|decide_supply_request\(|transition_supply_request\(|get_budget/,
  );
  // Preflight refuses to run twice or onto unexpected data.
  assert.match(migration, /Phase 6C\.2 requires the cancelled supply_request_status value/);
  assert.match(migration, /found cancelled requests before the cancellation workflow exists/);
});

test("the cancel RPC authenticates, scopes, locks, and enforces ownership and the window", () => {
  const order = [
    "IF _uid IS NULL THEN",
    "IF NOT public.is_org_member(_organization_id, _uid) THEN",
    "FOR UPDATE;",
    "IF NOT FOUND OR _request.requested_by IS DISTINCT FROM _uid THEN",
    "IF _request.status = 'cancelled' THEN",
    "IF _request.status = 'denied' THEN",
    "IF _request.status <> 'submitted' OR EXISTS (",
    "UPDATE public.supply_requests",
    "INSERT INTO public.supply_request_updates",
  ];
  let last = -1;
  for (const step of order) {
    const at = cancelFunction.indexOf(step, last + 1);
    assert.ok(at > last, `out of order or missing: ${step}`);
    last = at;
  }
  assert.match(cancelFunction, /SECURITY DEFINER\s+SET search_path = public/);
  assert.match(
    cancelFunction,
    /WHERE id = _request_id\s+AND organization_id = _organization_id\s+FOR UPDATE;/,
  );
  assert.match(cancelFunction, /'Supply request not found' USING ERRCODE = 'P0002'/);
  assert.match(
    cancelFunction,
    /'This request has already entered review and can no longer be cancelled\.'/,
  );
  assert.match(cancelFunction, /'This request has been declined and can no longer be cancelled\.'/);
  // The same window rule as the Phase 6C edit RPC.
  const editWindow = between(
    phase6cMigration,
    "IF _request.status <> 'submitted' OR EXISTS (",
    ") THEN",
  );
  assert.ok(cancelFunction.includes(editWindow));
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.cancel_submitted_supply_request\(uuid, uuid\) FROM PUBLIC, anon;\s+GRANT EXECUTE ON FUNCTION public\.cancel_submitted_supply_request\(uuid, uuid\) TO authenticated;/,
  );
});

test("cancelling changes only the status and writes one authoritative event", () => {
  const write = between(
    cancelFunction,
    "UPDATE public.supply_requests",
    "RETURNING created_at INTO _cancelled_at;",
  );
  assert.match(
    write,
    /SET status = 'cancelled'\s+WHERE id = _request\.id\s+AND organization_id = _organization_id;/,
  );
  assert.doesNotMatch(write, /notes|team_id|location_id|request_type|quantity/);
  assert.match(
    write,
    /\(organization_id, supply_request_id, author_id, status_from, status_to, event_kind\)\s+VALUES\s+\(_organization_id, _request\.id, _uid, 'submitted', 'cancelled', 'requester_cancelled'\)/,
  );
  assert.doesNotMatch(
    cancelFunction,
    /supply_request_items|DELETE|commitment\(|release_|budget|inventory|invoice/i,
  );
  // The audit constraint fixes the event shape and keeps admin notes out of it.
  const constraint = between(
    migration,
    "ADD CONSTRAINT supply_request_updates_event_kind_check CHECK (",
    ");",
  );
  assert.match(constraint, /event_kind IS NULL\s+AND status_to IS DISTINCT FROM 'cancelled'/);
  assert.match(
    constraint,
    /event_kind = 'requester_cancelled'\s+AND status_from = 'submitted'\s+AND status_to = 'cancelled'\s+AND internal_note IS NULL\s+AND staff_visible_note IS NULL/,
  );
  assert.match(
    constraint,
    /event_kind = 'requester_edited'\s+AND status_from IS NULL\s+AND status_to IS NULL\s+AND internal_note IS NULL\s+AND staff_visible_note IS NULL/,
  );
});

test("a repeat cancellation is an idempotent no-op that returns the original time", () => {
  const repeat = between(
    cancelFunction,
    "IF _request.status = 'cancelled' THEN",
    "IF _request.status = 'denied' THEN",
  );
  assert.match(repeat, /'alreadyCancelled', true/);
  assert.match(repeat, /event_kind = 'requester_cancelled'/);
  assert.doesNotMatch(repeat, /INSERT|UPDATE/);
  assert.match(cancelFunction, /'alreadyCancelled', false/);
});

test("the edit RPC is the Phase 6C body plus only a cancelled-request message", () => {
  const edited = between(
    migration,
    "CREATE OR REPLACE FUNCTION public.update_submitted_supply_request",
    "\n$$;",
  ).replace("CREATE OR REPLACE FUNCTION", "CREATE FUNCTION");
  const original = between(
    phase6cMigration,
    "CREATE FUNCTION public.update_submitted_supply_request",
    "\n$$;",
  );
  const added = `  IF _request.status = 'cancelled' THEN
    RAISE EXCEPTION 'This request has been cancelled and can no longer be edited.'
      USING ERRCODE = '55000';
  END IF;
`;
  assert.ok(edited.includes(added));
  assert.equal(edited.replace(added, ""), original);
});

test("the staff projection already returns the cancellation event without internal notes", () => {
  const projection = between(
    phase6cMigration,
    "CREATE FUNCTION public.list_staff_supply_request_updates",
    "REVOKE ALL ON FUNCTION public.list_staff_supply_request_updates",
  );
  assert.match(projection, /u\.status_to IS NOT NULL/);
  assert.doesNotMatch(projection, /internal_note/);
  assert.doesNotMatch(migrationCode, /list_staff_supply_request_updates/);
});

test("budget and command center math never count a cancelled request", () => {
  // Commitments are created only on approval; a cancellable request never has one.
  assert.match(
    read("supabase/migrations/20260914120000_phase6a2_request_commitments.sql"),
    /IF _request\.status NOT IN \('approved', 'ordered', 'received', 'completed'\) THEN/,
  );
  // Awaiting approval and settlement candidates name explicit statuses.
  assert.match(commandCenter, /request\.status IN \('submitted', 'under_review'\)/);
  assert.match(
    commandCenter,
    /request\.status IN \('received', 'completed'\) AS settlement_candidate/,
  );
  assert.doesNotMatch(commandCenter, /status <> 'denied'|status NOT IN \('denied'/);
  assert.match(
    read("src/lib/inventory-intelligence.functions.ts"),
    /OPEN_REQUEST_STATUSES = \['submitted', 'under_review', 'approved', 'ordered', 'received'\]/,
  );
});

test("SQL behavioral coverage is rollback-only and covers the required cases", () => {
  assert.match(behavior, /^[\s\S]*?BEGIN;/);
  assert.match(behavior, /ROLLBACK;\s*$/);
  for (const needle of [
    "Supply request not found",
    "Not a member of this organization",
    "Not authenticated",
    "This request has already entered review and can no longer be cancelled.",
    "This request has been declined and can no longer be cancelled.",
    "Cancelling changed the request lines",
    "Cancelling rewrote the request",
    "Expected exactly one edit and one cancellation event",
    "Repeat cancellation was not idempotent",
    "This request has been cancelled and can no longer be edited.",
    "Unexpected staff timeline",
    "awaitingApprovalCount",
    "Invalid supply request transition: cancelled to under_review",
    "Invalid supply request transition: approved to cancelled",
    "Edit-while-submitted regressed",
    "This request has been declined and can no longer be edited.",
    "Cancellation created a commitment",
  ]) {
    assert.ok(behavior.includes(needle), needle);
  }
});

// ---------------------------------------------------------------------------
// Rendered staff states

const ready = (data: unknown) => ({ data, isSuccess: true });

function detail(
  status: Parameters<typeof translateStaffRequestStatus>[0],
  extra: Record<string, unknown> = {},
) {
  const translated = translateStaffRequestStatus(status);
  return {
    id: uuid(501),
    itemCount: 1,
    items: [
      {
        id: "a",
        productId: uuid(2),
        inventoryItemId: null,
        vendorProductId: null,
        catalogVendorProductId: null,
        name: "Tape",
        quantity: 3,
        unit: "roll",
      },
    ],
    itemName: "Tape",
    quantity: 3,
    unit: "roll",
    statusLabel: translated.label,
    statusDescription: translated.description,
    statusGroup: translated.group,
    submittedAt: "2026-10-17T15:00:00Z",
    lastUpdatedAt: "2026-10-18T15:00:00Z",
    staffMessage: null,
    timeline: [{ label: "Submitted", occurredAt: "2026-10-17T15:00:00Z", message: null }],
    lifecycleStatus: status,
    canEdit: canRequesterEditSupplyRequest(status),
    canCancel: canRequesterCancelSupplyRequest(status),
    editGuidance: requesterEditGuidance(status),
    requestType: "reorder",
    teamId: uuid(201),
    locationId: uuid(301),
    notes: "For the away game",
    ...extra,
  };
}

test("a submitted request's detail offers Edit and Cancel request, without opening the dialog", () => {
  setStaff({
    path: `/staff/requests/${uuid(501)}`,
    params: { id: uuid(501) },
    queries: { requests: ready(detail("submitted")) },
  });
  const html = ui.render(ui.Detail.options.component);
  assert.match(html, /Edit request/);
  assert.match(html, /Cancel request/);
  assert.match(html, /Request again/);
  assert.doesNotMatch(html, /role="alertdialog"/);
});

test("a cancelled request stays viewable with its items, note and cancellation history", () => {
  const cancelled = detail("cancelled", {
    timeline: [
      { label: "Submitted", occurredAt: "2026-10-17T15:00:00Z", message: null },
      { label: "Request cancelled", occurredAt: "2026-10-18T09:30:00Z", message: null },
    ],
  });
  setStaff({
    path: `/staff/requests/${uuid(501)}`,
    params: { id: uuid(501) },
    queries: { requests: ready(cancelled) },
  });
  const html = ui.render(ui.Detail.options.component);
  assert.match(html, />Cancelled</);
  assert.match(html, /Tape/);
  assert.match(html, /× 3/);
  assert.match(html, /For the away game/);
  assert.match(html, /Request cancelled<span[^>]*> · <\/span><time[^>]*>Oct 18<\/time>/);
  assert.match(html, /You cancelled this request\. It will not be reviewed or fulfilled\./);
  assert.match(html, /Request again/);
  assert.doesNotMatch(html, /Edit request|Cancel request/);
});

test("an emptied edit shows the no-items state with Cancel request and no save", () => {
  // Static rendering does not run the preload effect, so the edit cart is empty, exactly
  // as after removing the final line.
  setStaff({
    path: "/staff/request",
    search: { edit: uuid(501) },
    queries: {
      requests: ready(detail("submitted")),
      "quick-picks": ready({ frequent: [], recent: [] }),
    },
  });
  const html = ui.render(ui.Composer.options.component);
  assert.match(html, /No items left in this request\./);
  assert.match(html, /cancel it if you no longer need anything/);
  assert.match(html, /Cancel request/);
  assert.doesNotMatch(html, /type="submit"/);
  assert.doesNotMatch(html, /Save changes/);
});

test("a cancelled request opened in edit mode is read-only", () => {
  setStaff({
    path: "/staff/request",
    search: { edit: uuid(501) },
    queries: { requests: ready(detail("cancelled")) },
  });
  const html = ui.render(ui.Composer.options.component);
  assert.match(html, /You cancelled this request/);
  assert.doesNotMatch(html, /Cancel request|Save changes|No items left/);
});

test("My Requests lists a cancelled request under past requests", () => {
  const card = (
    status: Parameters<typeof translateStaffRequestStatus>[0],
    n: number,
    name: string,
  ) => {
    const {
      timeline: _timeline,
      items,
      ...rest
    } = detail(status, { id: uuid(600 + n), itemName: name });
    return { ...rest, items: items.map((item) => ({ ...item, id: `${n}`, name })) };
  };
  setStaff({
    path: "/staff/requests",
    queries: {
      history: ready({
        summary: {},
        openRequests: [card("submitted", 1, "Gauze")],
        pastRequests: [card("cancelled", 2, "Cold packs")],
        hasMorePastRequests: false,
      }),
    },
  });
  const html = ui.render(ui.History.options.component);
  assert.match(html, /In progress · 1/);
  assert.ok(html.indexOf("Past requests") < html.indexOf("Cold packs"));
  assert.match(html, /Cancelled/);
});

// Phase 7C: receiving destination. Pure rules (destinations, labels, last-used), the rendered
// picker and staff timeline, the server wiring and the migration's shape. Database behavior is
// proven by supabase/tests/phase7c_receiving_destination_behavior.sql, phase7c_race_check.sh,
// phase7c_mutation_check.sh and tests/phase7c-receiving-destination-integration.test.ts.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import test, { after } from "node:test";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  UNASSIGNED_DESTINATION_LABEL,
  actionNeedsDestination,
  deliveredToLabel,
  initialDestinationId,
  orderReceivingDestinations,
  parseReceiptSummaries,
  parseReceivingDestinations,
  readLastUsedDestination,
  receivingDestinationLabel,
  rememberLastUsedDestination,
  type ReceivingDestination,
} from "../src/supply-requests/receiving.ts";
import { buildStaffRequestTimeline } from "../src/supply-requests/staff-dashboard.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const migration = read("supabase/migrations/20261112140000_phase7c_receiving_destination.sql");
const migrationCode = migration.replace(/--.*$/gm, "");
const between = (text: string, start: string, end: string) => {
  const from = text.indexOf(start);
  assert.ok(from >= 0, start);
  const to = text.indexOf(end, from + start.length);
  assert.ok(to >= 0, end);
  return text.slice(from, to);
};

// Bundle the UI for rendering before any test is registered (as in the 6C.3 and 7C.0 tests).
const cacheDir = join(root, `node_modules/.cache/phase7c-receiving-test-${process.pid}`);
mkdirSync(cacheDir, { recursive: true });
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
  export { ReceivingDestinationPicker } from "@/components/admin/supply-requests/ReceivingDestinationPicker";
  export { RequestDetailTimeline } from "@/components/staff/RequestDetailTimeline";
  export function render(component, props) { return renderToStaticMarkup(createElement(component, props)); }
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
      name: "alias",
      setup(pluginBuild) {
        pluginBuild.onResolve({ filter: /^@\// }, (args) => ({
          path: resolveSource(join(root, "src", args.path.slice(2))),
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
    .replace(/\s+/g, " ");

const destinations: ReceivingDestination[] = [
  { id: "u", name: "Unassigned", kind: "unassigned" },
  { id: "f", name: "First Team ATR", kind: "storage" },
  { id: "a", name: "Academy ATR", kind: "storage" },
];

// ---------------------------------------------------------------------------------------------
// Destinations and labels

test("destinations parse strictly and list storage by name, then Unassigned / not yet placed", () => {
  assert.deepEqual(
    parseReceivingDestinations([
      ...destinations,
      { id: 1 },
      { id: "x", name: "Bad", kind: "shelf" },
      null,
    ]),
    destinations,
  );
  assert.deepEqual(parseReceivingDestinations(null), []);
  assert.deepEqual(
    orderReceivingDestinations(destinations).map((d) => receivingDestinationLabel(d)),
    ["Academy ATR", "First Team ATR", UNASSIGNED_DESTINATION_LABEL],
  );
  assert.equal(UNASSIGNED_DESTINATION_LABEL, "Unassigned / not yet placed");
});

test("only the receiving actions need a destination", () => {
  assert.equal(actionNeedsDestination("mark_received"), true);
  assert.equal(actionNeedsDestination("receive_and_complete"), true);
  for (const kind of ["approve", "approve_and_order", "mark_ordered", "complete"] as const) {
    assert.equal(actionNeedsDestination(kind), false, kind);
  }
  assert.equal(actionNeedsDestination(null), false);
});

test("last-used destination is a browser convenience: preselected only while still active", () => {
  const store = new Map<string, string>();
  const storage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
  };
  assert.equal(readLastUsedDestination("org", storage), null);
  rememberLastUsedDestination("org", "f", storage);
  assert.equal(readLastUsedDestination("org", storage), "f");
  assert.equal(readLastUsedDestination("other-org", storage), null);
  assert.equal(initialDestinationId(destinations, "f"), "f");
  assert.equal(initialDestinationId(destinations, "archived-id"), "");
  assert.equal(initialDestinationId(destinations, null), "");
  // Blocked storage never breaks receiving.
  const broken = {
    getItem: () => {
      throw new Error("blocked");
    },
    setItem: () => {
      throw new Error("blocked");
    },
  };
  assert.equal(readLastUsedDestination("org", broken), null);
  assert.doesNotThrow(() => rememberLastUsedDestination("org", "f", broken));
});

test("receipt summaries parse; staff wording uses the name snapshot", () => {
  assert.deepEqual(
    parseReceiptSummaries([
      {
        supply_request_id: "r",
        supply_request_update_id: "u",
        inventory_location_id: null,
        destination_name: "First Team ATR",
        destination_kind: "storage",
        received_at: "2026-11-12T15:00:00Z",
        compound_action: null,
      },
    ]),
    [
      {
        supplyRequestId: "r",
        supplyRequestUpdateId: "u",
        destinationName: "First Team ATR",
        destinationKind: "storage",
        receivedAt: "2026-11-12T15:00:00Z",
        compoundAction: null,
      },
    ],
  );
  assert.equal(deliveredToLabel("First Team ATR", "storage"), "Delivered to First Team ATR");
  assert.equal(deliveredToLabel("Unassigned", "unassigned"), "Received, not yet placed");
});

// ---------------------------------------------------------------------------------------------
// Rendered picker and staff timeline

test("the picker requires an explicit choice and shows the request's team/location as context only", () => {
  const html = render(ui.ReceivingDestinationPicker, {
    destinations,
    value: "",
    onChange: () => {},
    loading: false,
    error: false,
    onRetry: () => {},
    disabled: false,
    requestTeam: "First Team",
    requestLocation: "First Team ATR",
  });
  const content = text(html);
  assert.match(content, /Receiving destination \(required\)/);
  assert.match(content, /does not move inventory/);
  assert.match(html, /<select[^>]*required/);
  assert.match(
    html,
    /<option value="" disabled="" selected="">Choose where it was received…<\/option>/,
  );
  // Nothing is preselected, even though the request location shares a destination's name.
  assert.equal((html.match(/selected=""/g) ?? []).length, 1);
  assert.match(content, /Academy ATR.*First Team ATR.*Unassigned \/ not yet placed/);
  assert.match(content, /Requested for: First Team · First Team ATR/);
  const loading = text(
    render(ui.ReceivingDestinationPicker, {
      destinations: [],
      value: "",
      onChange: () => {},
      loading: true,
      error: false,
      onRetry: () => {},
      disabled: false,
      requestTeam: null,
      requestLocation: null,
    }),
  );
  assert.match(loading, /Loading destinations/);
});

const at = "2026-11-12T15:00:00.000Z";
test("staff timeline: the received step says where it was delivered; bundles keep it", () => {
  const detailed = buildStaffRequestTimeline(at, [
    { status_to: "ordered", staff_visible_note: null, event_kind: null, created_at: at },
    {
      status_to: "received",
      staff_visible_note: "In the fridge",
      event_kind: null,
      created_at: at,
      receiving_destination: "First Team ATR",
      receiving_destination_kind: "storage",
    },
  ]);
  assert.deepEqual(detailed.at(-1), {
    label: "Ready",
    occurredAt: at,
    message: "In the fridge",
    destination: "Delivered to First Team ATR",
  });
  const lean = buildStaffRequestTimeline(
    at,
    [
      {
        status_to: "received",
        staff_visible_note: null,
        event_kind: null,
        created_at: at,
        compound_action: "receive_and_complete",
        receiving_destination: "Unassigned",
        receiving_destination_kind: "unassigned",
      },
      {
        status_to: "completed",
        staff_visible_note: "Done",
        event_kind: null,
        created_at: at,
        compound_action: "receive_and_complete",
      },
    ],
    "lean",
  );
  assert.deepEqual(lean.at(-1), {
    label: "Completed",
    occurredAt: at,
    message: "Done",
    destination: "Received, not yet placed",
  });
  // Older receipts without a destination render as before.
  assert.deepEqual(
    buildStaffRequestTimeline(at, [
      { status_to: "received", staff_visible_note: null, event_kind: null, created_at: at },
    ]).at(-1),
    { label: "Ready", occurredAt: at, message: null },
  );
  const html = text(render(ui.RequestDetailTimeline, { items: detailed }));
  assert.match(html, /Delivered to First Team ATR/);
});

// ---------------------------------------------------------------------------------------------
// Wiring

test("the drawer requires a destination before receiving; no confirmation dialog", () => {
  const detail = read("src/components/admin/supply-requests/AdminRequestDetail.tsx");
  assert.match(
    detail,
    /const needsDestination = actionNeedsDestination\(action\?\.kind\) && !declining;/,
  );
  assert.match(detail, /disabled=\{busy \|\| \(needsDestination && !destinationId\)\}/);
  assert.match(
    detail,
    /if \(needsDestination && !destinationId\) \{\s+setDenialError\("Choose where this delivery was received\."\)/,
  );
  assert.match(detail, /<ReceivingDestinationPicker destinations=\{destinations\}/);
  assert.match(detail, /requestTeam=\{request\.team\} requestLocation=\{request\.location\}/);
  assert.match(detail, /data-testid="receipt-destination"/);
  assert.doesNotMatch(detail, /AlertDialog|window\.confirm|confirm\(/);
  const route = read("src/routes/_authenticated/supply-requests.tsx");
  assert.match(route, /enabled: !!active && selected\?\.lifecycleStatus === "ordered"/);
  assert.match(route, /rememberLastUsedDestination\(organizationId, inventoryLocationId\)/);
});

test("server functions send the destination and read receipts through the narrow RPCs", () => {
  const server = read("src/lib/supply-requests.functions.ts");
  const receive = between(
    server,
    "export const receiveSupplyRequestFn",
    "export const receiveAndCompleteSupplyRequestFn",
  );
  assert.match(
    receive,
    /if \(!data\.inventoryLocationId\) throw new Error\("Choose where this delivery was received\."\)/,
  );
  assert.match(receive, /_inventory_location_id: data\.inventoryLocationId/);
  const complete = between(
    server,
    "export const receiveAndCompleteSupplyRequestFn",
    "export const listReceivingDestinationsFn",
  );
  assert.match(complete, /_inventory_location_id: data\.inventoryLocationId/);
  const list = between(
    server,
    "export const listReceivingDestinationsFn",
    "async function loadReceipts",
  );
  assert.match(list, /requireAdmin\(context, data\.organizationId\)/);
  assert.match(list, /rpc\("list_receiving_destinations"/);
  assert.match(server, /rpc\("list_supply_request_receipts"/);
  assert.doesNotMatch(server, /from\("inventory_locations"\)|from\("supply_request_receipts"\)/);
  assert.match(
    read("src/supply-requests/admin-request-inbox.ts"),
    /inventoryLocationId: z\.string\(\)\.uuid\(\)\.optional\(\)/,
  );
});

test("the migration is destination-only: no stock movement, no fallback, generic receipt closed", () => {
  assert.doesNotMatch(
    migrationCode,
    /inventory_apply_balance_delta|apply_inventory_location_delta|INSERT INTO public\.inventory_|UPDATE public\.inventory_|inventory_transfers/,
  );
  assert.doesNotMatch(
    migrationCode,
    /(CREATE|DROP|ALTER) (OR REPLACE )?FUNCTION public\.(post_reviewed_invoice|delete_invoice_permanently|decide_supply_request|apply_supply_request_transition|create_supply_request_commitment|capture_supply_request_decision_notification)\(/,
  );
  assert.match(
    migrationCode,
    /DROP FUNCTION public\.apply_supply_request_receipt\(uuid, uuid, text, text\);/,
  );
  assert.match(
    migrationCode,
    /DROP FUNCTION public\.receive_supply_request\(uuid, uuid, text, text\);/,
  );
  assert.match(
    migrationCode,
    /DROP FUNCTION public\.receive_and_complete_supply_request\(uuid, uuid, text, text\);/,
  );
  assert.match(
    migrationCode,
    /IF _status = 'received' THEN\s+RAISE EXCEPTION 'Use the receiving action to choose a receiving destination\.'/,
  );
  assert.match(
    migrationCode,
    /CONSTRAINT supply_request_receipts_request_key UNIQUE \(supply_request_id\)/,
  );
  assert.match(
    migrationCode,
    /REVOKE ALL ON public\.supply_request_receipts FROM PUBLIC, anon, authenticated, service_role;/,
  );
  assert.doesNotMatch(migrationCode, /'40001'/);
});

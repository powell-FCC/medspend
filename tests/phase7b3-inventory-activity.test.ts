// Phase 7B.3: Inventory activity (transfers and manual adjustments). Pure activity rules;
// structural checks of the migration, routes, navigation and server functions; rendered
// owner/admin UI. Database behavior is covered by
// supabase/tests/phase7b3_inventory_activity_history_behavior.sql (and
// phase7b3_mutation_check.sh); the API with real JWTs by
// run_phase7b3_activity_integration.sh.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  ADJUSTMENT_TOTALS_NOTE,
  NO_LOCATION_LABEL,
  activityDateRange,
  adjustmentEmptyMessage,
  adjustmentHistoryReasons,
  adjustmentLocationLabel,
  adjustmentReasonLabel,
  formatActivityQuantity,
  formatAdjustmentAmount,
  transferDirection,
  transferEmptyMessage,
  transferRouteLabel,
} from "../src/inventory/activity.ts";
import { formatCountDateTime } from "../src/inventory/count-history.ts";
import { workspaceTabs } from "../src/inventory/workspace.ts";
import { locationAdjustmentReasons } from "../src/types/inventory.ts";
import type { AdjustmentHistoryRow, TransferHistoryRow } from "../src/types/inventory-workspace.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const migration = read(
  "supabase/migrations/20261029140000_phase7b3_inventory_activity_history.sql",
);
const migrationCode = migration.replace(/--.*$/gm, "");
const functionBody = (name: string) => {
  const start = migration.indexOf(`CREATE FUNCTION public.${name}(`);
  assert.ok(start >= 0, name);
  return migration.slice(start, migration.indexOf("\n$$;", start));
};
const readFunctions = ["list_inventory_transfer_history", "list_inventory_adjustment_history"];
const newSources = [
  "src/inventory/activity.ts",
  "src/components/inventory/workspace/ActivityPanel.tsx",
  "src/components/inventory/workspace/ActivityFilters.tsx",
  "src/components/inventory/workspace/ActivityTables.tsx",
  "src/components/inventory/workspace/useActivityFilterState.ts",
];

// Bundle the UI before any test is registered, so cleanup cannot race the build.
const cacheDir = join(root, "node_modules/.cache/phase7b3-activity-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));
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
  export { renderToStaticMarkup } from "react-dom/server";
  export { createElement } from "react";
  export { TransferHistoryTable, AdjustmentHistoryTable } from "@/components/inventory/workspace/ActivityTables";
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
      name: "activity-aliases",
      setup(pluginBuild) {
        pluginBuild.onResolve({ filter: /^@\// }, (args) => ({
          path: resolveSource(join(root, "src", args.path.slice(2))),
        }));
      },
    },
  ],
});
const ui = createRequire(import.meta.url)(bundlePath);
const render = (component: unknown, props: Record<string, unknown>) =>
  ui.renderToStaticMarkup(ui.createElement(component, props)) as string;
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ");

const TRAINING = "7b300000-0000-4000-8000-0000000000b1";
const STADIUM = "7b300000-0000-4000-8000-0000000000b2";
const transfer = (overrides: Partial<TransferHistoryRow> = {}): TransferHistoryRow => ({
  transferId: "7b300000-0000-4000-8000-0000000000a1",
  createdAt: "2026-10-29T14:42:00Z",
  inventoryItemId: "7b300000-0000-4000-8000-000000000501",
  itemName: 'Elastic Wrap 4"',
  itemSku: "WRAP-4",
  itemUnit: "each",
  quantity: 6,
  fromLocationId: TRAINING,
  fromLocationName: "Training Room",
  toLocationId: STADIUM,
  toLocationName: "Stadium",
  createdBy: "7b300000-0000-4000-8000-000000000001",
  createdByName: "Aaron Powell",
  ...overrides,
});
const adjustment = (overrides: Partial<AdjustmentHistoryRow> = {}): AdjustmentHistoryRow => ({
  adjustmentId: "7b300000-0000-4000-8000-0000000000c1",
  createdAt: "2026-10-29T14:42:00Z",
  inventoryItemId: "7b300000-0000-4000-8000-000000000501",
  itemName: 'Elastic Wrap 4"',
  itemSku: "WRAP-4",
  itemUnit: "each",
  locationId: TRAINING,
  locationName: "Training Room",
  previousQuantity: 24,
  adjustmentAmount: -3,
  newQuantity: 21,
  reason: "Damaged",
  sourceType: "manual",
  createdBy: "7b300000-0000-4000-8000-000000000001",
  createdByName: "Aaron Powell",
  ...overrides,
});

// ---------------------------------------------------------------------------------------
// Pure rules.
// ---------------------------------------------------------------------------------------
test("adjustment amounts: zero, positive and negative, exact to six decimals", () => {
  assert.equal(formatAdjustmentAmount(0), "0");
  assert.equal(formatAdjustmentAmount(-0), "0");
  assert.equal(formatAdjustmentAmount(2), "+2");
  assert.equal(formatAdjustmentAmount(-3), "-3");
  assert.equal(formatAdjustmentAmount(0.25), "+0.25");
  assert.equal(formatAdjustmentAmount(-0.000001), "-0.000001");
  assert.equal(formatActivityQuantity(6, "each"), "6 each");
  assert.equal(formatActivityQuantity(4.25, "box"), "4.25 box");
  assert.equal(formatActivityQuantity(1, " "), "1 units");
});

test("transfer direction is seen from the location; the route reads from → to", () => {
  assert.equal(transferDirection(transfer(), TRAINING), "out");
  assert.equal(transferDirection(transfer(), STADIUM), "in");
  assert.equal(transferDirection(transfer(), "elsewhere"), null);
  assert.equal(transferRouteLabel(transfer()), "Training Room → Stadium");
});

test("empty states: top level, filtered and per location", () => {
  assert.equal(
    transferEmptyMessage({ filtered: false, forLocation: false }),
    "No inventory transfers have been recorded yet.",
  );
  assert.equal(
    transferEmptyMessage({ filtered: true, forLocation: true }),
    "No transfers match these filters.",
  );
  assert.equal(
    transferEmptyMessage({ filtered: false, forLocation: true }),
    "No transfers have been recorded for this location yet.",
  );
  assert.equal(
    adjustmentEmptyMessage({ filtered: false, forLocation: false }),
    "No manual inventory adjustments have been recorded yet.",
  );
  assert.equal(
    adjustmentEmptyMessage({ filtered: true, forLocation: false }),
    "No adjustments match these filters.",
  );
  assert.equal(
    adjustmentEmptyMessage({ filtered: false, forLocation: true }),
    "No manual adjustments have been recorded for this location yet.",
  );
});

test("reasons: the stored values, no new ones, and never Physical count", () => {
  assert.deepEqual(
    [...adjustmentHistoryReasons],
    [...locationAdjustmentReasons, "Invoice received"],
    "the location-adjustment reasons plus older manual rows that chose Invoice received",
  );
  assert.ok(!(adjustmentHistoryReasons as readonly string[]).includes("Physical count"));
  for (const reason of adjustmentHistoryReasons)
    assert.equal(adjustmentReasonLabel(reason), reason);
  assert.equal(adjustmentReasonLabel(" "), "No reason recorded");
  assert.equal(adjustmentLocationLabel(null), NO_LOCATION_LABEL);
  assert.equal(adjustmentLocationLabel("Stadium"), "Stadium");
  const body = functionBody("list_inventory_adjustment_history");
  assert.match(
    body,
    /_reason NOT IN \('Manual adjustment', 'Damaged', 'Expired', 'Correction', 'Invoice received'\)/,
    "the database accepts exactly the same reasons",
  );
});

test("date inputs become a half-open range in the viewer's time zone", () => {
  const range = activityDateRange("2026-10-01", "2026-10-29");
  assert.equal(range.createdFrom, new Date(2026, 9, 1).toISOString());
  assert.equal(range.createdBefore, new Date(2026, 9, 30).toISOString());
  assert.deepEqual(activityDateRange("", ""), { createdFrom: null, createdBefore: null });
});

test("copy is factual: no inference about why quantities changed", () => {
  const source = newSources.map(read).join("\n");
  assert.doesNotMatch(
    source,
    /\b(theft|stolen|steal|waste[ds]?|loss|lost|shrink(age)?(?!-)|misuse|missing|discrepanc\w*|unlogged|unaccounted|consum\w+|usage|staff error)\b/i,
  );
  assert.equal(
    ADJUSTMENT_TOTALS_NOTE,
    "Before and after are the item's recorded total across all locations at the time.",
  );
  assert.match(
    read("src/components/inventory/workspace/ActivityPanel.tsx"),
    /Physical count corrections are shown in Counts\./,
  );
});

// ---------------------------------------------------------------------------------------
// The migration.
// ---------------------------------------------------------------------------------------
test("the migration is additive: two read functions, their grants and four proven indexes", () => {
  assert.match(migration, /^BEGIN;$/m);
  assert.match(migration, /^COMMIT;\s*$/m);
  assert.match(migration, /DO \$preflight\$/);
  assert.match(migration, /DO \$postcheck\$/);
  assert.doesNotMatch(
    migrationCode,
    /CREATE\s+(TABLE|UNIQUE|POLICY|TRIGGER|VIEW)|ALTER\s+(TABLE|POLICY|FUNCTION)|DROP\s|CREATE OR REPLACE|GRANT\s+\w+(,\s*\w+)*\s+ON\s+(TABLE\s+)?public\.|INSERT\s+INTO|DELETE\s+FROM|UPDATE\s+public|TRUNCATE/i,
  );
  const created = [...migrationCode.matchAll(/CREATE FUNCTION public\.(\w+)\(/g)]
    .map((m) => m[1])
    .sort();
  assert.deepEqual(created, [...readFunctions].sort());
  const indexes = [
    ...migrationCode.matchAll(/CREATE INDEX (\w+)\s+ON public\.(\w+) \(([^)]*)\)/g),
  ].map((m) => `${m[1]}|${m[2]}|${m[3]}`);
  assert.deepEqual(indexes, [
    "inventory_transfers_org_created_idx|inventory_transfers|organization_id, created_at DESC, id DESC",
    "inventory_transfers_from_created_idx|inventory_transfers|from_inventory_location_id, created_at DESC, id DESC",
    "inventory_transfers_to_created_idx|inventory_transfers|to_inventory_location_id, created_at DESC, id DESC",
    "inventory_adjustments_manual_org_created_idx|inventory_adjustments|organization_id, created_at DESC, id DESC",
  ]);
  assert.doesNotMatch(
    migrationCode,
    /CREATE\s+TEMP/i,
    "no temp tables: the SQL Editor must send it unchanged",
  );
  assert.match(migrationCode, /set_config\('medspend\.phase7b3_raw_access', [\s\S]*, true\)/);
  assert.match(
    migrationCode,
    /current_setting\('medspend\.phase7b3_raw_access', true\) IS DISTINCT FROM/,
  );
  assert.doesNotMatch(migrationCode, /\b(budget|spend|shrink|consumption)\b/i, "no analytics");
});

test("both reads: owner or admin only, organization-scoped, stable, keyset paged, no prices", () => {
  for (const name of readFunctions) {
    const body = functionBody(name);
    assert.match(
      body,
      /\nSTABLE\nSECURITY DEFINER\nSET search_path = public\nSET plan_cache_mode = force_custom_plan/,
      name,
    );
    assert.match(
      body,
      /IF auth\.uid\(\) IS NULL OR NOT public\.is_org_admin\(_organization_id, auth\.uid\(\)\) THEN\n\s+RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';/,
      name,
    );
    assert.match(body, /organization_id = _organization_id/, name);
    assert.match(body, /list_organization_member_identities\(_organization_id\)/, name);
    assert.match(body, /'Former member'/, name);
    assert.match(body, /ORDER BY \w+\.created_at DESC, \w+\.id DESC/, name);
    assert.match(body, /\(\w+\.created_at, \w+\.id\) < \(_after_created_at, _after_id\)/, name);
    assert.doesNotMatch(
      body,
      /price|last_purchase|email|raw_user_meta|idempotency|source_invoice/i,
      name,
    );
    assert.doesNotMatch(body, /OFFSET/i, name);
    assert.match(
      migration,
      new RegExp(`REVOKE ALL ON FUNCTION public\\.${name}\\([^)]*\\) FROM PUBLIC, anon;`),
    );
    assert.match(
      migration,
      new RegExp(`GRANT EXECUTE ON FUNCTION public\\.${name}\\([^)]*\\) TO authenticated;`),
    );
  }
  const transfers = functionBody("list_inventory_transfer_history");
  assert.match(transfers, /WHERE transfer\.from_inventory_location_id = _inventory_location_id/);
  assert.match(transfers, /WHERE transfer\.to_inventory_location_id = _inventory_location_id/);
  assert.doesNotMatch(transfers, /inventory_adjustments/);
  const adjustments = functionBody("list_inventory_adjustment_history");
  assert.match(
    adjustments,
    /AND \(adjustment\.source_type = 'manual' OR \(adjustment\.source_type IS NULL AND adjustment\.reason <> 'Invoice received'\)\)/,
    "manual rows only: never physical_count, never invoice receipts",
  );
  assert.match(
    migration,
    /WHERE \(source_type = 'manual' OR \(source_type IS NULL AND reason <> 'Invoice received'\)\);/,
    "the partial index predicate is the same predicate",
  );
  assert.match(
    adjustments,
    /LEFT JOIN public\.inventory_locations location/,
    "location-less rows stay",
  );
});

// ---------------------------------------------------------------------------------------
// Routes, navigation and server functions.
// ---------------------------------------------------------------------------------------
test("Activity joins the workspace and every location page, Unassigned included", () => {
  assert.deepEqual(workspaceTabs, ["items", "locations", "counts", "activity"]);
  const workspace = read("src/components/inventory/workspace/InventoryWorkspacePage.tsx");
  assert.match(workspace, /<TabsTrigger value="activity">Activity<\/TabsTrigger>/);
  assert.match(workspace, /<ActivityPanel organizationId=\{active\.organizationId\} \/>/);
  assert.doesNotMatch(
    workspace,
    /Transfers<\/TabsTrigger>|Adjustments<\/TabsTrigger>/,
    "no separate top-level tabs",
  );
  const panel = read("src/components/inventory/workspace/ActivityPanel.tsx");
  assert.match(
    panel,
    /<TabsTrigger value="transfers">Transfers<\/TabsTrigger>\n\s+<TabsTrigger value="adjustments">Adjustments<\/TabsTrigger>/,
  );
  assert.match(panel, /"transfer-history", state\.filters/);
  assert.match(panel, /"adjustment-history", filters/, "each list pages independently");
  const detail = read("src/components/inventory/workspace/LocationDetailPage.tsx");
  assert.match(detail, /\{storage && <TabsTrigger value="labels">Labels<\/TabsTrigger>\}/);
  assert.match(detail, /\{storage && <TabsTrigger value="counts">Counts<\/TabsTrigger>\}/);
  assert.match(
    detail,
    /\n\s+<TabsTrigger value="activity">Activity<\/TabsTrigger>/,
    "not storage-only",
  );
  assert.match(
    detail,
    /<ActivityPanel organizationId=\{organizationId\} locationId=\{location\.id\} \/>/,
  );
  assert.match(
    detail,
    /tab=\{location\.data\.kind === "unassigned" && tab !== "activity" \? "stock" : tab\}/,
    "Unassigned never opens Labels or Counts",
  );
});

test("staff get nothing new: /inventory stays admin-only and /count is untouched", () => {
  const gate = read("src/routes/_authenticated/route.tsx");
  assert.match(gate, /const ADMIN_ROUTES = \[[^\]]*"\/inventory"/);
  for (const path of [
    "src/routes/_authenticated/count.index.tsx",
    "src/routes/_authenticated/count.$token.tsx",
    "src/routes/_authenticated/count.location.$locationId.tsx",
    "src/lib/inventory-count.functions.ts",
    "src/inventory/count.ts",
  ])
    assert.doesNotMatch(read(path), /Activity|transfer_history|adjustment_history/, path);
});

test("server functions: authenticated, validated, and read-only RPCs only", () => {
  const fns = read("src/lib/inventory-workspace.functions.ts");
  for (const name of ["listTransferHistoryFn", "listAdjustmentHistoryFn"]) {
    const start = fns.indexOf(`export const ${name}`);
    assert.ok(start >= 0, name);
    const block = fns.slice(start, fns.indexOf("\nexport const", start + 1));
    assert.match(block, /\.middleware\(\[requireSupabaseAuth\]\)/, name);
    assert.match(block, /\.inputValidator\(/, name);
  }
  assert.match(fns, /limit: z\.number\(\)\.int\(\)\.min\(1\)\.max\(200\)\.default\(50\)/);
  const reads = read("src/inventory/workspace-reads.ts");
  const activityReads = reads.slice(reads.indexOf("// Phase 7B.3"));
  assert.deepEqual(
    [...activityReads.matchAll(/db\.(rpc|from)\("(\w+)"/g)].map((m) => `${m[1]}:${m[2]}`),
    ["rpc:list_inventory_transfer_history", "rpc:list_inventory_adjustment_history"],
    "no raw table reads",
  );
});

// ---------------------------------------------------------------------------------------
// Rendered UI. Owners and admins get the same read-only view: these components take no
// role and render no controls that change anything.
// ---------------------------------------------------------------------------------------
test("transfers table: date, item, from, to, quantity and who; read-only", () => {
  const html = render(ui.TransferHistoryTable, {
    rows: [
      transfer(),
      transfer({ transferId: "x2", createdByName: "Former member", quantity: 0.5 }),
    ],
    emptyMessage: "x",
  });
  const plain = text(html);
  for (const heading of ["Date / time", "Item", "From", "To", "Quantity", "Moved by"])
    assert.ok(plain.includes(heading), heading);
  assert.ok(!plain.includes("Direction"), "no direction column at the top level");
  assert.ok(plain.includes('Elastic Wrap 4" · WRAP-4'));
  assert.ok(plain.includes("Training Room → Stadium"), "mobile card route");
  assert.ok(plain.includes("6 each"));
  assert.ok(plain.includes("0.5 each"));
  assert.ok(plain.includes("Aaron Powell"));
  assert.ok(plain.includes("Former member"));
  assert.ok(plain.includes(formatCountDateTime("2026-10-29T14:42:00Z")));
  assert.doesNotMatch(html, /<button|<input|<form/i);
  assert.match(html, /overflow-x-auto md:block/, "the table scrolls inside its panel");
  assert.match(html, /md:hidden/, "phones get cards");
});

test("a location's transfers say OUT or IN", () => {
  const rows = [
    transfer(),
    transfer({
      transferId: "x2",
      fromLocationId: "unassigned",
      fromLocationName: "Unassigned",
      toLocationId: TRAINING,
      toLocationName: "Training Room",
    }),
  ];
  const plain = text(
    render(ui.TransferHistoryTable, { rows, locationId: TRAINING, emptyMessage: "x" }),
  );
  assert.ok(plain.includes("Direction"));
  assert.ok(plain.includes("OUT Training Room → Stadium"));
  assert.ok(plain.includes("IN Unassigned → Training Room"));
});

test("adjustments table: totals before and after, signed amount, reason and who", () => {
  const rows = [
    adjustment(),
    adjustment({
      adjustmentId: "x2",
      previousQuantity: 12,
      adjustmentAmount: 2,
      newQuantity: 14,
      reason: "Correction",
      locationName: "Stadium",
    }),
    adjustment({
      adjustmentId: "x3",
      previousQuantity: 10.5,
      adjustmentAmount: 0,
      newQuantity: 10.5,
      reason: "Correction",
      locationId: null,
      locationName: null,
      sourceType: null,
      createdByName: "Former member",
    }),
  ];
  const html = render(ui.AdjustmentHistoryTable, { rows, showLocation: true, emptyMessage: "x" });
  const plain = text(html);
  for (const heading of [
    "Date / time",
    "Item",
    "Location",
    "Total before",
    "Adjustment",
    "Total after",
    "Reason",
    "Adjusted by",
  ])
    assert.ok(plain.includes(heading), heading);
  assert.ok(plain.includes("-3 each"));
  assert.ok(plain.includes("+2 each"));
  assert.ok(plain.includes(" 0 each"));
  assert.ok(plain.includes("Total 24 → 21 · Damaged"), "mobile card");
  assert.ok(plain.includes("Total 10.5 → 10.5 · Correction"));
  assert.ok(plain.includes(NO_LOCATION_LABEL));
  assert.ok(plain.includes("Former member"));
  assert.doesNotMatch(plain, /Physical count|Invoice/);
  assert.doesNotMatch(html, /<button|<input|<form/i);
  const scoped = text(
    render(ui.AdjustmentHistoryTable, {
      rows: [adjustment()],
      showLocation: false,
      emptyMessage: "x",
    }),
  );
  assert.ok(!scoped.includes("Location"), "a location's own list omits the location column");
});

test("empty lists show the message they are given", () => {
  const message = transferEmptyMessage({ filtered: false, forLocation: true });
  assert.ok(
    text(render(ui.TransferHistoryTable, { rows: [], emptyMessage: message })).includes(message),
  );
  const filtered = adjustmentEmptyMessage({ filtered: true, forLocation: false });
  assert.ok(
    text(
      render(ui.AdjustmentHistoryTable, { rows: [], showLocation: true, emptyMessage: filtered }),
    ).includes(filtered),
  );
});

// ---------------------------------------------------------------------------------------
// Release files.
// ---------------------------------------------------------------------------------------
test("release files: precheck and postcheck end with the shared fingerprint; nothing writes", () => {
  const dir = "supabase/release/phase7b3";
  const fingerprint = read(`${dir}/fingerprint.sql`);
  const select = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM"));
  for (const name of ["precheck.sql", "postcheck.sql"]) {
    const file = read(`${dir}/${name}`);
    assert.ok(file.endsWith(select), `${name} ends with the fingerprint`);
    // String literals (the postcheck's expected index definitions) are data, not statements.
    assert.doesNotMatch(
      file.replace(/--.*$/gm, "").replace(/'(?:[^']|'')*'/g, "''"),
      /\b(BEGIN;|COMMIT;|ROLLBACK;|INSERT\s+INTO|UPDATE\s+public|DELETE\s+FROM|CREATE\s|ALTER\s|DROP\s|GRANT\s|REVOKE\s)/i,
      name,
    );
  }
  const pre = read(`${dir}/precheck.sql`);
  assert.match(pre, /'precheck: Phase 7B\.3 objects already exist'/);
  assert.match(pre, /'precheck: Phase 7B\.2 is not applied'/);
  // 7B.2's pinned production hashes.
  assert.match(
    pre,
    /\('get_inventory_count_session', '282766d69a86d3b4d31be35de847cacb secdef=true/,
  );
  assert.match(
    pre,
    /\('list_inventory_count_history', 'c9197911f5a4242c1d36a20b622de164 secdef=true/,
  );
  const post = read(`${dir}/postcheck.sql`);
  for (const name of readFunctions) {
    assert.match(
      post,
      new RegExp(`\\('${name}', '[0-9a-f]{32} secdef=true authenticated=true anon=false'\\)`),
    );
    assert.match(fingerprint, new RegExp(`\\('${name}'\\)`), `${name} fingerprinted`);
  }
  for (const index of [
    "inventory_transfers_org_created_idx",
    "inventory_transfers_from_created_idx",
    "inventory_transfers_to_created_idx",
    "inventory_adjustments_manual_org_created_idx",
  ]) {
    assert.match(post, new RegExp(`\\('${index}', 'CREATE INDEX ${index} ON public\\.`), index);
    assert.match(fingerprint, new RegExp(`\\('${index}'\\)`), `${index} fingerprinted`);
  }
  assert.match(fingerprint, /'inventory_adjustments hash'/);
  assert.match(fingerprint, /'inventory_transfers hash'/);
  assert.match(read(`${dir}/README.md`), /117 → 119/);
});

// Phase 7B.4: Inventory Overview + Unassigned workspace. Pure overview rules; structural
// checks of the migration, routes, navigation and server functions; rendered owner/admin UI.
// Database behavior is covered by supabase/tests/phase7b4_inventory_overview_behavior.sql
// (and phase7b4_mutation_check.sh); the API with real JWTs by
// run_phase7b4_overview_integration.sh.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  RECORDED_QUANTITY_NOTE,
  UNASSIGNED_EXPLAINER,
  attentionSections,
  attentionTotal,
  moreRowsLabel,
  plural,
  recordedUnitsLabel,
} from "../src/inventory/overview.ts";
import { workspaceTabs } from "../src/inventory/workspace.ts";
import type {
  AdjustmentHistoryRow,
  CountHistoryRow,
  InventoryOverview,
  TransferHistoryRow,
} from "../src/types/inventory-workspace.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const migration = read("supabase/migrations/20261030120000_phase7b4_inventory_overview.sql");
const migrationCode = migration.replace(/--.*$/gm, "");
const functionBody = migration.slice(
  migration.indexOf("CREATE FUNCTION public.get_inventory_overview("),
  migration.indexOf("\n$$;", migration.indexOf("CREATE FUNCTION public.get_inventory_overview(")),
);
const newSources = [
  "src/inventory/overview.ts",
  "src/components/inventory/workspace/InventoryOverviewTab.tsx",
  "src/components/inventory/workspace/OverviewSections.tsx",
  "src/components/inventory/workspace/UnassignedRecentTransfers.tsx",
];

// Bundle the UI before any test is registered, so cleanup cannot race the build.
const cacheDir = join(root, "node_modules/.cache/phase7b4-overview-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));
const stubs: Record<string, string> = {
  "@tanstack/react-router": `
    import { createElement } from "react";
    export const Link = ({ to, params, search, children, className }) => {
      let href = String(to);
      for (const [key, value] of Object.entries(params ?? {})) href = href.replace("$" + key, value);
      if (search?.tab) href += "?tab=" + search.tab;
      return createElement("a", { href, className }, children);
    };`,
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
  export { renderToStaticMarkup } from "react-dom/server";
  export { createElement } from "react";
  export { OverviewSnapshotCards, NeedsAttention, RecentActivityLists } from "@/components/inventory/workspace/OverviewSections";
  export { LocationStockTable } from "@/components/inventory/workspace/LocationStockTable";
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
      name: "overview-stubs",
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
const render = (component: unknown, props: Record<string, unknown>) =>
  ui.renderToStaticMarkup(ui.createElement(component, props)) as string;
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ");

const UNASSIGNED = "7b400000-0000-4000-8000-0000000000u1";
const item = (name: string, extra: Record<string, unknown> = {}) => ({
  inventoryItemId: `item-${name}`,
  name,
  sku: `${name.toUpperCase()}-1`,
  unit: "each",
  itemActive: true,
  ...extra,
});
const overview = (overrides: Partial<InventoryOverview["attention"]> = {}): InventoryOverview => ({
  snapshot: {
    activeItemCount: 9,
    itemsInStockCount: 7,
    recordedQuantity: 17,
    stockedUnitCount: 3,
    activeStorageLocationCount: 4,
    archivedStorageLocationCount: 2,
    unassignedLocationId: UNASSIGNED,
    unassignedItemCount: 12,
    unassignedQuantity: 30.5,
  },
  attention: {
    unassignedStock: {
      total: 12,
      rows: [
        { ...item("Wrap"), quantity: 5 },
        { ...item("Old Kit", { itemActive: false }), quantity: 0.5 },
      ],
    },
    neverCountedLocations: {
      total: 1,
      rows: [{ locationId: "loc-cart", name: "Cart", countableItemCount: 3 }],
    },
    neverCountedItems: {
      total: 1,
      rows: [{ ...item("Gauze", { unit: "box" }), locationCount: 2 }],
    },
    noActiveLabel: { total: 1, rows: [{ locationId: "loc-bay", name: "Empty Bay" }] },
    archivedWithActiveLabel: {
      total: 1,
      rows: [{ locationId: "loc-closet", name: "Closet", activeLabelCount: 2 }],
    },
    ...overrides,
  },
});
const empty = { total: 0, rows: [] };

// ---------------------------------------------------------------------------------------
// Pure rules.
// ---------------------------------------------------------------------------------------
test("factual copy: Unassigned is explained neutrally; quantities are raw, not values", () => {
  assert.equal(
    UNASSIGNED_EXPLAINER,
    "Unassigned holds inventory that is not currently assigned to a physical storage location.",
  );
  assert.match(RECORDED_QUANTITY_NOTE, /Not comparable across units and not a value/);
  assert.deepEqual(
    attentionSections.map((section) => section.title),
    [
      "Stock in Unassigned",
      "Locations never counted",
      "Items never counted",
      "No active label",
      "Active label on archived location",
    ],
  );
  const source = newSources.map(read).join("\n");
  assert.doesNotMatch(
    source,
    /\b(overdue|stale|late|due|missing|lost|misplaced|shrink(age)?(?!-)|waste[ds]?|consum\w+|dead stock|excess|understock\w*|overstock\w*|theft|turns|carrying cost|months of supply|savings|valuation)\b/i,
  );
  assert.doesNotMatch(source, /\$\s?\d|\bprice|\bcost\b|\bUSD\b/i, "no money anywhere");
});

test("recorded quantity, list remainders, totals and plurals", () => {
  assert.equal(recordedUnitsLabel({ stockedUnitCount: 1 }), "In 1 unit");
  assert.equal(recordedUnitsLabel({ stockedUnitCount: 0 }), "Across 0 units");
  assert.equal(recordedUnitsLabel({ stockedUnitCount: 3 }), "Across 3 units");
  assert.equal(moreRowsLabel(12, 10), "and 2 more");
  assert.equal(moreRowsLabel(3, 3), null);
  assert.equal(attentionTotal(overview()), 16);
  assert.equal(plural(1, "item"), "1 item");
  assert.equal(plural(0, "location"), "0 locations");
});

// ---------------------------------------------------------------------------------------
// The migration.
// ---------------------------------------------------------------------------------------
test("the migration is additive: one read function and its grants, no index", () => {
  assert.match(migration, /^BEGIN;$/m);
  assert.match(migration, /^COMMIT;\s*$/m);
  assert.match(migration, /DO \$preflight\$/);
  assert.match(migration, /DO \$postcheck\$/);
  assert.doesNotMatch(
    migrationCode,
    /CREATE\s+(TABLE|INDEX|UNIQUE|POLICY|TRIGGER|VIEW|TEMP)|ALTER\s+(TABLE|POLICY|FUNCTION)|DROP\s|CREATE OR REPLACE|GRANT\s+\w+(,\s*\w+)*\s+ON\s+(TABLE\s+)?public\.|INSERT\s+INTO|DELETE\s+FROM|UPDATE\s+public|TRUNCATE/i,
  );
  assert.deepEqual(
    [...migrationCode.matchAll(/CREATE FUNCTION public\.(\w+)\(/g)].map((m) => m[1]),
    ["get_inventory_overview"],
  );
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.get_inventory_overview\(uuid, integer\) FROM PUBLIC, anon;/,
  );
  assert.match(
    migration,
    /GRANT EXECUTE ON FUNCTION public\.get_inventory_overview\(uuid, integer\) TO authenticated;/,
  );
  assert.doesNotMatch(
    functionBody.replace(/--.*$/gm, ""),
    /now\(\)|interval|submitted_at|created_at|overdue|stale|cadence|price|last_purchase|email|budget/i,
    "nothing time-based, no money, no auth metadata",
  );
});

test("the overview: owner or admin only, organization-scoped, stable, Unassigned outside count and label rules", () => {
  assert.match(functionBody, /\nSTABLE\nSECURITY DEFINER\nSET search_path = public/);
  assert.match(
    functionBody,
    /IF auth\.uid\(\) IS NULL OR NOT public\.is_org_admin\(_organization_id, auth\.uid\(\)\) THEN\n\s+RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';/,
  );
  assert.match(functionBody, /WHERE location\.organization_id = _organization_id/);
  assert.match(functionBody, /WHERE balances\.kind = 'unassigned' AND balances\.quantity > 0/);
  assert.match(
    functionBody,
    /WHERE balances\.kind = 'storage' AND balances\.location_active\n\s+AND \(balances\.item_active OR balances\.quantity > 0\)/,
    "the 7A.2 countability rule at active storage locations",
  );
  for (const list of ["no_active_label", "archived_with_label", "never_counted_locations"])
    assert.match(
      functionBody.slice(functionBody.indexOf(`${list} AS (`)),
      /location\.kind = 'storage'/,
      `${list} never includes Unassigned`,
    );
  assert.match(functionBody, /label\.revoked_at IS NULL/);
  assert.match(functionBody, /LIMIT _attention_limit/);
  assert.match(functionBody, /_attention_limit < 1 OR _attention_limit > 50/);
});

// ---------------------------------------------------------------------------------------
// Routes, navigation and server functions.
// ---------------------------------------------------------------------------------------
test("Overview is first and /inventory opens on it; older tab links keep working", () => {
  assert.deepEqual(workspaceTabs, ["overview", "items", "locations", "counts", "activity"]);
  const route = read("src/routes/_authenticated/inventory.index.tsx");
  assert.match(
    route,
    /z\s*\.enum\(\["overview", "items", "locations", "counts", "activity"\]\)\s*\.catch\("overview"\)\s*\.default\("overview"\)/,
  );
  const page = read("src/components/inventory/workspace/InventoryWorkspacePage.tsx");
  assert.match(
    page,
    /<TabsTrigger value="overview">Overview<\/TabsTrigger>\n\s+<TabsTrigger value="items">Items<\/TabsTrigger>/,
  );
  assert.match(page, /<InventoryOverviewTab organizationId=\{active\.organizationId\} \/>/);
});

test("Unassigned workspace: its stock and recent moves, still no Labels or Counts", () => {
  const detail = read("src/components/inventory/workspace/LocationDetailPage.tsx");
  assert.match(detail, /\{storage && <TabsTrigger value="labels">Labels<\/TabsTrigger>\}/);
  assert.match(detail, /\{storage && <TabsTrigger value="counts">Counts<\/TabsTrigger>\}/);
  assert.match(
    detail,
    /tab=\{location\.data\.kind === "unassigned" && tab !== "activity" \? "stock" : tab\}/,
  );
  assert.match(detail, /Stock in Unassigned/);
  assert.match(
    detail,
    /<UnassignedRecentTransfers organizationId=\{organizationId\} locationId=\{location\.id\} \/>/,
  );
  const header = read("src/components/inventory/workspace/LocationHeader.tsx");
  assert.match(header, /`\$\{UNASSIGNED_EXPLAINER\} It is never counted and has no QR labels\.`/);
  assert.match(header, /\{canManage && storage && \(/, "no rename or archive for Unassigned");
  const recent = read("src/components/inventory/workspace/UnassignedRecentTransfers.tsx");
  assert.match(recent, /limit: RECENT/);
  assert.match(recent, /search=\{\{ tab: "activity" \}\}/);
  assert.doesNotMatch(recent, /<Button|onClick/, "read-only");
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
    assert.doesNotMatch(read(path), /overview|Overview|get_inventory_overview/, path);
});

test("server function: authenticated, validated, and one read-only RPC", () => {
  const fns = read("src/lib/inventory-workspace.functions.ts");
  const start = fns.indexOf("export const getInventoryOverviewFn");
  assert.ok(start >= 0);
  const block = fns.slice(start);
  assert.match(block, /\.middleware\(\[requireSupabaseAuth\]\)/);
  assert.match(block, /\.inputValidator\(/);
  const reads = read("src/inventory/workspace-reads.ts");
  const overviewReads = reads.slice(
    reads.indexOf("// Phase 7B.4 Inventory Overview"),
    reads.indexOf("// Phase 7B.3 inventory activity"),
  );
  assert.deepEqual(
    [...overviewReads.matchAll(/db\.(rpc|from)\("(\w+)"/g)].map((m) => `${m[1]}:${m[2]}`),
    ["rpc:get_inventory_overview"],
  );
  const tab = read("src/components/inventory/workspace/InventoryOverviewTab.tsx");
  assert.match(tab, /const RECENT = 5;/);
  for (const fn of ["listCountHistoryFn", "listTransferHistoryFn", "listAdjustmentHistoryFn"])
    assert.match(tab, new RegExp(`${fn}\\b`), `recent activity reuses ${fn}`);
});

// ---------------------------------------------------------------------------------------
// Rendered UI. Owners and admins see the same read-only Overview.
// ---------------------------------------------------------------------------------------
test("snapshot cards: counts, raw recorded quantity, locations and Unassigned", () => {
  const plain = text(render(ui.OverviewSnapshotCards, { snapshot: overview().snapshot }));
  for (const piece of [
    "Active items 9",
    "7 items with stock",
    "Recorded quantity 17 Across 3 units.",
    RECORDED_QUANTITY_NOTE,
    "Storage locations 4 Active · 2 archived",
    "Stock in Unassigned 12 items 30.5 recorded",
  ])
    assert.ok(plain.includes(piece), piece);
});

test("needs attention: five lists, totals, remainders and links into the workspace", () => {
  const html = render(ui.NeedsAttention, { overview: overview() });
  const plain = text(html);
  assert.ok(plain.includes("Needs attention 16 items"));
  for (const section of attentionSections) assert.ok(plain.includes(section.title), section.title);
  assert.ok(plain.includes("Wrap 5 each"));
  assert.ok(plain.includes("Old Kit (archived) 0.5 each"));
  assert.ok(plain.includes("and 10 more"), "12 in Unassigned, 2 shown");
  assert.ok(plain.includes("Cart 3 items"));
  assert.ok(plain.includes("Gauze · GAUZE-1 2 locations"));
  assert.ok(plain.includes("Closet 2 active labels"));
  assert.match(html, new RegExp(`href="/inventory/locations/${UNASSIGNED}"[^>]*>Wrap`));
  assert.match(html, /href="\/inventory\/locations\/loc-cart"/);
  assert.match(html, /href="\/inventory\/locations\/loc-bay\?tab=labels"/);
  assert.match(html, /href="\/inventory\/locations\/loc-closet\?tab=labels"/);
  assert.doesNotMatch(html, /<button|<input|<form/i, "read-only");
});

test("needs attention: an empty list says None; nothing at all is a positive state", () => {
  const clean = overview({
    unassignedStock: empty,
    neverCountedLocations: empty,
    neverCountedItems: empty,
    noActiveLabel: empty,
    archivedWithActiveLabel: empty,
  });
  const plain = text(render(ui.NeedsAttention, { overview: clean }));
  assert.ok(plain.includes("Nothing needs attention"));
  assert.equal(plain.match(/\bNone\b/g)?.length, 5);
});

test("recent activity: three short lists linking to the full histories", () => {
  const count = {
    sessionId: "session-1",
    submittedAt: "2026-10-29T15:04:00Z",
    locationName: "Shelf",
    countedByName: "Sam Staff",
    changedCount: 0,
  } as CountHistoryRow;
  const transfer = {
    transferId: "t1",
    createdAt: "2026-10-29T15:00:00Z",
    itemName: "Wrap",
    itemUnit: "each",
    quantity: 6,
    fromLocationName: "Unassigned",
    toLocationName: "Shelf",
    createdByName: "Former member",
  } as TransferHistoryRow;
  const adjustment = {
    adjustmentId: "a1",
    createdAt: "2026-10-29T14:00:00Z",
    itemName: "Gauze",
    itemUnit: "box",
    adjustmentAmount: -1,
    reason: "Damaged",
    createdByName: "Olivia Owner",
  } as AdjustmentHistoryRow;
  const html = render(ui.RecentActivityLists, {
    counts: [count],
    transfers: [transfer],
    adjustments: [adjustment],
  });
  const plain = text(html);
  assert.ok(plain.includes("Recent inventory activity"));
  assert.ok(plain.includes("Shelf"));
  assert.ok(plain.includes("No corrections"));
  assert.ok(plain.includes("Wrap 6 each Unassigned → Shelf"));
  assert.ok(plain.includes("Gauze -1 box Damaged"));
  assert.match(html, /href="\/inventory\/counts\/session-1"/);
  assert.match(html, /href="\/inventory\?tab=counts"/);
  assert.equal(html.match(/href="\/inventory\?tab=activity"/g)?.length, 2);
  const none = text(render(ui.RecentActivityLists, { counts: [], transfers: [], adjustments: [] }));
  for (const message of [
    "No physical counts yet.",
    "No transfers yet.",
    "No manual adjustments yet.",
  ])
    assert.ok(none.includes(message), message);
});

test("stock in Unassigned: phone cards and the desktop table; owner-only actions", () => {
  const unassigned = { id: UNASSIGNED, name: "Unassigned", kind: "unassigned", active: true };
  const rows = [
    {
      inventoryItemId: "i1",
      name: "Wrap",
      sku: "W-1",
      unit: "each",
      quantity: 5,
      itemActive: true,
      organizationQuantity: 9,
      organizationParLevel: null,
      organizationStockStatus: "healthy",
      lastCountedAt: null,
    },
  ];
  const admin = render(ui.LocationStockTable, { location: unassigned, rows, canManage: false });
  assert.match(admin, /<ul class="[^"]*md:hidden[^"]*" aria-label="Stock">/, "phones get cards");
  assert.match(
    admin,
    /hidden overflow-x-auto rounded-xl border bg-card md:block/,
    "the table from md up",
  );
  assert.ok(text(admin).includes("Wrap 5 each"));
  assert.doesNotMatch(admin, /<button/i, "admins read only");
  assert.doesNotMatch(text(admin), /Not counted yet|Counted here/, "Unassigned is never counted");
  const owner = render(ui.LocationStockTable, {
    location: unassigned,
    rows,
    canManage: true,
    onAction: () => {},
  });
  assert.equal(owner.match(/aria-label="Move Wrap"/g)?.length, 2, "card and table both offer Move");
  assert.equal(
    text(
      render(ui.LocationStockTable, { location: unassigned, rows: [], canManage: false }),
    ).trim(),
    "Nothing is waiting in Unassigned.",
  );
});

// ---------------------------------------------------------------------------------------
// Release files.
// ---------------------------------------------------------------------------------------
test("release files: precheck and postcheck end with the shared fingerprint; nothing writes", () => {
  const dir = "supabase/release/phase7b4";
  const fingerprint = read(`${dir}/fingerprint.sql`);
  const select = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM"));
  for (const name of ["precheck.sql", "postcheck.sql"]) {
    const file = read(`${dir}/${name}`);
    assert.ok(file.endsWith(select), `${name} ends with the fingerprint`);
    // String literals (the expected index definitions) are data, not statements.
    assert.doesNotMatch(
      file.replace(/--.*$/gm, "").replace(/'(?:[^']|'')*'/g, "''"),
      /\b(BEGIN;|COMMIT;|ROLLBACK;|INSERT\s+INTO|UPDATE\s+public|DELETE\s+FROM|CREATE\s|ALTER\s|DROP\s|GRANT\s|REVOKE\s)/i,
      name,
    );
    // 7B.3 and 7B.2 stay pinned to their production hashes.
    assert.match(
      file,
      /\('list_inventory_transfer_history', '3eab2bd18e8e7cf85c1ea7d8ae07c9ad secdef=true/,
    );
    assert.match(
      file,
      /\('list_inventory_adjustment_history', '91feed7b530af4840f976b2afdff1365 secdef=true/,
    );
    assert.match(
      file,
      /\('list_inventory_count_history', 'c9197911f5a4242c1d36a20b622de164 secdef=true/,
    );
    assert.match(file, /\('inventory_transfers_org_created_idx', 'CREATE INDEX /);
  }
  assert.match(read(`${dir}/precheck.sql`), /'precheck: Phase 7B\.4 objects already exist'/);
  assert.match(read(`${dir}/precheck.sql`), /'precheck: Phase 7B\.3 is not applied'/);
  assert.match(
    read(`${dir}/postcheck.sql`),
    /\('get_inventory_overview', '[0-9a-f]{32} secdef=true authenticated=true anon=false'\)/,
  );
  assert.match(fingerprint, /\('get_inventory_overview'\)/);
  assert.match(fingerprint, /'inventory_location_labels hash'/);
  assert.match(read(`${dir}/README.md`), /119 → 120/);
});

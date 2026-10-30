// Phase 7B.1: Inventory admin workspace. Pure workspace rules; structural checks of the
// migration, release scripts, routes, navigation and server functions; rendered owner and
// admin UI. Database behavior is covered by
// supabase/tests/phase7b1_inventory_admin_workspace_behavior.sql; the API with real JWTs and
// more rows than the API row cap by run_phase7b1_workspace_integration.sh; the release
// scripts by phase7b1_release_check.sh.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { stockLocationLabel } from "../src/inventory/locations.ts";
import { getInventoryStatus } from "../src/inventory/status.ts";
import {
  canArchiveWorkspaceLocation,
  countAgeLabel,
  inventoryWorkspaceAccess,
  replaceFailureMessage,
  replaceLabelsCopy,
  revokeLabelsCopy,
  stockPlacementLabel,
} from "../src/inventory/workspace.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const migration = read("supabase/migrations/20261028120000_phase7b1_inventory_admin_workspace.sql");
const migrationCode = migration.replace(/--.*$/gm, "");
const functionBody = (name: string) => {
  const start = migration.indexOf(`CREATE FUNCTION public.${name}(`);
  assert.ok(start >= 0, name);
  return migration.slice(start, migration.indexOf("\n$$;", start));
};
const readFunctions = [
  "list_inventory_workspace_locations",
  "get_inventory_workspace_location",
  "list_inventory_workspace_location_stock",
  "list_inventory_workspace_items",
  "list_inventory_workspace_item_balances",
];

// Bundle the UI before any test is registered, so cleanup cannot race the build.
const cacheDir = join(root, "node_modules/.cache/phase7b1-workspace-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));
const stubs: Record<string, string> = {
  "@/components/ui/dialog": `
    import { createElement } from "react";
    const pass = (tag) => ({ children, className }) => createElement(tag, { className }, children);
    export const Dialog = ({ open, children }) => (open ? createElement("div", { role: "dialog" }, children) : null);
    export const DialogContent = pass("div"), DialogHeader = pass("div"), DialogFooter = pass("div"),
      DialogTitle = pass("h2"), DialogDescription = pass("p");`,
  "@/components/ui/dropdown-menu": `
    import { createElement } from "react";
    const pass = ({ children }) => createElement("div", null, children);
    export const DropdownMenu = pass, DropdownMenuContent = pass, DropdownMenuTrigger = pass;
    export const DropdownMenuItem = ({ children, onClick, disabled, title }) =>
      createElement("button", { onClick, disabled, title }, children);`,
  "@tanstack/react-router": `
    import { createElement } from "react";
    export const Link = ({ to, params, children, className }) =>
      createElement("a", { href: String(to).replace("$locationId", params?.locationId ?? ""), className }, children);`,
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
  export { InventoryTable } from "@/components/inventory/InventoryTable";
  export { LocationsTable } from "@/components/inventory/workspace/LocationsTable";
  export { LocationHeader } from "@/components/inventory/workspace/LocationHeader";
  export { LocationStockTable } from "@/components/inventory/workspace/LocationStockTable";
  export { LocationLabelsPanel } from "@/components/inventory/workspace/LocationLabelsPanel";
  export { LocationManageDialogs } from "@/components/inventory/workspace/LocationManageDialogs";
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
      name: "workspace-stubs",
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
const noop = async () => {
  throw new Error("not called");
};

// ---------------------------------------------------------------------------------------
// Pure workspace rules.
// ---------------------------------------------------------------------------------------
test("owners manage and admins read; staff and others get nothing", () => {
  assert.deepEqual(inventoryWorkspaceAccess("owner"), { canRead: true, canManage: true });
  assert.deepEqual(inventoryWorkspaceAccess("admin"), { canRead: true, canManage: false });
  for (const role of ["staff", undefined, "", "Owner"])
    assert.deepEqual(inventoryWorkspaceAccess(role), { canRead: false, canManage: false });
});

test("count state is factual: never counted, nothing to count, or an age; no cadence words", () => {
  const now = new Date("2026-10-28T12:00:00Z");
  const storage = { kind: "storage" as const, countableItemCount: 3, lastCountedAt: null };
  assert.equal(countAgeLabel(storage, now), "Not counted yet");
  assert.equal(countAgeLabel({ ...storage, countableItemCount: 0 }, now), "Nothing to count");
  assert.equal(
    countAgeLabel({ ...storage, lastCountedAt: "2026-10-28T08:00:00Z" }, now),
    "Counted today",
  );
  assert.equal(
    countAgeLabel({ ...storage, lastCountedAt: "2026-10-27T08:00:00Z" }, now),
    "Counted 1 day ago",
  );
  assert.equal(
    countAgeLabel({ ...storage, lastCountedAt: "2026-09-28T12:00:00Z" }, now),
    "Counted 30 days ago",
  );
  assert.equal(
    countAgeLabel({ kind: "unassigned", countableItemCount: null, lastCountedAt: null }, now),
    null,
  );
  const source =
    read("src/inventory/workspace.ts") +
    read("src/components/inventory/workspace/LocationsTable.tsx");
  assert.doesNotMatch(
    source,
    /\b(Fresh|Due|Overdue|stale)\b/,
    "no count cadence until it is approved",
  );
});

test("placement wording from the server summary matches the 7A.2 balance-based wording", () => {
  const cases = [
    { u: 0, count: 0, single: null, balances: [] },
    { u: 5, count: 0, single: null, balances: [["u", 5]] },
    { u: 0, count: 1, single: "Cabinet", balances: [["c", 3]] },
    {
      u: 2,
      count: 1,
      single: "Cabinet",
      balances: [
        ["u", 2],
        ["c", 3],
      ],
    },
    {
      u: 0,
      count: 2,
      single: null,
      balances: [
        ["c", 3],
        ["a", 1],
      ],
    },
    {
      u: 1,
      count: 2,
      single: null,
      balances: [
        ["u", 1],
        ["c", 3],
        ["a", 1],
      ],
    },
  ] as const;
  const locations = [
    { id: "u", name: "Unassigned", kind: "unassigned" as const, active: true },
    { id: "c", name: "Cabinet", kind: "storage" as const, active: true },
    { id: "a", name: "Away Cart", kind: "storage" as const, active: true },
  ];
  for (const entry of cases) {
    const balances = entry.balances.map(([loc, quantity]) => ({
      inventoryItemId: "item",
      inventoryLocationId: loc,
      quantity,
      version: 1,
      updatedAt: "",
    }));
    assert.equal(
      stockPlacementLabel({
        unassignedQuantity: entry.u,
        physicalLocationCount: entry.count,
        singlePhysicalLocationName: entry.single,
      }),
      stockLocationLabel("item", locations, balances),
    );
  }
});

test("organization-level stock status: the SQL rule and getInventoryStatus are one rule", () => {
  const status = functionBody("inventory_workspace_stock_status");
  for (const line of [
    "WHEN NOT _active THEN 'inactive'",
    "WHEN _par_level IS NULL OR _par_level <= 0 OR _quantity > _par_level THEN 'healthy'",
    "WHEN _quantity <= _par_level * 0.5 THEN 'critical'",
    "ELSE 'low'",
  ])
    assert.ok(status.includes(line), line);
  // The same cases the behavior suite checks in SQL.
  assert.equal(getInventoryStatus(5, null, false), "inactive");
  assert.equal(getInventoryStatus(2.75, 10, true), "critical");
  assert.equal(getInventoryStatus(20, 4, true), "healthy");
  assert.equal(getInventoryStatus(0, null, true), "healthy");
  assert.equal(getInventoryStatus(4, 5, true), "low");
});

test("label copy says exactly what each action does", () => {
  const active = { name: "Cabinet A", active: true };
  const archived = { name: "Old Bin", active: false };
  const revoke = revokeLabelsCopy(active, 2);
  assert.equal(
    revoke[0],
    "2 active labels for Cabinet A will stop working immediately. No new label will be issued.",
  );
  assert.match(revoke[1], /can still count Cabinet A/);
  const revokeArchived = revokeLabelsCopy(archived, 1);
  assert.equal(
    revokeArchived[0],
    "1 active label for Old Bin will stop working immediately. No new label will be issued.",
  );
  assert.equal(revokeArchived[1], "Restoring this location will not reactivate revoked labels.");
  assert.match(
    replaceLabelsCopy(active, 3),
    /3 active labels for Cabinet A will stop working, and one new label is issued/,
  );
});

test("archiving is offered only for empty storage locations", () => {
  const base = { kind: "storage" as const, active: true, name: "Cabinet", stockedItemCount: 0 };
  assert.deepEqual(canArchiveWorkspaceLocation(base), { allowed: true });
  assert.match(
    canArchiveWorkspaceLocation({ ...base, stockedItemCount: 2 }).reason!,
    /Move all stock out of Cabinet/,
  );
  assert.equal(canArchiveWorkspaceLocation({ ...base, active: false }).allowed, false);
  assert.match(
    canArchiveWorkspaceLocation({ ...base, kind: "unassigned" }).reason!,
    /protected system location/,
  );
});

// ---------------------------------------------------------------------------------------
// The migration.
// ---------------------------------------------------------------------------------------
test("the migration is additive: functions and their grants only", () => {
  assert.match(migration, /^BEGIN;$/m);
  assert.match(migration, /^COMMIT;\s*$/m);
  assert.equal(
    migration
      .slice(migration.lastIndexOf("\nCOMMIT;") + 8)
      .replace(/--.*$/gm, "")
      .trim(),
    "",
  );
  assert.match(migration, /DO \$preflight\$/);
  assert.match(migration, /DO \$postcheck\$/);
  assert.doesNotMatch(
    migrationCode,
    /CREATE\s+(TABLE|INDEX|UNIQUE|POLICY|TRIGGER|TEMP|VIEW)|ALTER\s+(TABLE|POLICY)|DROP\s|CREATE OR REPLACE|GRANT\s+\w+(,\s*\w+)*\s+ON\s+(TABLE\s+)?public\.inventory|INSERT\s+INTO|DELETE\s+FROM|TRUNCATE/i,
  );
  // The only UPDATE is the revocation inside replace_inventory_location_labels.
  const updates = migrationCode.match(/\bUPDATE\s+public\.\w+/g) ?? [];
  assert.deepEqual(updates, ["UPDATE public.inventory_location_labels"]);
  assert.ok(
    functionBody("replace_inventory_location_labels").includes(
      "UPDATE public.inventory_location_labels",
    ),
  );
  const created = [...migrationCode.matchAll(/CREATE FUNCTION public\.(\w+)\(/g)]
    .map((m) => m[1])
    .sort();
  assert.deepEqual(
    created,
    [
      ...readFunctions,
      "inventory_workspace_stock_status",
      "replace_inventory_location_labels",
    ].sort(),
  );
});

test("every read function allows owner or admin only, scopes to the organization and returns no prices", () => {
  for (const name of readFunctions) {
    const body = functionBody(name);
    assert.match(body, /SECURITY DEFINER\nSET search_path = public/, name);
    assert.match(
      body,
      /IF auth\.uid\(\) IS NULL OR NOT public\.is_org_admin\(_organization_id, auth\.uid\(\)\) THEN\n\s+RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';/,
      name,
    );
    assert.match(body, /organization_id = _organization_id/, `${name} scopes by organization`);
    assert.doesNotMatch(body, /price|last_purchase/i, name);
    assert.match(
      migration,
      new RegExp(`REVOKE ALL ON FUNCTION public\\.${name}\\([^)]*\\) FROM PUBLIC, anon;`),
      name,
    );
    assert.match(
      migration,
      new RegExp(`GRANT EXECUTE ON FUNCTION public\\.${name}\\([^)]*\\) TO authenticated;`),
      name,
    );
  }
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.inventory_workspace_stock_status\(numeric, numeric, boolean\) FROM PUBLIC, anon, authenticated;/,
  );
  // Countable counts reuse the locked 7A.2 rule rather than restating it.
  assert.match(
    functionBody("list_inventory_workspace_locations"),
    /public\.inventory_countable_balances\(_organization_id, page\.id\)/,
  );
  assert.match(
    functionBody("get_inventory_workspace_location"),
    /public\.inventory_countable_balances\(_organization_id, _location\.id\)/,
  );
  // Lists are keyset paged with a bounded page size.
  for (const name of [
    "list_inventory_workspace_locations",
    "list_inventory_workspace_location_stock",
    "list_inventory_workspace_items",
  ]) {
    assert.match(functionBody(name), /_limit < 1 OR _limit > 500/, name);
    assert.match(functionBody(name), /LIMIT _limit;?/, name);
  }
});

test("Replace labels is owner-only and one transaction around the existing issuer", () => {
  const body = functionBody("replace_inventory_location_labels");
  assert.match(body, /SECURITY DEFINER\nSET search_path = public/);
  assert.match(
    body,
    /public\.has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]::public\.org_role\[\]\)/,
  );
  assert.match(body, /FOR UPDATE;/);
  const revoke = body.indexOf("UPDATE public.inventory_location_labels");
  const issue = body.indexOf(
    "public.issue_inventory_location_label(_organization_id, _location.id)",
  );
  assert.ok(revoke > 0 && issue > revoke, "revoke, then issue through the 7A.2 issuer");
  assert.doesNotMatch(
    body,
    /gen_random_bytes|digest\(|EXCEPTION WHEN/,
    "no second token path and no swallowed failure",
  );
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.replace_inventory_location_labels\(uuid, uuid\) FROM PUBLIC, anon;/,
  );
  // 7A.2's issuer and revoker are reused, never redefined.
  assert.doesNotMatch(migration, /CREATE FUNCTION public\.(issue|revoke)_inventory_location_label/);
});

test("release scripts are SQL Editor safe and share one fingerprint", async () => {
  const rewrite = (await import(
    new URL("../supabase/tests/support/studio_sql_editor_rewrite.mjs", import.meta.url).href
  )) as { tablesMissingRLS: (sql: string) => unknown[] };
  const fingerprint = read("supabase/release/phase7b1/fingerprint.sql");
  const select = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM ("));
  for (const file of ["precheck", "postcheck"]) {
    const sql = read(`supabase/release/phase7b1/${file}.sql`);
    assert.ok(sql.endsWith(select), `${file} ends with the shared fingerprint`);
    assert.doesNotMatch(
      sql.replace(/--.*$/gm, ""),
      /^\s*\\|^\s*(BEGIN|COMMIT);|^\s*(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|GRANT|REVOKE)\s/im,
      `${file} has no meta-commands, transaction control or writes`,
    );
    assert.deepEqual(rewrite.tablesMissingRLS(sql), [], file);
  }
  assert.deepEqual(rewrite.tablesMissingRLS(migration), []);
  for (const name of [
    ...readFunctions,
    "replace_inventory_location_labels",
    "inventory_workspace_stock_status",
  ])
    assert.ok(fingerprint.includes(`('${name}')`), name);
  const readme = read("supabase/release/phase7b1/README.md");
  assert.match(readme, /108 → 115/);
  assert.match(readme, /Do not alter the Phase 7A\.2 acceptance records/);
});

// ---------------------------------------------------------------------------------------
// Application structure.
// ---------------------------------------------------------------------------------------
test("routes: /inventory tabs in the query string and a location detail route", () => {
  const layout = read("src/routes/_authenticated/inventory.tsx");
  assert.match(layout, /component: Outlet/);
  const index = read("src/routes/_authenticated/inventory.index.tsx");
  assert.match(
    index,
    // Phase 7B.2 added Counts after Items and Locations; Phase 7B.3 added Activity.
    /tab: z\.enum\(\["items", "locations", "counts", "activity"\]\)\.catch\("items"\)\.default\("items"\)/,
  );
  const detail = read("src/routes/_authenticated/inventory.locations.$locationId.tsx");
  assert.match(detail, /createFileRoute\("\/_authenticated\/inventory\/locations\/\$locationId"\)/);
  assert.match(detail, /tab: z\.enum\(\["stock", "labels", "counts", "activity"\]\)/);
  const tree = read("src/routeTree.gen.ts");
  for (const path of ["/inventory/", "/inventory/locations/$locationId"])
    assert.ok(tree.includes(`'${path}'`) || tree.includes(`"${path}"`), path);
  // The layout gate is unchanged: /inventory is an admin-shell path, so staff are redirected.
  const gate = read("src/routes/_authenticated/route.tsx");
  assert.match(gate, /const ADMIN_ROUTES = \[[^\]]*"\/inventory"/);
  assert.match(gate, /const STAFF_ROUTES = \["\/staff", "\/profile", "\/count"\];/);
});

test("navigation exposes Inventory to admins and nothing else that was owner-only", () => {
  const shell = read("src/components/app/AdminAppShell.tsx");
  assert.match(shell, /\{ to: "\/inventory", label: "Inventory", icon: Package \}/);
  assert.match(
    shell,
    /\{ to: "\/upload", label: "Upload Invoice", icon: Upload, ownerOnly: true \}/,
  );
  assert.match(shell, /\{ to: "\/invoices", label: "Invoices", icon: FileText, ownerOnly: true \}/);
  assert.equal((shell.match(/ownerOnly: true/g) ?? []).length, 2);
});

test("workspace reads go only through the owner+admin functions; no full-organization fetch", () => {
  const reads = read("src/inventory/workspace-reads.ts");
  assert.doesNotMatch(reads, /\.from\(/, "no raw table reads");
  for (const rpc of [...readFunctions, "replace_inventory_location_labels"])
    assert.match(reads, new RegExp(`rpc\\("${rpc}"`), rpc);
  const dir = join(root, "src/components/inventory/workspace");
  const ui = readdirSync(dir)
    .map((file) => read(`src/components/inventory/workspace/${file}`))
    .join("\n");
  assert.doesNotMatch(ui, /listInventoryFn|listLocationCountStatusFn|inventory_location_balances/);
  // The deployed application's server functions stay for compatibility.
  const legacy = read("src/lib/inventory.functions.ts");
  assert.match(legacy, /export const listInventoryFn/);
  assert.match(
    read("src/lib/inventory-count.functions.ts"),
    /export const listLocationCountStatusFn/,
  );
});

test("every inventory mutation server function checks the owner before its database call", () => {
  const legacy = read("src/lib/inventory.functions.ts");
  const count = read("src/lib/inventory-count.functions.ts");
  const handlers = (source: string, names: string[]) =>
    names.map((name) => {
      const start = source.indexOf(`export const ${name} =`);
      assert.ok(start >= 0, name);
      const next = source.indexOf("export const ", start + 10);
      return [name, source.slice(start, next < 0 ? undefined : next)] as const;
    });
  for (const [name, body] of [
    ...handlers(legacy, [
      "saveInventoryItemFn",
      "adjustInventoryQuantityFn",
      "setInventoryItemActiveFn",
      "saveInventoryCategoryFn",
      "deleteInventoryCategoryFn",
      "createInventoryLocationFn",
      "updateInventoryLocationFn",
      "setInventoryLocationActiveFn",
      "moveInventoryStockFn",
    ]),
    ...handlers(count, [
      "issueLocationLabelFn",
      "revokeLocationLabelsFn",
      "replaceLocationLabelsFn",
    ]),
  ]) {
    const check = body.indexOf(
      "await assertOwner(context.supabase, context.userId, data.organizationId);",
    );
    assert.ok(check > 0, `${name} checks the owner`);
    const call = Math.min(
      ...[
        body.indexOf(".rpc("),
        body.indexOf(".from("),
        body.indexOf("replaceLocationLabels("),
      ].filter((i) => i > 0),
    );
    assert.ok(call > check, `${name} checks before it writes`);
  }
  assert.match(
    read("src/inventory/owner-access.ts"),
    /if \(data\?\.role !== "owner"\) throw new Error\("Forbidden: owner access required"\);/,
  );
  assert.doesNotMatch(
    count,
    /rpc\(\s*"revoke_inventory_location_labels"[\s\S]*rpc\(\s*"issue_inventory_location_label"[\s\S]*replace/i,
  );
});

test("owner-only dialogs and controls render only when canManage", () => {
  const items = read("src/components/inventory/workspace/ItemsTab.tsx");
  const locations = read("src/components/inventory/workspace/LocationsTab.tsx");
  const detail = read("src/components/inventory/workspace/LocationDetailPage.tsx");
  assert.match(items, /\{canManage && \(\n\s+<>\n\s+<InventoryItemDialog/);
  assert.match(
    items,
    /\{canManage && \(\n\s+<div className="mb-4 flex flex-wrap justify-end gap-2">\n\s+<Button variant="outline" onClick=\{\(\) => setCategoryOpen\(true\)\}>/,
  );
  assert.match(locations, /\{canManage && <AddLocationForm/);
  assert.match(locations, /\{canManage && \(\n\s+<LocationManageDialogs/);
  assert.match(detail, /\{canManage && \(\n\s+<>\n\s+<ItemStockDialogs/);
  assert.match(detail, /onIssue=\{canManage \? \(\) => actions\.issue\(location\) : undefined\}/);
  // The Replace button calls the atomic server function, never revoke-then-issue.
  const owner = read("src/components/inventory/workspace/useLocationOwnerActions.ts");
  assert.match(owner, /return await replace\(\{ data: target\(location\) \}\)/);
  assert.match(owner, /useServerFn\(replaceLocationLabelsFn\)/);
});

// ---------------------------------------------------------------------------------------
// Rendered owner and admin UI.
// ---------------------------------------------------------------------------------------

const storage = {
  id: "c",
  name: "Cabinet A",
  description: null,
  kind: "storage",
  active: true,
  stockedItemCount: 3,
  archivedStockedItemCount: 1,
  countableItemCount: 4,
  lastCountedAt: "2026-10-20T12:00:00Z",
  lastCountedByName: "Staff Counter",
  activeLabelCount: 2,
  lastLabelIssuedAt: "2026-10-01T12:00:00Z",
};
const unassigned = {
  ...storage,
  id: "u",
  name: "Unassigned",
  kind: "unassigned",
  stockedItemCount: 4,
  countableItemCount: null,
  lastCountedAt: null,
  lastCountedByName: null,
  activeLabelCount: null,
  lastLabelIssuedAt: null,
};
const archivedLocation = {
  ...storage,
  id: "z",
  name: "Old Bin",
  active: false,
  stockedItemCount: 0,
  activeLabelCount: 1,
};
const emptyLocation = {
  ...storage,
  id: "e",
  name: "Empty Room",
  stockedItemCount: 0,
  countableItemCount: 0,
  lastCountedAt: null,
  activeLabelCount: 0,
};
const item = {
  id: "tape",
  name: "Athletic Tape",
  description: null,
  sku: "T-1",
  vendorName: "Vendor Co",
  manufacturer: "Tape Co",
  category: "Taping",
  unit: "roll",
  active: true,
  quantity: 20,
  parLevel: 4,
  stockStatus: "healthy",
  unassignedQuantity: 5,
  physicalQuantity: 15,
  physicalLocationCount: 2,
  singlePhysicalLocationName: null,
};
const stockRows = [
  {
    inventoryItemId: "a",
    name: "Archived Splints",
    sku: null,
    unit: "each",
    quantity: 5,
    itemActive: false,
    organizationQuantity: 5,
    organizationParLevel: null,
    organizationStockStatus: "inactive",
    lastCountedAt: null,
  },
  {
    inventoryItemId: "g",
    name: "Gauze",
    sku: "G-1",
    unit: "box",
    quantity: 2.75,
    itemActive: true,
    organizationQuantity: 2.75,
    organizationParLevel: 10,
    organizationStockStatus: "critical",
    lastCountedAt: "2026-10-20T12:00:00Z",
  },
];

test("items table: owners get row actions; admins get the same rows read-only", () => {
  const owner = render(ui.InventoryTable, {
    items: [item],
    canManage: true,
    onEdit: () => {},
    onLocations: () => {},
    onAdjust: () => {},
    onArchive: () => {},
  });
  const admin = render(ui.InventoryTable, { items: [item], canManage: false });
  for (const html of [owner, admin]) {
    assert.match(html, /Athletic Tape/);
    assert.match(html, /2 locations \+ Unassigned/);
    assert.match(html, /In stock/);
  }
  assert.match(owner, /aria-label="Actions for Athletic Tape"/);
  assert.match(owner, /Locations &amp; move stock/);
  assert.match(owner, /Adjust quantity/);
  for (const control of [
    /Actions for/,
    /Stock locations for/,
    />Edit</,
    /Adjust quantity/,
    /Archive/,
    /move stock/,
  ])
    assert.doesNotMatch(admin, control);
  assert.doesNotMatch(admin, /price/i);
});

test("locations table: Unassigned pinned and distinct; factual columns; owner-only actions", () => {
  const locations = [unassigned, storage, emptyLocation, archivedLocation];
  const now = new Date("2026-10-28T12:00:00Z");
  const owner = render(ui.LocationsTable, { locations, canManage: true, now });
  const admin = render(ui.LocationsTable, { locations, canManage: false, now });
  for (const html of [owner, admin]) {
    assert.ok(html.indexOf("Unassigned") < html.indexOf("Cabinet A"), "Unassigned first");
    assert.match(html, /data-location-kind="unassigned"[^>]*class="bg-muted\/40/);
    assert.match(html, /System/);
    assert.match(html, /Not counted or labeled/);
    assert.match(html, /href="\/inventory\/locations\/c"/);
    assert.match(html, /Counted 8 days ago/);
    assert.match(html, /Oct 20, 2026 · Staff Counter/);
    assert.match(html, /Nothing to count/);
    assert.match(html, /Archived/);
    for (const header of [
      "Items stocked",
      "Countable",
      "Last counted",
      "Active labels",
      "Last label issued",
    ])
      assert.ok(html.includes(header), header);
    assert.doesNotMatch(html, /\b(Fresh|Due|Overdue)\b/);
  }
  assert.match(owner, /aria-label="Actions for Cabinet A"/);
  assert.doesNotMatch(owner, /aria-label="Actions for Unassigned"/);
  assert.match(owner, /Archive \(move stock out first\)/, "a stocked location cannot be archived");
  assert.match(owner, /Restore/);
  assert.doesNotMatch(admin, /Actions for|Rename|Restore|Archive \(/);
});

test("location header: storage facts and owner actions; Unassigned system layout; admin read-only", () => {
  const now = new Date("2026-10-28T12:00:00Z");
  const owner = render(ui.LocationHeader, { location: storage, canManage: true, now });
  assert.match(owner, /Storage location/);
  assert.match(owner, /Active/);
  assert.match(owner, /Counted 8 days ago/);
  assert.match(owner, /by Staff Counter/);
  assert.match(owner, /Active QR labels/);
  assert.match(owner, /3 \(1 archived\)/);
  assert.match(owner, /Rename/);
  assert.match(owner, /Move all stock out of Cabinet A before archiving it\./);
  const admin = render(ui.LocationHeader, { location: storage, canManage: false, now });
  assert.match(admin, /Read-only/);
  assert.doesNotMatch(admin, /Rename|Archive<|Restore/);
  const system = render(ui.LocationHeader, { location: unassigned, canManage: true, now });
  assert.match(system, /System · Unassigned/);
  assert.match(system, /never counted and has no QR labels/);
  assert.doesNotMatch(system, /Rename|Archive|Restore|Last counted|QR labels<|Countable items/);
});

test("stock table: organization-level par is labeled as such; archived items flagged; owner Move/Adjust", () => {
  const owner = render(ui.LocationStockTable, {
    location: storage,
    rows: stockRows,
    canManage: true,
    onAction: () => {},
  });
  assert.match(owner, /not a threshold for this location/);
  assert.match(owner, /Organization par/);
  assert.match(owner, /Organization status/);
  assert.match(owner, /Archived item/);
  assert.match(owner, /Critical/);
  assert.match(owner, /Last counted here/);
  assert.match(owner, /Oct 20, 2026/);
  assert.match(owner, /Not counted yet/);
  assert.match(owner, /aria-label="Move Gauze"/);
  assert.match(owner, /aria-label="Adjust Gauze"/);
  assert.doesNotMatch(owner, /low stock here|location is low/i);
  const admin = render(ui.LocationStockTable, {
    location: storage,
    rows: stockRows,
    canManage: false,
  });
  assert.doesNotMatch(admin, /aria-label="Move|aria-label="Adjust|>Move<|>Adjust</);
  assert.match(admin, /Gauze/);
  const system = render(ui.LocationStockTable, {
    location: unassigned,
    rows: stockRows,
    canManage: false,
  });
  assert.doesNotMatch(system, /Last counted here/, "Unassigned is never counted");
});

test("labels panel: owner controls on active locations, revoke-only on archived ones, facts for admins", () => {
  const panel = (location: Record<string, unknown>, canManage: boolean) =>
    render(ui.LocationLabelsPanel, {
      location,
      canManage,
      origin: "https://app.sport-spend.com",
      onIssue: noop,
      onReplace: noop,
      onRevoke: noop,
    });
  const owner = panel(storage, true);
  assert.match(owner, /Issue another label/);
  assert.match(owner, /Replace labels…/);
  assert.match(owner, /Revoke labels…/);
  assert.match(owner, /Oct 1, 2026/);
  const none = panel({ ...storage, activeLabelCount: 0, lastLabelIssuedAt: null }, true);
  assert.match(none, /Issue QR label/);
  assert.doesNotMatch(none, /Replace labels|Revoke labels/);
  const archived = panel(archivedLocation, true);
  assert.match(archived, /Revoke labels…/);
  assert.doesNotMatch(archived, /Issue QR label|Issue another label|Replace labels/);
  assert.match(archived, /Restore this location to issue or replace labels/);
  assert.match(archived, /Labels are suspended while this location is archived/);
  const admin = panel(storage, false);
  assert.match(admin, /Active labels/);
  assert.match(admin, />2</);
  assert.doesNotMatch(admin, /Issue|Replace|Revoke/);
  // Revoke and Replace confirmations use the exact copy.
  const source = read("src/components/inventory/workspace/LocationLabelsPanel.tsx");
  assert.match(source, /revokeLabelsCopy\(location, count\)/);
  assert.match(source, /replaceLabelsCopy\(location, count\)/);
  assert.match(source, /replaceFailureMessage/, "a failed Replace says nothing was revoked");
  assert.doesNotMatch(source, /Print another copy/, "another copy is always a newly issued label");
});

test("archive dialog offers label revocation, unchecked by default", () => {
  const html = render(ui.LocationManageDialogs, {
    action: { kind: "archive", location: { ...storage, stockedItemCount: 0 } },
    onClose: () => {},
    onRename: noop,
    onArchive: noop,
    onRevoke: noop,
  });
  assert.match(html, /Archive Cabinet A\?/);
  assert.match(html, /Also revoke 2 active labels/);
  assert.match(html, /<input type="checkbox" class="mt-0\.5"\/>/, "unchecked");
  assert.match(html, /work again if it is restored/);
  const noLabels = render(ui.LocationManageDialogs, {
    action: { kind: "archive", location: { ...emptyLocation } },
    onClose: () => {},
    onRename: noop,
    onArchive: noop,
    onRevoke: noop,
  });
  assert.doesNotMatch(noLabels, /Also revoke/);
  const source = read("src/components/inventory/workspace/LocationManageDialogs.tsx");
  assert.match(
    source,
    /was archived, but its \$\{labels\} active label/,
    "a failed revoke reports the real state",
  );
});

// ---------------------------------------------------------------------------------------
// Preview review fixes: Locations containment at 768–1100px, SKUs, Replace failure copy.
// ---------------------------------------------------------------------------------------
test("locations grid scrolls inside its panel, never the page, and fits a 1024px viewport", () => {
  const source = read("src/components/inventory/workspace/LocationsTable.tsx");
  const template = source.match(/md:grid-cols-\[([^\]]+)\]/)![1].split("_");
  const rem = (track: string) => Number((track.match(/([\d.]+)rem/) ?? [])[1]);
  const columns = template.reduce((sum, track) => sum + rem(track), 0);
  const gaps = (template.length - 1) * 0.75; // md:gap-3
  const minWidth = Number(source.match(/md:min-w-\[([\d.]+)rem\]/)![1]);
  assert.equal(columns + gaps + 2, minWidth, "min width is the grid's real width (px-4 padding)");
  // At 1024px the workspace panel is 1024 - 2 * 32 (page padding) - 15 (scrollbar) = 945px wide.
  assert.ok(minWidth * 16 <= 945, `${minWidth * 16}px fits the panel at 1024px`);
  for (const canManage of [true, false]) {
    const html = render(ui.LocationsTable, {
      locations: [unassigned, storage, emptyLocation, archivedLocation],
      canManage,
      onRename: () => {},
      onArchive: () => {},
      onRestore: () => {},
    });
    assert.match(
      html,
      /<div class="overflow-x-auto rounded-xl border bg-card" data-testid="locations-table" role="region" aria-label="Locations" tabindex="0"><div class="md:min-w-\[57\.75rem\]">/,
      "the grid sits in a scroll container like the Items and Stock tables",
    );
    const actions = (html.match(/aria-label="Actions for /g) ?? []).length;
    assert.equal(
      actions,
      canManage ? 3 : 0,
      canManage ? "every storage row keeps its actions" : "admins get none",
    );
    assert.doesNotMatch(
      html,
      canManage ? /aria-label="Actions for Unassigned"/ : /Rename|Restore|Archive \(/,
    );
  }
});

test("SKUs never break at the hyphen", () => {
  const items = render(ui.InventoryTable, { items: [item], canManage: false });
  assert.match(items, /<td class="[^"]*whitespace-nowrap font-mono text-xs[^"]*">T-1<\/td>/);
  const stock = render(ui.LocationStockTable, {
    location: storage,
    rows: stockRows,
    canManage: false,
  });
  assert.match(stock, /<td class="[^"]*whitespace-nowrap font-mono text-xs[^"]*">G-1<\/td>/);
});

test("a failed Replace reads as sentences and still says no label was revoked", () => {
  assert.equal(replaceFailureMessage("Forced failure"), "Forced failure. No label was revoked.");
  assert.equal(replaceFailureMessage("Forced failure."), "Forced failure. No label was revoked.");
  assert.notEqual(
    replaceFailureMessage("Forced failure."),
    "Forced failure.. No label was revoked.",
  );
  assert.equal(replaceFailureMessage("Try again!"), "Try again! No label was revoked.");
  assert.equal(
    replaceFailureMessage("Restore Old Bin first?  "),
    "Restore Old Bin first? No label was revoked.",
  );
  assert.equal(replaceFailureMessage(""), "Could not replace the labels. No label was revoked.");
  const source = read("src/components/inventory/workspace/LocationLabelsPanel.tsx");
  assert.match(
    source,
    /setError\(kind === "replace" \? replaceFailureMessage\(message\) : message\);/,
  );
});

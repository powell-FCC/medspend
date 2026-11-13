// Phase 7D Replenishment V1. Pure wording and Move Stock prefill helpers; structural checks of
// the migration, server functions and wiring (including that nothing in 7D reads par_level or
// creates requests, purchases or notifications); rendered Replenishment and location UI for
// owners and admins. Database behavior is covered by
// supabase/tests/phase7d_inventory_replenishment_behavior.sql (with phase7d_mutation_check.sh and
// phase7d_race_check.sh); the API with real JWTs and the query plan at scale by
// supabase/tests/run_phase7d_replenishment_integration.sh.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  NOT_STOCKED_HERE_TEXT,
  countCadenceWarning,
  coverageText,
  donorContext,
  lastCountedText,
  moveText,
  nextMovePrefill,
  openRequestText,
  otherShortText,
  purchasingText,
  recommendationText,
  shortageText,
  validateRuleInput,
} from "../src/inventory/replenishment.ts";
import { initialMoveForm, reconcileMoveSource } from "../src/inventory/locations.ts";
import { toReplenishmentRow } from "../src/inventory/replenishment-reads.ts";
import type {
  ReplenishmentRow,
  ReplenishmentSummary,
} from "../src/types/inventory-replenishment.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const migrationPath = "supabase/migrations/20261113120000_phase7d_inventory_replenishment.sql";
const migration = read(migrationPath);
const migrationCode = migration.replace(/--.*$/gm, "");
const sevenDSources = [
  "src/types/inventory-replenishment.ts",
  "src/inventory/replenishment.ts",
  "src/inventory/replenishment-reads.ts",
  "src/lib/inventory-replenishment.functions.ts",
  "src/components/inventory/workspace/ReplenishmentTab.tsx",
  "src/components/inventory/workspace/ReplenishmentRowCard.tsx",
  "src/components/inventory/workspace/ReplenishmentRuleDialog.tsx",
  "src/components/inventory/workspace/LocationReplenishmentRules.tsx",
  "src/components/inventory/workspace/useReplenishmentRuleActions.ts",
];

// ---------------------------------------------------------------------------------------
// Rendered UI. Bundled before any test is registered, so cleanup cannot race the build.
// ---------------------------------------------------------------------------------------
const cacheDir = join(root, "node_modules/.cache/phase7d-replenishment-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));
const pending = "() => new Promise(() => {})";
const stubs: Record<string, string> = {
  "@tanstack/react-router": `
    import { createElement } from "react";
    export const Link = ({ children, className }) => createElement("a", { className }, children);`,
  "@tanstack/react-start": `export const useServerFn = (fn) => fn;`,
  "@/lib/inventory.functions": `export const adjustInventoryQuantityFn = ${pending}, moveInventoryStockFn = ${pending};`,
  "@/lib/inventory-workspace.functions": `
    export const listWorkspaceLocationsFn = ${pending}, getWorkspaceItemBalancesFn = ${pending},
      listWorkspaceItemsFn = ${pending};`,
  "@/lib/inventory-replenishment.functions": `
    export const listReplenishmentFn = ${pending}, getReplenishmentSummaryFn = ${pending},
      listLocationReplenishmentRulesFn = ${pending}, setReplenishmentRuleFn = ${pending},
      setReplenishmentRuleEnabledFn = ${pending};`,
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
  export { ReplenishmentView } from "@/components/inventory/workspace/ReplenishmentTab";
  export { ReplenishmentRowCard } from "@/components/inventory/workspace/ReplenishmentRowCard";
  export { RuleForm } from "@/components/inventory/workspace/ReplenishmentRuleDialog";
  export { ruleDialogTitle } from "@/inventory/replenishment";
  export { LocationReplenishmentRulesView } from "@/components/inventory/workspace/LocationReplenishmentRules";
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
      name: "replenishment-stubs",
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
  ui.render(component, props) as string;
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/&#x27;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ");
const noop = () => {};
const now = new Date("2026-11-13T12:00:00Z");

const row = (overrides: Partial<ReplenishmentRow> = {}): ReplenishmentRow => ({
  ruleId: "r-1",
  inventoryItemId: "i-tape",
  itemName: "Athletic Tape",
  itemUnit: "BX",
  itemActive: true,
  inventoryLocationId: "l-first",
  locationName: "First Team ATR",
  locationActive: true,
  minimumQuantity: 5,
  targetQuantity: 12,
  enabled: true,
  updatedAt: "2026-11-13T12:00:00.123456+00:00",
  category: "partly_covered",
  inactiveReason: null,
  currentQuantity: 3,
  notStockedHere: false,
  shortageQuantity: 9,
  availableQuantity: 8,
  moveQuantity: 8,
  externalQuantity: 1,
  organizationQuantity: 23,
  unassignedQuantity: 8,
  donors: [
    {
      locationId: "l-unassigned",
      name: "Unassigned",
      kind: "unassigned",
      spareQuantity: 8,
      moveQuantity: 8,
    },
  ],
  otherShortLocationCount: 0,
  lastCountedAt: null,
  locationCountState: "never_counted",
  openRequestCount: 0,
  openApprovedRequestCount: 0,
  openOrderedRequestCount: 0,
  ...overrides,
});

const summary = (overrides: Partial<ReplenishmentSummary> = {}): ReplenishmentSummary => ({
  rules: { total: 6, active: 5, inactive: 1, disabled: 1 },
  categories: { moveAvailable: 1, partlyCovered: 1, needsPurchasing: 1, ok: 2, inactive: 1 },
  notStockedHere: 1,
  items: { active: 40, withRule: 4, withoutRule: 36 },
  locations: { activeStorage: 3, withRule: 2, withoutRule: 1 },
  ...overrides,
});

test("wording: the accepted examples, in the item's own unit and never as a pack", () => {
  assert.equal(shortageText(row()), "Short 9 BX");
  assert.equal(recommendationText(row()), "Move 8 from Unassigned · Needs purchasing: 1 BX");
  assert.equal(purchasingText(row()), "Needs purchasing: 1 BX");
  assert.equal(
    moveText(
      row({
        moveQuantity: 9,
        donors: [
          {
            locationId: "u",
            name: "Unassigned",
            kind: "unassigned",
            spareQuantity: 3,
            moveQuantity: 3,
          },
          {
            locationId: "a",
            name: "Academy ATR",
            kind: "storage",
            spareQuantity: 10,
            moveQuantity: 6,
          },
          {
            locationId: "c",
            name: "FCC2 ATR",
            kind: "storage",
            spareQuantity: 10,
            moveQuantity: 0,
          },
        ],
      }),
    ),
    "Move 3 from Unassigned, 6 from Academy ATR",
  );
  assert.equal(
    moveText(
      row({
        moveQuantity: 5,
        donors: [
          {
            locationId: "u",
            name: "Unassigned",
            kind: "unassigned",
            spareQuantity: 2,
            moveQuantity: 2,
          },
        ],
      }),
    ),
    "Move 2 from Unassigned, 3 from other locations",
  );
  assert.equal(
    recommendationText(
      row({ category: "needs_purchasing", moveQuantity: 0, externalQuantity: 6, donors: [] }),
    ),
    "Needs purchasing: 6 BX",
  );
  assert.equal(
    recommendationText(
      row({
        category: "ok",
        shortageQuantity: 0,
        moveQuantity: 0,
        externalQuantity: 0,
        donors: [],
      }),
    ),
    null,
  );
  assert.equal(shortageText(row({ shortageQuantity: 0 })), null);
  assert.equal(
    purchasingText(row({ externalQuantity: 5.5, itemUnit: "L" })),
    "Needs purchasing: 5.5 L",
  );
  for (const value of [row(), row({ externalQuantity: 3 })]) {
    assert.doesNotMatch(recommendationText(value) ?? "", /\b(box|boxes|case|cases|pack|order)\b/i);
  }
  assert.deepEqual(donorContext(row()), ["Unassigned: 8 BX (not physically counted)"]);
  assert.deepEqual(
    donorContext(
      row({
        donors: [
          {
            locationId: "c",
            name: "FCC2 ATR",
            kind: "storage",
            spareQuantity: 15,
            moveQuantity: 9,
          },
        ],
      }),
    ),
    ["FCC2 ATR: 15 BX above its Minimum"],
  );
});

test("wording: open requests, other short locations, counts and cadence are context only", () => {
  assert.equal(openRequestText(row()), null);
  assert.equal(
    openRequestText(row({ openRequestCount: 1, openOrderedRequestCount: 1 })),
    "1 open request (ordered) for this item",
  );
  assert.equal(
    openRequestText(
      row({ openRequestCount: 2, openApprovedRequestCount: 1, openOrderedRequestCount: 1 }),
    ),
    "2 open requests (1 approved, 1 ordered) for this item",
  );
  assert.equal(otherShortText(row()), null);
  assert.equal(
    otherShortText(row({ otherShortLocationCount: 1 })),
    "Also short at 1 other location",
  );
  assert.equal(
    otherShortText(row({ otherShortLocationCount: 2 })),
    "Also short at 2 other locations",
  );
  const now = new Date("2026-11-13T12:00:00Z");
  assert.equal(lastCountedText(row(), now), "Not counted here yet");
  assert.equal(
    lastCountedText(row({ lastCountedAt: "2026-10-02T09:00:00Z" }), now),
    "Counted here 42 days ago",
  );
  assert.equal(
    lastCountedText(row({ lastCountedAt: "2026-11-13T08:00:00Z" }), now),
    "Counted here today",
  );
  assert.equal(countCadenceWarning(row({ locationCountState: "counted" })), null);
  assert.equal(countCadenceWarning(row({ locationCountState: "current" })), null);
  assert.equal(
    countCadenceWarning(row({ locationCountState: "overdue" })),
    "First Team ATR count is overdue",
  );
  assert.equal(
    countCadenceWarning(row({ locationCountState: "due" })),
    "First Team ATR count is due",
  );
  assert.equal(
    coverageText(summary()),
    "5 active rules · 36 items without a rule · 1 location without a rule",
  );
  assert.equal(
    NOT_STOCKED_HERE_TEXT,
    "Not stocked here yet. Move stock in to start counting it here.",
  );
});

test("rule validation mirrors the database: Minimum >= 0, Target > 0, Target >= Minimum", () => {
  assert.equal(validateRuleInput("", "5"), "Enter a Minimum and a Target.");
  assert.equal(validateRuleInput("-1", "5"), "Minimum must be zero or more.");
  assert.equal(validateRuleInput("0", "0"), "Target must be greater than zero.");
  assert.equal(validateRuleInput("6", "5"), "Target must be at least the Minimum.");
  assert.equal(validateRuleInput("1", "abc"), "Enter numbers only.");
  assert.equal(
    validateRuleInput("1", "1.0000001"),
    "Quantities must be at most 1,000,000,000 with up to six decimal places.",
  );
  assert.equal(
    validateRuleInput("1", "1000000001"),
    "Quantities must be at most 1,000,000,000 with up to six decimal places.",
  );
  assert.equal(validateRuleInput("0", "5"), null);
  assert.equal(validateRuleInput("5", "5"), null);
  assert.equal(validateRuleInput("2.5", "7.25"), null);
});

test("Move Stock prefill: one donor per action, kept by the reconcile step, never automatic", () => {
  assert.deepEqual(nextMovePrefill(row()), {
    fromId: "l-unassigned",
    toId: "l-first",
    quantity: 8,
  });
  const multi = row({
    category: "move_available",
    moveQuantity: 9,
    donors: [
      {
        locationId: "u",
        name: "Unassigned",
        kind: "unassigned",
        spareQuantity: 3,
        moveQuantity: 3,
      },
      { locationId: "a", name: "Academy ATR", kind: "storage", spareQuantity: 10, moveQuantity: 6 },
    ],
  });
  assert.deepEqual(
    nextMovePrefill(multi),
    { fromId: "u", toId: "l-first", quantity: 3 },
    "first donor first",
  );
  assert.equal(
    nextMovePrefill(row({ category: "needs_purchasing", moveQuantity: 0, donors: [] })),
    null,
  );
  assert.equal(nextMovePrefill(row({ category: "ok" })), null);
  assert.equal(nextMovePrefill(row({ category: "inactive" })), null);

  const prefill = { fromId: "a", toId: "l-first", quantity: 6 };
  const form = initialMoveForm(["u", "a"], prefill);
  assert.deepEqual(form, { fromId: "a", toId: "l-first", quantity: "6", prefilled: true });
  // The existing reconcile step keeps a prefilled source that still has stock.
  assert.deepEqual(reconcileMoveSource({ fromId: form.fromId, toId: form.toId }, ["u", "a"]), {
    fromId: "a",
    toId: "l-first",
  });
  // A source that has emptied since: the form opens as before, unprefilled.
  assert.deepEqual(initialMoveForm(["u"], prefill), {
    fromId: "u",
    toId: "",
    quantity: "",
    prefilled: false,
  });
  assert.deepEqual(initialMoveForm(["u", "a"]), {
    fromId: "u",
    toId: "",
    quantity: "",
    prefilled: false,
  });
  assert.deepEqual(initialMoveForm([], prefill), {
    fromId: "",
    toId: "",
    quantity: "",
    prefilled: false,
  });

  const dialog = read("src/components/inventory/ItemLocationsDialog.tsx");
  assert.match(dialog, /prefilled: prefillPending/);
  assert.match(
    dialog,
    /setPrefillPending\(false\)/,
    "only the first confirmed move is the recommendation's",
  );
  const stock = read("src/components/inventory/workspace/ItemStockDialogs.tsx");
  assert.match(stock, /source: input\.prefilled \? "replenishment" : "manual"/);
  assert.match(stock, /replenishmentQueryKey\(organizationId\)/, "moves refresh replenishment");
  assert.match(stock, /workspaceQueryKey\(organizationId\)/, "and the workspace");
  // The recommendation only opens the dialog; the owner presses Move stock.
  const tab = read("src/components/inventory/workspace/ReplenishmentTab.tsx");
  assert.doesNotMatch(tab, /moveInventoryStockFn|move_inventory_stock/);
});

test("rows from the database keep the version string exactly (microseconds)", () => {
  const mapped = toReplenishmentRow({
    rule_id: "r",
    inventory_item_id: "i",
    item_name: "Tape",
    item_unit: "roll",
    item_active: true,
    inventory_location_id: "l",
    location_name: "First",
    location_active: true,
    minimum_quantity: 2.5,
    target_quantity: "7.25",
    enabled: true,
    updated_at: "2026-11-13T12:00:00.123456+00:00",
    category: "partly_covered",
    inactive_reason: null,
    current_quantity: 1.5,
    not_stocked_here: false,
    shortage_quantity: 5.75,
    available_quantity: 0.25,
    move_quantity: 0.25,
    external_quantity: 5.5,
    organization_quantity: 1.75,
    unassigned_quantity: 0.25,
    donors: [
      {
        locationId: "u",
        name: "Unassigned",
        kind: "unassigned",
        spareQuantity: 0.25,
        moveQuantity: 0.25,
      },
    ],
    other_short_location_count: 0,
    last_counted_at: null,
    location_count_state: "counted",
    open_request_count: 0,
    open_approved_request_count: 0,
    open_ordered_request_count: 0,
  });
  assert.equal(mapped.updatedAt, "2026-11-13T12:00:00.123456+00:00");
  assert.equal(mapped.targetQuantity, 7.25);
  assert.equal(mapped.donors[0].moveQuantity, 0.25);
});

test("par_level isolation: no 7D source or migration function reads it or says par", () => {
  for (const path of sevenDSources) {
    const source = read(path);
    assert.doesNotMatch(source, /par_level|parLevel/, `${path} reads par_level`);
    assert.doesNotMatch(source, /\bpar\b/i, `${path} says par`);
  }
  // The migration mentions par_level only to prove it unchanged (snapshot and postcheck).
  for (const line of migrationCode.split("\n").filter((entry) => /par_level/.test(entry))) {
    assert.match(
      line,
      /coalesce\(par_level::text, '-'\)|position\('par_level' IN|replenishment must not read par_level|Never reads par_level/,
      line,
    );
  }
  for (const name of [
    "inventory_replenishment_rows",
    "list_inventory_replenishment",
    "get_inventory_replenishment_summary",
    "list_inventory_location_replenishment_rules",
    "set_inventory_replenishment_rule",
    "set_inventory_replenishment_rule_enabled",
    "move_inventory_stock",
  ]) {
    const start = migration.indexOf(`CREATE FUNCTION public.${name}(`);
    assert.ok(start >= 0, name);
    assert.doesNotMatch(
      migration.slice(start, migration.indexOf("\n$$;", start)),
      /par_level/,
      name,
    );
  }
  // Legacy displays and functions are untouched by 7D.
  assert.doesNotMatch(
    migrationCode,
    /inventory_workspace_stock_status|ALTER TABLE public\.inventory_items/,
  );
  assert.match(
    read("src/components/inventory/workspace/LocationStockTable.tsx"),
    /Organization par/,
  );
  assert.match(read("src/inventory/status.ts"), /parLevel \* 0\.5/);
});

test("no silent operational changes: 7D never creates requests, purchases, notifications or alerts", () => {
  for (const path of sevenDSources) {
    const source = read(path);
    assert.doesNotMatch(
      source,
      /submit_supply_request|submitSupplyRequest|supply-requests\.functions|staff-request-cart|\/supply-requests|\/staff\/request|notification|digest|purchase_order/i,
      `${path} reaches into requests, purchasing or notifications`,
    );
    assert.doesNotMatch(
      source,
      /move_inventory_stock|moveInventoryStockFn/,
      `${path} moves stock itself`,
    );
  }
  assert.doesNotMatch(
    migrationCode,
    /INSERT INTO public\.(supply_requests|supply_request_items|notification_events|inventory_adjustments)|CREATE TABLE public\.\w*alert/i,
  );
  assert.doesNotMatch(migrationCode, /notification|digest/i);
});

test("migration: one additive file, RLS and grants, owner-only writes, owner+admin reads", () => {
  const later = readdir("supabase/migrations").filter(
    (name) => name > "20261112140000_phase7c_receiving_destination.sql",
  );
  assert.deepEqual(later, ["20261113120000_phase7d_inventory_replenishment.sql"]);
  assert.match(migration, /^BEGIN;$/m);
  assert.match(migration, /\nCOMMIT;\n$/);
  assert.doesNotMatch(migrationCode, /CREATE\s+TEMP/i);
  assert.match(
    migrationCode,
    /ALTER TABLE public\.inventory_replenishment_rules ENABLE ROW LEVEL SECURITY;/,
  );
  assert.match(
    migrationCode,
    /REVOKE ALL ON public\.inventory_replenishment_rules FROM PUBLIC, anon, authenticated, service_role;\nGRANT SELECT ON public\.inventory_replenishment_rules TO service_role;/,
  );
  assert.doesNotMatch(migrationCode, /CREATE POLICY/);
  assert.match(
    migrationCode,
    /CONSTRAINT inventory_replenishment_rules_item_location_key UNIQUE \(inventory_item_id, inventory_location_id\)/,
  );
  assert.match(migrationCode, /CHECK \(target_quantity >= minimum_quantity\)/);
  assert.match(
    migrationCode,
    /ADD COLUMN source text NOT NULL DEFAULT 'manual'\s+CONSTRAINT inventory_transfers_source_check CHECK \(source IN \('manual', 'replenishment'\)\)/,
  );
  assert.match(
    migrationCode,
    /DROP FUNCTION public\.move_inventory_stock\(uuid, uuid, uuid, uuid, numeric, text\);/,
  );
  assert.match(migrationCode, /_source text DEFAULT 'manual'/);
  for (const name of [
    "set_inventory_replenishment_rule",
    "set_inventory_replenishment_rule_enabled",
  ]) {
    const start = migration.indexOf(`CREATE FUNCTION public.${name}(`);
    assert.match(
      migration.slice(start, migration.indexOf("\n$$;", start)),
      /ARRAY\['owner'\]::public\.org_role\[\]/,
      name,
    );
  }
  for (const name of [
    "list_inventory_replenishment",
    "get_inventory_replenishment_summary",
    "list_inventory_location_replenishment_rules",
  ]) {
    const start = migration.indexOf(`CREATE FUNCTION public.${name}(`);
    assert.match(
      migration.slice(start, migration.indexOf("\n$$;", start)),
      /public\.is_org_admin\(_organization_id, auth\.uid\(\)\)/,
      name,
    );
  }
  assert.match(
    migrationCode,
    /REVOKE ALL ON FUNCTION public\.inventory_replenishment_rows\(uuid\) FROM PUBLIC, anon, authenticated;/,
  );
  // Stale screens never raise 40001 (PostgREST retries it).
  assert.doesNotMatch(migrationCode, /40001/);
  assert.match(
    migrationCode,
    /changed since you opened it\. Reload and try again\.' USING ERRCODE = '55000'/,
  );
});

test("server functions: owner checks on writes, source passed to Move Stock, staff blocked by the route", () => {
  const fns = read("src/lib/inventory-replenishment.functions.ts");
  for (const name of ["setReplenishmentRuleFn", "setReplenishmentRuleEnabledFn"]) {
    const start = fns.indexOf(`export const ${name}`);
    const end = fns.indexOf("export const", start + 10);
    assert.match(fns.slice(start, end < 0 ? undefined : end), /await assertInventoryOwner\(/, name);
  }
  const inventory = read("src/lib/inventory.functions.ts");
  assert.match(inventory, /source: z\.enum\(\["manual", "replenishment"\]\)\.default\("manual"\)/);
  assert.match(inventory, /_source: data\.source,/);
  const gate = read("src/routes/_authenticated/route.tsx");
  assert.match(gate, /const ADMIN_ROUTES = \[[^\]]*"\/inventory"/);
  assert.doesNotMatch(gate.match(/const STAFF_ROUTES = \[[^\]]*\]/)?.[0] ?? "", /inventory/);
  assert.match(read("src/routes/_authenticated/inventory.index.tsx"), /"replenishment"/);
  assert.match(
    read("src/components/inventory/workspace/InventoryWorkspacePage.tsx"),
    /<ReplenishmentTab organizationId=\{active\.organizationId\} canManage=\{access\.canManage\} \/>/,
  );
  const types = read("src/integrations/supabase/types.ts");
  assert.match(types, /set_inventory_replenishment_rule: \{/);
  assert.match(types, /_source\?: string/);
});

function readdir(path: string) {
  return readdirSync(join(root, path)).sort();
}

const rows: ReplenishmentRow[] = [
  row({
    ruleId: "move",
    category: "move_available",
    itemName: "Gauze",
    moveQuantity: 9,
    externalQuantity: 0,
    donors: [
      {
        locationId: "u",
        name: "Unassigned",
        kind: "unassigned",
        spareQuantity: 20,
        moveQuantity: 9,
      },
    ],
    otherShortLocationCount: 1,
    openRequestCount: 1,
    openOrderedRequestCount: 1,
    lastCountedAt: "2026-10-02T09:00:00Z",
    locationCountState: "overdue",
  }),
  row({ ruleId: "partly" }),
  row({
    ruleId: "buy",
    category: "needs_purchasing",
    itemName: "Pads",
    itemUnit: "each",
    notStockedHere: true,
    currentQuantity: 0,
    shortageQuantity: 6,
    moveQuantity: 0,
    externalQuantity: 6,
    donors: [],
  }),
];
const viewProps = (overrides: Record<string, unknown> = {}) => ({
  summary: summary(),
  canManage: true,
  attention: rows,
  ok: [],
  okOpen: false,
  onToggleOk: noop,
  inactive: [],
  inactiveOpen: false,
  onToggleInactive: noop,
  now,
  onMove: noop,
  onEdit: noop,
  onToggleEnabled: noop,
  ...overrides,
});

test("Replenishment (owner): coverage, the three attention groups in order, full row context", () => {
  const html = render(ui.ReplenishmentView, viewProps());
  const words = text(html);
  assert.match(words, /5 active rules · 36 items without a rule · 1 location without a rule/);
  assert.match(words, /Needs attention \(3\)/);
  const order = ["move_available", "partly_covered", "needs_purchasing"].map((group) =>
    html.indexOf(`data-group="${group}"`),
  );
  assert.ok(
    order.every((index, i) => index >= 0 && (i === 0 || index > order[i - 1])),
    "group order",
  );
  assert.match(words, /Move available \(1\).*Partly covered \(1\).*Needs purchasing \(1\)/);
  // Row fields.
  assert.match(
    words,
    /Gauze First Team ATR Move available Current 3 BX Minimum 5 Target 12 Short 9 BX/,
  );
  assert.match(words, /Move 9 from Unassigned/);
  assert.match(words, /Unassigned: 20 BX \(not physically counted\)/);
  assert.match(words, /Counted here 42 days ago/);
  assert.match(words, /First Team ATR count is overdue/);
  assert.match(words, /1 open request \(ordered\) for this item/);
  assert.match(words, /Also short at 1 other location/);
  assert.match(words, /Move 8 from Unassigned · Needs purchasing: 1 BX/);
  assert.match(words, /Needs purchasing: 6 each/);
  assert.match(words, /Not stocked here yet\. Move stock in to start counting it here\./);
  assert.match(words, /Not counted here yet/);
  // Owner actions: Move stock only where a move is available, never on a purchasing-only row.
  assert.equal((html.match(/>Move stock</g) ?? []).length, 2);
  assert.equal((html.match(/>Edit</g) ?? []).length, 3);
  assert.equal((html.match(/>Turn off</g) ?? []).length, 3);
  // Collapsed groups.
  assert.match(html, /data-testid="replenishment-ok" data-open="false"/);
  assert.match(html, /data-testid="replenishment-inactive" data-open="false"/);
  assert.match(words, /OK \(2\)/);
  assert.match(words, /Inactive rules \(1\)/);
  assert.doesNotMatch(words, /\b(box|boxes|case|pack|order \d)\b/i, "no package conversion");
  assert.doesNotMatch(words, /\bpar\b/i);
  assert.doesNotMatch(html, /<table/, "cards, not a dense table");
});

test("Replenishment (admin): read-only, no actions, same information", () => {
  const html = render(
    ui.ReplenishmentView,
    viewProps({
      canManage: false,
      onMove: undefined,
      onEdit: undefined,
      onToggleEnabled: undefined,
    }),
  );
  const words = text(html);
  assert.match(words, /Read-only/i);
  assert.match(words, /Only owners can change rules or move stock\./);
  assert.match(words, /Move 9 from Unassigned/, "the recommendation is still shown");
  assert.doesNotMatch(html, />Move stock<|>Edit<|>Turn off<|>Turn on</);
});

test("Replenishment: empty state, all-OK state and expanded inactive rules", () => {
  const empty = text(
    render(
      ui.ReplenishmentView,
      viewProps({
        summary: summary({
          rules: { total: 0, active: 0, inactive: 0, disabled: 0 },
          categories: {
            moveAvailable: 0,
            partlyCovered: 0,
            needsPurchasing: 0,
            ok: 0,
            inactive: 0,
          },
          items: { active: 35, withRule: 0, withoutRule: 35 },
          locations: { activeStorage: 3, withRule: 0, withoutRule: 3 },
        }),
        attention: [],
      }),
    ),
  );
  assert.match(
    empty,
    /No replenishment rules yet\. Set a Minimum and Target on a storage location's Stock tab\./,
  );
  assert.match(empty, /0 active rules · 35 items without a rule · 3 locations without a rule/);
  assert.doesNotMatch(empty, /Needs attention|OK \(|Inactive rules/);

  const calm = text(
    render(
      ui.ReplenishmentView,
      viewProps({
        summary: summary({
          categories: {
            moveAvailable: 0,
            partlyCovered: 0,
            needsPurchasing: 0,
            ok: 4,
            inactive: 0,
          },
        }),
        attention: [],
      }),
    ),
  );
  assert.match(calm, /Needs attention \(0\) Every active rule is above its Minimum\./);

  const inactiveHtml = render(
    ui.ReplenishmentView,
    viewProps({
      inactiveOpen: true,
      okOpen: true,
      ok: [
        row({
          ruleId: "ok",
          category: "ok",
          shortageQuantity: 0,
          moveQuantity: 0,
          externalQuantity: 0,
          donors: [],
          currentQuantity: 9,
        }),
      ],
      inactive: [
        row({
          ruleId: "off",
          category: "inactive",
          inactiveReason: "disabled",
          enabled: false,
          shortageQuantity: 0,
          moveQuantity: 0,
          externalQuantity: 0,
          donors: [],
        }),
        row({
          ruleId: "gone",
          category: "inactive",
          inactiveReason: "item_archived",
          itemActive: false,
          shortageQuantity: 0,
          moveQuantity: 0,
          externalQuantity: 0,
          donors: [],
        }),
        row({
          ruleId: "room",
          category: "inactive",
          inactiveReason: "location_archived",
          locationActive: false,
          enabled: false,
          shortageQuantity: 0,
          moveQuantity: 0,
          externalQuantity: 0,
          donors: [],
        }),
      ],
    }),
  );
  const words = text(inactiveHtml);
  assert.match(inactiveHtml, /data-testid="replenishment-inactive" data-open="true"/);
  assert.match(words, /Turned off/);
  assert.match(words, /Item archived/);
  assert.match(words, /Location archived/);
  assert.match(words, /OK Current 9 BX/);
  // A disabled rule with active item and location can be turned on; an archived item's rule
  // can only be turned off; an archived location's disabled rule offers nothing.
  assert.equal((inactiveHtml.match(/>Turn on</g) ?? []).length, 1);
});

test("rule form and location rules: Minimum and Target wording, create picker, read-only admin", () => {
  const create = text(
    render(ui.RuleForm, {
      state: {
        mode: "create",
        locationId: "l-first",
        locationName: "First Team ATR",
        items: [{ id: "i", name: "Athletic Tape", unit: "BX" }],
      },
      onSubmit: async () => {},
    }),
  );
  assert.equal(
    ui.ruleDialogTitle({
      mode: "create",
      locationId: "l",
      locationName: "First Team ATR",
      items: [],
    }),
    "Set Minimum and Target",
  );
  assert.match(create, /Athletic Tape \(BX\)/);
  assert.match(create, /The item does not need stock here yet\./);
  assert.match(
    create,
    /Minimum can be 0\. Target must be greater than 0 and at least the Minimum\./,
  );
  const edit = render(ui.RuleForm, {
    state: {
      mode: "edit",
      locationId: "l-first",
      locationName: "First Team ATR",
      item: { id: "i", name: "Athletic Tape", unit: "BX" },
      minimum: 2.5,
      target: 7.25,
      updatedAt: "2026-11-13T12:00:00.123456+00:00",
    },
    onSubmit: async () => {},
  });
  assert.equal(
    ui.ruleDialogTitle({
      mode: "edit",
      locationId: "l",
      locationName: "First Team ATR",
      item: { id: "i", name: "Athletic Tape", unit: "BX" },
      minimum: 1,
      target: 2,
      updatedAt: "x",
    }),
    "Athletic Tape at First Team ATR",
  );
  assert.match(edit, /value="2\.5"/);
  assert.match(edit, /value="7\.25"/);
  assert.match(text(edit), /Minimum \(BX\).*Target \(BX\)/);
  assert.doesNotMatch(text(edit) + create, /\bpar\b/i);

  const location = { id: "l-first", name: "First Team ATR", kind: "storage", active: true };
  const owner = render(ui.LocationReplenishmentRulesView, {
    location,
    rows: [row()],
    canManage: true,
    onAdd: noop,
    onEdit: noop,
    onToggleEnabled: noop,
    now,
  });
  assert.match(text(owner), /Minimum and Target here/);
  assert.match(owner, />Set Minimum \/ Target</);
  assert.match(owner, />Edit</);
  assert.doesNotMatch(
    owner,
    />Move stock</,
    "the location panel manages rules; moves stay in Replenishment and Stock",
  );
  const admin = render(ui.LocationReplenishmentRulesView, {
    location,
    rows: [row()],
    canManage: false,
    now,
  });
  assert.doesNotMatch(admin, />Set Minimum \/ Target<|>Edit<|>Turn off</);
  const none = text(
    render(ui.LocationReplenishmentRulesView, { location, rows: [], canManage: true, onAdd: noop }),
  );
  assert.match(none, /No item has a Minimum and Target at First Team ATR yet\./);
});

test("phone width: cards wrap long names and nothing has a fixed width", () => {
  const long = row({
    itemName: "Extra Long Self-Adherent Cohesive Bandage Wrap With Very Long Vendor Description",
    locationName: "First Team Athletic Training Room — Main Building",
  });
  const html = render(ui.ReplenishmentRowCard, {
    row: long,
    canManage: true,
    now,
    onMove: noop,
    onEdit: noop,
    onToggleEnabled: noop,
  });
  assert.match(html, /break-words/);
  assert.match(html, /flex-wrap/);
  const content = html.replace(/<button[^>]*>/g, "<button>");
  assert.doesNotMatch(content, /\bw-\[\d|min-w-\[\d|whitespace-nowrap/);
  // The workspace's six tabs scroll inside their own strip on a phone.
  assert.match(
    read("src/components/inventory/workspace/InventoryWorkspacePage.tsx"),
    /data-testid="inventory-tabs-scroller"/,
  );
});

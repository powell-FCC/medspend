// Phase 7A.1: location-aware inventory foundation. Pure location helpers, structural checks
// of the migration, release scripts and server functions, and rendered owner UI states.
// Database behavior is covered by supabase/tests/phase7a1_location_aware_inventory_behavior.sql,
// phase7a1_backfill_check.sh (migration, release scripts, deletion parity) and
// phase7a1_race_check.sh (two-session concurrency).
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  canArchiveInventoryLocation,
  formatQuantity,
  itemLocationBreakdown,
  physicalLocationCount,
  sortInventoryLocations,
  summarizeInventoryLocations,
  validateLocationAdjustment,
  validateMove,
} from "../src/inventory/locations.ts";
import type { InventoryLocation, InventoryLocationBalance } from "../src/types/inventory.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const between = (source: string, start: string, end: string) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end}`);
  return source.slice(from, to);
};

const migration = read("supabase/migrations/20261021120000_phase7a1_location_aware_inventory.sql");
const migrationCode = migration.replace(/--.*$/gm, "");
const postingMain = read(
  "supabase/migrations/20261012120000_beta_invoice_manual_catalog_matching.sql",
);
const deletionMain = read("supabase/migrations/20260817120000_phase3a6_safe_invoice_deletion.sql");
const server = read("src/lib/inventory.functions.ts");
const page = read("src/components/inventory/InventoryPage.tsx");
const itemDialog = read("src/components/inventory/InventoryItemDialog.tsx");
const settings = read("src/routes/_authenticated/settings.tsx");
const types = read("src/integrations/supabase/types.ts");
const behavior = read("supabase/tests/phase7a1_location_aware_inventory_behavior.sql");
const precheck = read("supabase/release/phase7a1/precheck.sql");
const postcheck = read("supabase/release/phase7a1/postcheck.sql");

const location = (
  id: string,
  name: string,
  kind: "unassigned" | "storage" = "storage",
  active = true,
): InventoryLocation => ({
  id,
  organizationId: "org",
  name,
  description: null,
  kind,
  active,
  createdAt: "",
  updatedAt: "",
});
const balance = (item: string, loc: string, quantity: number): InventoryLocationBalance => ({
  inventoryItemId: item,
  inventoryLocationId: loc,
  quantity,
  version: 1,
  updatedAt: "",
});
const unassigned = location("u", "Unassigned", "unassigned");
const cabinet = location("c", "Training Room Cabinet A");
const cart = location("a", "Away Medical Cart");
const archived = location("z", "Old Bin", "storage", false);
const locations = [cart, archived, cabinet, unassigned];
const balances = [
  balance("tape", "u", 20),
  balance("tape", "c", 60),
  balance("tape", "a", 20),
  balance("gauze", "u", 2.75),
  balance("empty", "u", 0),
];

// Bundle the owner UI before any test is registered, so cleanup cannot race the build.
const cacheDir = join(root, "node_modules/.cache/phase7a1-inventory-test");
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
    export const DropdownMenuItem = ({ children, onClick }) => createElement("button", { onClick }, children);`,
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
  export { InventoryLocationsPanel } from "@/components/inventory/InventoryLocationsPanel";
  export { ItemLocationsDialog } from "@/components/inventory/ItemLocationsDialog";
  export { QuantityAdjustmentDialog } from "@/components/inventory/QuantityAdjustmentDialog";
  export { InventoryTable } from "@/components/inventory/InventoryTable";
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
      name: "inventory-stubs",
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
const noop = async () => {};
const tape = {
  id: "tape",
  organizationId: "org",
  name: "Athletic Tape",
  description: null,
  sku: "T-1",
  vendorName: null,
  category: null,
  manufacturer: null,
  quantity: 100,
  unit: "roll",
  parLevel: null,
  active: true,
  createdAt: "",
  updatedAt: "",
};
const gauze = { ...tape, id: "gauze", name: "Gauze", quantity: 2.75, unit: "box" };

// ---------------------------------------------------------------------------------------
// Pure helpers.
// ---------------------------------------------------------------------------------------
test("locations sort Unassigned first, then active by name, archived last", () => {
  assert.deepEqual(
    sortInventoryLocations(locations).map((l) => l.name),
    ["Unassigned", "Away Medical Cart", "Training Room Cabinet A", "Old Bin"],
  );
});

test("the same item can sit in several locations, and Unassigned always shows", () => {
  assert.deepEqual(
    itemLocationBreakdown("tape", locations, balances).map((e) => [e.location.name, e.quantity]),
    [
      ["Unassigned", 20],
      ["Away Medical Cart", 20],
      ["Training Room Cabinet A", 60],
    ],
  );
  assert.equal(physicalLocationCount("tape", locations, balances), 2);
  assert.deepEqual(
    itemLocationBreakdown("empty", locations, balances).map((e) => [e.location.name, e.quantity]),
    [["Unassigned", 0]],
  );
  assert.equal(physicalLocationCount("gauze", locations, balances), 0);
  const total = itemLocationBreakdown("tape", locations, balances).reduce(
    (sum, e) => sum + e.quantity,
    0,
  );
  assert.equal(total, 100, "breakdown sums to the organization total");
});

test("location summaries count stocked items only", () => {
  const summary = Object.fromEntries(
    summarizeInventoryLocations(locations, balances).map((s) => [
      s.name,
      [s.itemCount, s.hasStock],
    ]),
  );
  assert.deepEqual(summary, {
    Unassigned: [2, true],
    "Away Medical Cart": [1, true],
    "Training Room Cabinet A": [1, true],
    "Old Bin": [0, false],
  });
});

test("archive rules protect Unassigned and never strand stock", () => {
  assert.equal(canArchiveInventoryLocation(unassigned, balances).allowed, false);
  assert.match(
    canArchiveInventoryLocation(cabinet, balances).reason ?? "",
    /Move all stock out of Training Room Cabinet A/,
  );
  assert.equal(canArchiveInventoryLocation(location("e", "Empty Bin"), balances).allowed, true);
  assert.equal(canArchiveInventoryLocation(archived, balances).allowed, false);
});

test("move and adjustment pre-checks mirror the database rules", () => {
  assert.equal(validateMove({ fromId: "u", toId: "c", quantity: 20, available: 20 }), null);
  assert.equal(validateMove({ fromId: "u", toId: "c", quantity: 0.125, available: 20 }), null);
  assert.match(
    validateMove({ fromId: "u", toId: "c", quantity: 20.5, available: 20 }) ?? "",
    /Only 20 available/,
  );
  assert.match(
    validateMove({ fromId: "u", toId: "u", quantity: 1, available: 20 }) ?? "",
    /two different/,
  );
  assert.match(
    validateMove({ fromId: "u", toId: "c", quantity: 0, available: 20 }) ?? "",
    /greater than zero/,
  );
  assert.match(
    validateMove({ fromId: "u", toId: "c", quantity: -2, available: 20 }) ?? "",
    /greater than zero/,
  );
  assert.match(
    validateMove({ fromId: "", toId: "c", quantity: 1, available: 20 }) ?? "",
    /Choose where/,
  );
  assert.equal(validateLocationAdjustment({ amount: -2.75, available: 2.75 }), null);
  assert.match(validateLocationAdjustment({ amount: -3, available: 2.75 }) ?? "", /only 2.75/);
  assert.match(validateLocationAdjustment({ amount: 0, available: 1 }) ?? "", /non-zero/);
});

test("fractional quantities display exactly, without float noise", () => {
  assert.equal(formatQuantity(2.75), "2.75");
  assert.equal(formatQuantity(0.1 + 0.2), "0.3");
  assert.equal(formatQuantity(12.333333), "12.333333");
  assert.equal(formatQuantity(120), "120");
  assert.equal(formatQuantity(0), "0");
});

// ---------------------------------------------------------------------------------------
// Migration structure.
// ---------------------------------------------------------------------------------------
test("the migration is one transaction with a preflight and an in-migration postcheck", () => {
  assert.match(migration, /^BEGIN;$/m);
  assert.match(migration, /^COMMIT;\s*$/m);
  assert.match(
    migration,
    /LOCK TABLE public\.inventory_items, public\.inventory_adjustments IN SHARE ROW EXCLUSIVE MODE/,
  );
  assert.match(migration, /\$preflight\$/);
  assert.match(migration, /Phase 7A\.1 postcheck: % inventory items changed quantity/);
  assert.match(migration, /Phase 7A\.1 postcheck: % items do not equal their location balances/);
  assert.match(migration, /the migration must not write inventory history/);
});

test("inventory locations are a new concept, separate from public.locations", () => {
  assert.match(migrationCode, /CREATE TABLE public\.inventory_locations/);
  assert.doesNotMatch(
    migrationCode,
    /ALTER TABLE public\.locations|INSERT INTO public\.locations|UPDATE public\.locations/,
  );
  assert.doesNotMatch(migrationCode, /ADD COLUMN inventory_location_id[^;]*inventory_items/);
  assert.doesNotMatch(migrationCode, /ALTER TABLE public\.inventory_items ADD/);
  assert.match(
    migrationCode,
    /CREATE UNIQUE INDEX inventory_locations_org_unassigned_uq ON public\.inventory_locations \(organization_id\)\s+WHERE kind = 'unassigned'/,
  );
  assert.match(
    migrationCode,
    /CREATE TRIGGER organizations_seed_inventory_unassigned AFTER INSERT ON public\.organizations/,
  );
  assert.doesNotMatch(
    settings,
    /inventory_location|InventoryLocation/,
    "cabinets never appear in Settings > Locations",
  );
});

test("balances are canonical: the backfill copies every quantity into Unassigned and invents nothing", () => {
  const backfill = between(migration, "DO $backfill$", "$backfill$;");
  assert.match(
    backfill,
    /INSERT INTO public\.inventory_location_balances[\s\S]*SELECT item\.organization_id, item\.id, location\.id, item\.quantity[\s\S]*location\.kind = 'unassigned'/,
  );
  assert.doesNotMatch(backfill, /inventory_adjustments|inventory_transfers|kind = 'storage'/);
  assert.match(
    migrationCode,
    /quantity numeric NOT NULL DEFAULT 0 CHECK \(quantity >= 0\)/,
    "fractional numeric quantities, never negative",
  );
  assert.doesNotMatch(migrationCode, /::integer|ALTER COLUMN quantity TYPE/);
});

test("only the primitive may change quantities; drift fails at commit", () => {
  assert.match(
    migrationCode,
    /CREATE TRIGGER inventory_items_guard_quantity BEFORE INSERT OR UPDATE ON public\.inventory_items/,
  );
  assert.match(
    migrationCode,
    /CREATE TRIGGER inventory_location_balances_guard BEFORE INSERT OR UPDATE ON public\.inventory_location_balances/,
  );
  assert.match(
    migrationCode,
    /CREATE CONSTRAINT TRIGGER inventory_items_balance_invariant[\s\S]*DEFERRABLE INITIALLY DEFERRED/,
  );
  assert.match(
    migrationCode,
    /CREATE CONSTRAINT TRIGGER inventory_location_balances_invariant[\s\S]*DEFERRABLE INITIALLY DEFERRED/,
  );
  const primitive = between(
    migration,
    "CREATE FUNCTION public.inventory_apply_balance_delta",
    "$$;",
  );
  assert.match(
    primitive,
    /FROM public\.inventory_items\s+WHERE id = _inventory_item_id AND organization_id = _organization_id\s+FOR UPDATE/,
    "locks the item first",
  );
  assert.match(
    primitive,
    /UPDATE public\.inventory_location_balances\s+SET quantity = quantity \+ _delta/,
  );
  assert.match(primitive, /UPDATE public\.inventory_items SET quantity = quantity \+ _delta/);
  // Every quantity write in the migration happens inside the primitive (or the seeding trigger and backfill).
  const writes =
    migrationCode.match(
      /UPDATE public\.inventory_items SET quantity|SET quantity = quantity \+/g,
    ) ?? [];
  assert.equal(writes.length, 2, "exactly the two primitive writes");
  for (const fn of [
    "ensure_inventory_unassigned_location(uuid)",
    "inventory_apply_balance_delta(uuid, uuid, uuid, numeric)",
    "apply_inventory_location_delta(uuid, uuid, uuid, numeric, text, text, uuid, uuid, text)",
  ]) {
    assert.match(
      migrationCode,
      new RegExp(
        `REVOKE ALL ON FUNCTION public\\.${fn.replace(/[()]/g, "\\$&")}\\s+FROM PUBLIC, anon, authenticated;`,
      ),
      `${fn} not client-executable`,
    );
  }
  assert.match(
    migrationCode,
    /REVOKE ALL ON public\.inventory_locations, public\.inventory_location_balances, public\.inventory_transfers\s+FROM PUBLIC, anon, authenticated, service_role;/,
  );
  assert.match(
    migrationCode,
    /GRANT SELECT ON public\.inventory_locations, public\.inventory_location_balances, public\.inventory_transfers\s+TO authenticated;/,
  );
  assert.match(
    migrationCode,
    /REVOKE INSERT ON public\.inventory_adjustments FROM anon, authenticated;/,
  );
});

test("the deployed four-argument adjust_inventory_quantity stays callable and adjusts Unassigned", () => {
  const compat = between(
    migration,
    "CREATE OR REPLACE FUNCTION public.adjust_inventory_quantity(",
    "$$;",
  );
  assert.match(
    compat,
    /_organization_id uuid,\s+_inventory_item_id uuid,\s+_adjustment_amount numeric,\s+_reason text\s+\)\s+RETURNS numeric/,
  );
  assert.match(compat, /has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]/);
  assert.match(
    compat,
    /apply_inventory_location_delta\(\s+_organization_id, _inventory_item_id, NULL,/,
    "NULL location means Unassigned",
  );
  assert.doesNotMatch(migrationCode, /DROP FUNCTION public\.adjust_inventory_quantity/);
  assert.match(
    migrationCode,
    /GRANT EXECUTE ON FUNCTION public\.adjust_inventory_quantity\(uuid, uuid, numeric, text\) TO authenticated;/,
  );
  assert.match(postcheck, /adjust_inventory_quantity signature changed/);
  const located = between(
    migration,
    "CREATE FUNCTION public.adjust_inventory_location_quantity(",
    "$$;",
  );
  assert.match(located, /Choose an inventory location/);
  assert.doesNotMatch(located, /'Invoice received'/);
});

test("the legacy receive helper is owner-only and closed to PUBLIC/anon", () => {
  const legacy = between(
    migration,
    "CREATE OR REPLACE FUNCTION public.receive_invoice_inventory_item(",
    "$$;",
  );
  assert.match(
    legacy,
    /auth\.uid\(\) IS NULL OR NOT public\.has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]/,
  );
  assert.match(
    legacy,
    /apply_inventory_location_delta\(_organization_id, _item\.id, NULL, _quantity, 'Invoice received', NULL\)/,
  );
  assert.doesNotMatch(
    legacy,
    /UPDATE public\.inventory_items|INSERT INTO public\.inventory_adjustments/,
  );
  assert.match(
    migrationCode,
    /REVOKE ALL ON FUNCTION public\.receive_invoice_inventory_item\(uuid, text, text, text, numeric, text, text, numeric\) FROM PUBLIC, anon;/,
  );
});

test("post_reviewed_invoice keeps main's body and changes only the inventory statements", () => {
  const before = between(
    postingMain,
    "CREATE OR REPLACE FUNCTION public.post_reviewed_invoice(",
    "\n$$;",
  );
  const after = between(
    migration,
    "CREATE OR REPLACE FUNCTION public.post_reviewed_invoice(",
    "\n$function$;",
  );
  const normalise = (sql: string) => sql.replace(/--.*$/gm, "").replace(/\s+/g, " ").trim();
  const strip = (sql: string) =>
    normalise(sql)
      .replace(/_previous numeric; _new numeric; /, "")
      .replace(/_previous := _inventory\.quantity; _new := _previous \+ _line\.quantity; /, "")
      .replace(/quantity = _new, /, "")
      .replace(
        /INSERT INTO public\.inventory_adjustments .*?'invoice-item:' \|\| _line\.id::text\); /,
        "",
      )
      .replace(
        /PERFORM public\.apply_inventory_location_delta\( .*?'invoice-item:' \|\| _line\.id::text\); /,
        "",
      );
  const body = (sql: string) => strip(sql).slice(strip(sql).indexOf("DECLARE"));
  assert.equal(
    body(after).replace(/\$function\$/g, "$$"),
    body(before).replace(/\$\$/g, "$$"),
    "only the receipt statements differ",
  );
  assert.match(
    after,
    /PERFORM public\.apply_inventory_location_delta\(\s+_organization_id, _inventory\.id, NULL, _line\.quantity, 'Invoice received', 'invoice',\s+_invoice\.id, _line\.id, 'invoice-item:' \|\| _line\.id::text\);/,
  );
  assert.match(after, /INSERT INTO public\.inventory_price_history/, "price history untouched");
});

test("delete_invoice_permanently gains the Unassigned and count-checkpoint guards and nothing else", () => {
  const after = between(
    migration,
    "CREATE OR REPLACE FUNCTION public.delete_invoice_permanently(",
    "\n$function$;",
  );
  assert.match(after, /source_type = 'physical_count'/);
  assert.match(after, /was physically counted after it was received/);
  assert.match(after, /Move % % of % back to Unassigned before deleting this invoice\./);
  assert.match(
    after,
    /inventory_apply_balance_delta\(\s+_organization_id, _inventory\.id, _unassigned_location_id, -_receipt_quantity\)/,
  );
  assert.doesNotMatch(after, /UPDATE public\.inventory_items\s+SET quantity/);
  // Every guard and message from main survives.
  for (const message of [
    "Forbidden: owner access required",
    "inventory provenance is incomplete",
    "would make % inventory negative",
    "would begin below zero",
    "would become negative",
    "could not reconstruct inventory history safely",
    "DELETE FROM public.inventory_adjustments",
    "DELETE FROM public.inventory_price_history",
    "DELETE FROM public.invoices",
  ]) {
    assert.ok(deletionMain.includes(message) && after.includes(message), message);
  }
});

test("delete_invoice_permanently is authenticated-only after the migration", () => {
  assert.match(
    migrationCode,
    /REVOKE ALL ON FUNCTION public\.delete_invoice_permanently\(uuid, uuid\) FROM PUBLIC, anon;\s+GRANT EXECUTE ON FUNCTION public\.delete_invoice_permanently\(uuid, uuid\) TO authenticated;/,
  );
  for (const marker of [
    "authenticated retains EXECUTE on delete_invoice_permanently",
    "anon cannot EXECUTE delete_invoice_permanently",
    "PUBLIC cannot EXECUTE delete_invoice_permanently",
    "permission denied for function delete_invoice_permanently",
    "refused deletions changed nothing",
  ]) {
    assert.ok(behavior.includes(marker), marker);
  }
});

test("moves are idempotent, owner-only and lock deterministically", () => {
  const move = between(migration, "CREATE FUNCTION public.move_inventory_stock(", "$$;");
  assert.match(move, /ARRAY\['owner'\]/);
  assert.match(move, /already used for a different move/);
  assert.match(move, /'replayed', true/);
  assert.match(move, /ORDER BY id FOR SHARE/);
  assert.match(move, /ORDER BY inventory_location_id FOR UPDATE/);
  assert.ok(
    move.indexOf("FROM public.inventory_items") < move.indexOf("FROM public.inventory_transfers"),
    "item lock precedes the idempotency lookup",
  );
  assert.match(
    migrationCode,
    /CREATE UNIQUE INDEX inventory_transfers_idempotency_uq\s+ON public\.inventory_transfers \(organization_id, idempotency_key\)/,
  );
  assert.doesNotMatch(move, /inventory_adjustments/, "moves write no total-changing history");
});

test("release scripts and SQL suites cover the reviewed boundaries", () => {
  // Supabase SQL Editor safe: no psql meta-commands, no transaction control, and each file
  // ends with the exact fingerprint statement so its result grid is the diffable output.
  const fingerprint = read("supabase/release/phase7a1/fingerprint.sql");
  const statement = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM ("));
  for (const [name, script] of [
    ["precheck", precheck],
    ["postcheck", postcheck],
    ["fingerprint", fingerprint],
  ]) {
    const code = script.replace(/--.*$/gm, "");
    assert.doesNotMatch(code, /^\s*\\/m, `${name} uses a psql meta-command`);
    assert.doesNotMatch(
      code.replace(/DO \$(\w+)\$[\s\S]*?\$\1\$;/g, ""),
      /^\s*(BEGIN|COMMIT|ROLLBACK|START TRANSACTION)\b/im,
      `${name} controls transactions`,
    );
    assert.doesNotMatch(
      code,
      /\b(INSERT INTO|UPDATE public\.|DELETE FROM|CREATE |ALTER |DROP )/i,
      `${name} writes`,
    );
    assert.ok(script.endsWith(statement), `${name} ends with the fingerprint statement`);
  }
  assert.doesNotMatch(postcheck, /HASH_/);
  assert.match(postcheck, /delete_invoice_permanently grants are not authenticated-only/);
  assert.match(fingerprint, / public=/);
  assert.match(precheck, /precheck: Phase 7A\.1 tables already exist/);
  for (const marker of [
    "Unassigned holds 20",
    "receipt of 25 lands in Unassigned",
    "Move 3 roll of Phase 7A.1 Athletic Tape back to Unassigned",
    "was physically counted after it was received",
    "four-argument call returns the new organization total",
    "anon cannot execute legacy receive",
    "Inventory location balances can only change",
    "earlier write in the failed unit was rolled back",
    "SET CONSTRAINTS ALL IMMEDIATE;",
  ]) {
    assert.ok(behavior.includes(marker), marker);
  }
});

// ---------------------------------------------------------------------------------------
// Server functions and types.
// ---------------------------------------------------------------------------------------
test("the 7A.1 app calls only location-aware RPCs, and item edits never change quantity", () => {
  assert.doesNotMatch(server, /rpc\(\s*"adjust_inventory_quantity"/);
  assert.match(server, /rpc\(\s*"adjust_inventory_location_quantity"/);
  assert.match(server, /rpc\(\s*"move_inventory_stock"/);
  const save = between(
    server,
    "export const saveInventoryItemFn",
    "export const adjustInventoryQuantityFn",
  );
  const edit = between(save, "if (data.id) {", "return { id: data.id };");
  assert.doesNotMatch(edit, /quantity/);
  assert.doesNotMatch(server, /\.update\(\{[^}]*quantity/);
  assert.match(server, /inventoryLocationId: uuid/);
  assert.match(itemDialog, /readOnly/);
  assert.match(types, /inventory_location_balances: \{/);
  assert.match(types, /move_inventory_stock: \{/);
  assert.match(page, /InventoryLocationsPanel/);
  assert.match(page, /ItemLocationsDialog/);
  assert.doesNotMatch(page + server, /qr|scanner|physical count/i);
});

// ---------------------------------------------------------------------------------------
// Rendered owner UI.
// ---------------------------------------------------------------------------------------
test("locations panel shows Unassigned as protected and blocks archiving stocked locations", () => {
  const html = render(ui.InventoryLocationsPanel, {
    locations,
    balances,
    onCreate: noop,
    onRename: noop,
    onSetActive: noop,
  });
  assert.ok(
    html.indexOf("Unassigned") < html.indexOf("Away Medical Cart"),
    "Unassigned listed first",
  );
  assert.match(html, /System/);
  assert.match(html, /Protected/);
  assert.doesNotMatch(html, /aria-label="Rename Unassigned"|aria-label="Archive Unassigned"/);
  assert.match(
    html,
    /<button[^>]*disabled=""[^>]*aria-label="Archive Training Room Cabinet A"|<button[^>]*aria-label="Archive Training Room Cabinet A"[^>]*disabled=""/,
  );
  assert.match(html, /aria-label="Restore Old Bin"/);
  assert.match(html, /Archived/);
  assert.match(html, /Empty/);
});

test("item locations dialog lists every location holding the item and the move form", () => {
  const html = render(ui.ItemLocationsDialog, {
    item: tape,
    locations,
    balances,
    onOpenChange: () => {},
    onMove: noop,
  });
  assert.match(html, /Total on hand: <span[^>]*>100 roll<\/span>/);
  for (const name of ["Unassigned", "Away Medical Cart", "Training Room Cabinet A"])
    assert.ok(html.includes(name), name);
  assert.doesNotMatch(between(html, "item-location-breakdown", "</ul>"), /Old Bin/);
  assert.match(html, /Move stock/);
  assert.match(html, /inputMode="decimal"/);
  const empty = render(ui.ItemLocationsDialog, {
    item: { ...tape, id: "empty", quantity: 0 },
    locations,
    balances,
    onOpenChange: () => {},
    onMove: noop,
  });
  assert.match(empty, /This item has no stock to move/);
});

test("adjustment dialog asks for a location and offers no receipt reason", () => {
  const html = render(ui.QuantityAdjustmentDialog, {
    item: gauze,
    locations,
    balances,
    onOpenChange: () => {},
    onAdjust: noop,
  });
  assert.match(html, /<select id="adjust-location"/);
  assert.match(html, /Unassigned \(2\.75 box\)/);
  assert.doesNotMatch(html, /Invoice received/);
  assert.doesNotMatch(html, /Old Bin/, "archived empty locations are not offered");
});

test("inventory table shows totals with placement", () => {
  const html = render(ui.InventoryTable, {
    items: [tape, gauze],
    locations,
    balances,
    onEdit: () => {},
    onArchive: () => {},
    onAdjust: () => {},
    onLocations: () => {},
  });
  assert.match(html, /2 locations/);
  assert.match(html, />2\.75</);
  assert.match(html, />Unassigned</);
  assert.match(html, /Locations &amp; move stock/);
});

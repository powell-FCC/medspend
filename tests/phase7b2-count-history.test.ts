// Phase 7B.2: Count history and corrections. Pure count-history rules; structural checks of
// the migration, routes, navigation and server functions; rendered owner/admin UI. Database
// behavior is covered by supabase/tests/phase7b2_inventory_count_history_behavior.sql (and
// phase7b2_mutation_check.sh); the API with real JWTs by
// run_phase7b2_count_history_integration.sh.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  COUNT_HISTORY_EXPLAINER,
  correctionCountLabel,
  countDateRange,
  countHistoryEmptyMessage,
  displayUnit,
  formatCorrectionSummary,
  formatCountDateTime,
  formatSignedQuantity,
  splitCountLines,
} from "../src/inventory/count-history.ts";
import { workspaceTabs } from "../src/inventory/workspace.ts";
import type {
  CountCorrectionUnit,
  CountHistoryRow,
  CountSessionDetail,
} from "../src/types/inventory-workspace.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const migration = read("supabase/migrations/20261029120000_phase7b2_inventory_count_history.sql");
const migrationCode = migration.replace(/--.*$/gm, "");
const functionBody = (name: string) => {
  const start = migration.indexOf(`CREATE FUNCTION public.${name}(`);
  assert.ok(start >= 0, name);
  return migration.slice(start, migration.indexOf("\n$$;", start));
};
const readFunctions = ["list_inventory_count_history", "get_inventory_count_session"];
const newSources = [
  "src/inventory/count-history.ts",
  "src/components/inventory/workspace/CountHistoryPanel.tsx",
  "src/components/inventory/workspace/CountHistoryTable.tsx",
  "src/components/inventory/workspace/CountSessionView.tsx",
  "src/components/inventory/workspace/CountSessionPage.tsx",
  "src/routes/_authenticated/inventory.counts.$sessionId.tsx",
];

// Bundle the UI before any test is registered, so cleanup cannot race the build.
const cacheDir = join(root, "node_modules/.cache/phase7b2-count-history-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));
const stubs: Record<string, string> = {
  "@tanstack/react-router": `
    import { createElement } from "react";
    export const Link = ({ to, params, children, className }) =>
      createElement("a", { href: String(to).replace("$sessionId", params?.sessionId ?? "")
        .replace("$locationId", params?.locationId ?? ""), className }, children);`,
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
  export { CountHistoryTable } from "@/components/inventory/workspace/CountHistoryTable";
  export { CountSessionView } from "@/components/inventory/workspace/CountSessionView";
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
      name: "count-history-stubs",
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
    .replace(/&#x27;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ");

const unit = (
  name: string,
  netDelta: number,
  increase: number,
  decrease: number,
  changedLines = 1,
): CountCorrectionUnit => ({ unit: name, changedLines, netDelta, increase, decrease });

// The mixed count from the SQL suite.
const mixedSummary = [
  unit("bottle", -0.25, 0, -0.25),
  unit("box", 1, 1, 0),
  unit("each", 1, 4, -3, 2),
  unit("roll", -2, 0, -2),
];
const historyRow = (overrides: Partial<CountHistoryRow> = {}): CountHistoryRow => ({
  sessionId: "7b200000-0000-4000-8000-0000000000a1",
  submittedAt: "2026-10-29T15:04:00Z",
  locationId: "7b200000-0000-4000-8000-0000000000b1",
  locationName: "Cabinet",
  locationActive: true,
  countedBy: "7b200000-0000-4000-8000-000000000003",
  countedByName: "Sam Staff",
  lineCount: 6,
  changedCount: 5,
  correctionSummary: mixedSummary,
  ...overrides,
});
const line = (
  name: string,
  previousQuantity: number,
  countedQuantity: number,
  overrides: Partial<CountSessionDetail["lines"][number]> = {},
) => ({
  inventoryItemId: `item-${name}`,
  name,
  sku: `${name.toUpperCase()}-1`,
  unit: "each",
  previousQuantity,
  countedQuantity,
  delta: Number((countedQuantity - previousQuantity).toFixed(6)),
  itemArchivedNow: false,
  ...overrides,
});
const mixedSession: CountSessionDetail = {
  ...historyRow(),
  lines: [
    line("Gauze", 4, 5, { unit: "box" }),
    line("Saline", 2.5, 2.25, { unit: "bottle" }),
    line("Tape", 8, 6, { unit: "roll" }),
    line("Archived Kit", 3, 3, { itemArchivedNow: true }),
  ],
};

// ---------------------------------------------------------------------------------------
// Pure rules.
// ---------------------------------------------------------------------------------------
test("signed quantities are exact and never round fractional inventory", () => {
  assert.equal(formatSignedQuantity(3), "+3");
  assert.equal(formatSignedQuantity(-2), "-2");
  assert.equal(formatSignedQuantity(0), "0");
  assert.equal(formatSignedQuantity(-0), "0");
  assert.equal(formatSignedQuantity(-0.25), "-0.25");
  assert.equal(formatSignedQuantity(0.000001), "+0.000001");
  assert.equal(formatSignedQuantity(1.1 + 2.2 - 3.3), "0", "float noise below six decimals");
});

test("correction summaries group by unit and never add incompatible units", () => {
  assert.equal(formatCorrectionSummary(mixedSummary), "-0.25 bottle · +1 box · +1 each · -2 roll");
  assert.equal(formatCorrectionSummary([unit("each", -3, 0, -3)]), "-3 each");
  assert.equal(
    formatCorrectionSummary([unit("roll", 1, 1, 0), unit("each", -4, 0, -4)]),
    "-4 each · +1 roll",
    "deterministic order whatever the input order",
  );
  assert.equal(
    formatCorrectionSummary([unit("each", 0, 2, -2, 2)]),
    "net 0 each (+2 / -2)",
    "corrections that cancel out are still shown",
  );
  assert.equal(formatCorrectionSummary([]), "No corrections");
  assert.equal(formatCorrectionSummary([unit("", -1, 0, -1)]), "-1 units", "neutral fallback");
  assert.equal(displayUnit("  BX "), "BX", "units shown as recorded, no invented plural");
  assert.equal(displayUnit(null), "units");
  // No single cross-unit total: the mixed summary never shows a sum of every delta.
  assert.doesNotMatch(formatCorrectionSummary(mixedSummary), /-0\.25 total|\+?-?0\.75/);
});

test("correction counts, empty states and line split", () => {
  assert.equal(correctionCountLabel(0), "No corrections");
  assert.equal(correctionCountLabel(1), "1 correction");
  assert.equal(correctionCountLabel(5), "5 corrections");
  assert.equal(
    countHistoryEmptyMessage({ filtered: false, forLocation: false }),
    "No physical counts have been submitted yet.",
  );
  assert.equal(
    countHistoryEmptyMessage({ filtered: false, forLocation: true }),
    "No physical counts have been submitted for this location yet.",
  );
  assert.equal(
    countHistoryEmptyMessage({ filtered: true, forLocation: true }),
    "No counts match these filters.",
  );
  const { changed, unchanged } = splitCountLines(mixedSession.lines);
  assert.deepEqual(
    changed.map((row) => row.name),
    ["Gauze", "Saline", "Tape"],
  );
  assert.deepEqual(
    unchanged.map((row) => row.name),
    ["Archived Kit"],
  );
});

test("date inputs become a half-open range in the viewer's time zone", () => {
  const range = countDateRange("2026-01-05", "2026-01-09");
  assert.equal(range.submittedFrom, new Date(2026, 0, 5).toISOString());
  assert.equal(range.submittedBefore, new Date(2026, 0, 10).toISOString());
  assert.deepEqual(countDateRange("", ""), { submittedFrom: null, submittedBefore: null });
  assert.equal(
    countDateRange("2026-01-31", "2026-01-31").submittedBefore,
    new Date(2026, 1, 1).toISOString(),
  );
  assert.equal(countDateRange("bad", "").submittedFrom, null);
});

test("copy is factual: a count replaces the recorded quantity; no blame words anywhere", () => {
  assert.equal(
    COUNT_HISTORY_EXPLAINER,
    "A physical count replaces SportSpend's recorded quantity with what is actually on hand. Differences are shown as count corrections and may reflect routine use that staff are not required to log.",
  );
  const source = newSources.map(read).join("\n");
  assert.doesNotMatch(
    source,
    /\b(theft|stolen|steal|waste[ds]?|loss|lost|shrink(age)?|misuse|missing|discrepanc\w*|unlogged|unaccounted|overdue|due|fresh)\b/i,
  );
  assert.match(source, /Recorded/);
  assert.match(source, /Counted/);
  assert.match(source, /Correction/);
});

// ---------------------------------------------------------------------------------------
// The migration.
// ---------------------------------------------------------------------------------------
test("the migration is additive: two read functions and their grants only", () => {
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
    /CREATE\s+(TABLE|INDEX|UNIQUE|POLICY|TRIGGER|TEMP|VIEW)|ALTER\s+(TABLE|POLICY|FUNCTION)|DROP\s|CREATE OR REPLACE|GRANT\s+\w+(,\s*\w+)*\s+ON\s+(TABLE\s+)?public\.|INSERT\s+INTO|DELETE\s+FROM|UPDATE\s+public|TRUNCATE/i,
  );
  const created = [...migrationCode.matchAll(/CREATE FUNCTION public\.(\w+)\(/g)]
    .map((m) => m[1])
    .sort();
  assert.deepEqual(created, [...readFunctions].sort());
  assert.doesNotMatch(migrationCode, /cadence|due_at|overdue/i, "no count cadence");
});

test("both reads: owner or admin only, organization-scoped, stable, no prices or ledger", () => {
  for (const name of readFunctions) {
    const body = functionBody(name);
    assert.match(body, /\nSTABLE\nSECURITY DEFINER\nSET search_path = public/, name);
    assert.match(
      body,
      /IF auth\.uid\(\) IS NULL OR NOT public\.is_org_admin\(_organization_id, auth\.uid\(\)\) THEN\n\s+RAISE EXCEPTION 'Forbidden: owner or admin access required' USING ERRCODE = '42501';/,
      name,
    );
    assert.match(body, /organization_id = _organization_id/, `${name} scopes by organization`);
    assert.match(body, /list_organization_member_identities\(_organization_id\)/, name);
    assert.match(body, /'Former member'/, name);
    assert.doesNotMatch(
      body,
      /price|last_purchase|inventory_adjustments|email|raw_user_meta/i,
      name,
    );
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
});

test("history pages by (submitted_at DESC, id DESC); detail uses count-time snapshots", () => {
  const list = functionBody("list_inventory_count_history");
  assert.match(list, /ORDER BY session\.submitted_at DESC, session\.id DESC\n\s+LIMIT _limit/);
  assert.match(list, /\(session\.submitted_at, session\.id\) < \(_after_submitted_at, _after_id\)/);
  assert.match(list, /GROUP BY line\.item_unit/, "corrections grouped by unit");
  const detail = functionBody("get_inventory_count_session");
  for (const field of [
    "'name', line.item_name",
    "'sku', line.item_sku",
    "'unit', line.item_unit",
    "'previousQuantity', trim_scale(line.previous_quantity)",
    "'countedQuantity', trim_scale(line.counted_quantity)",
    "'delta', trim_scale(line.delta)",
    "'itemArchivedNow', NOT item.active",
  ])
    assert.ok(detail.includes(field), field);
  assert.match(detail, /ORDER BY \(line\.delta = 0\), lower\(line\.item_name\)/);
  assert.doesNotMatch(
    detail.slice(detail.indexOf("'lines'")),
    /delta <> 0/,
    "zero-delta lines are never filtered out",
  );
});

// ---------------------------------------------------------------------------------------
// Routes, navigation and server functions.
// ---------------------------------------------------------------------------------------
test("Counts joins the Inventory workspace and storage locations; Unassigned has none", () => {
  // Phase 7B.3 adds Activity after Counts; Phase 7B.4 puts Overview first.
  assert.deepEqual(workspaceTabs, ["overview", "items", "locations", "counts", "activity"]);
  assert.match(
    read("src/routes/_authenticated/inventory.index.tsx"),
    /z\s*\.enum\(\["overview", "items", "locations", "counts", "activity"\]\)/,
  );
  assert.match(
    read("src/routes/_authenticated/inventory.locations.$locationId.tsx"),
    /z\.enum\(\["stock", "labels", "counts", "activity"\]\)/,
  );
  const workspace = read("src/components/inventory/workspace/InventoryWorkspacePage.tsx");
  assert.match(workspace, /<TabsTrigger value="counts">Counts<\/TabsTrigger>/);
  assert.match(workspace, /<CountHistoryPanel organizationId=\{active\.organizationId\} \/>/);
  const detail = read("src/components/inventory/workspace/LocationDetailPage.tsx");
  assert.match(detail, /\{storage && <TabsTrigger value="counts">Counts<\/TabsTrigger>\}/);
  assert.match(
    detail,
    /<CountHistoryPanel organizationId=\{organizationId\} locationId=\{location\.id\} \/>/,
    "the location tab reuses the same history panel and read contract",
  );
  // Unassigned shows Stock and (7B.3) Activity, never Labels or Counts.
  assert.match(
    detail,
    /tab=\{location\.data\.kind === "unassigned" && tab !== "activity" \? "stock" : tab\}/,
  );
  const route = read("src/routes/_authenticated/inventory.counts.$sessionId.tsx");
  assert.match(route, /createFileRoute\("\/_authenticated\/inventory\/counts\/\$sessionId"\)/);
  assert.match(read("src/routeTree.gen.ts"), /\/inventory\/counts\/\$sessionId/);
  const page = read("src/components/inventory/workspace/CountSessionPage.tsx");
  assert.match(page, /to="\/inventory"\n\s+search=\{\{ tab: "counts" \}\}/);
  assert.match(page, /to="\/inventory\/locations\/\$locationId"/);
  assert.match(page, /inventoryWorkspaceAccess\(active\?\.role\)/);
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
    assert.doesNotMatch(
      read(path),
      /count-history|CountHistory|list_inventory_count_history/,
      path,
    );
});

test("server functions: authenticated, validated, and read-only RPCs only", () => {
  const fns = read("src/lib/inventory-workspace.functions.ts");
  for (const name of ["listCountHistoryFn", "getCountSessionFn"]) {
    const start = fns.indexOf(`export const ${name}`);
    assert.ok(start >= 0, name);
    const block = fns.slice(start, fns.indexOf("\nexport const", start + 1));
    assert.match(block, /\.middleware\(\[requireSupabaseAuth\]\)/, name);
    assert.match(block, /\.inputValidator\(/, name);
  }
  const reads = read("src/inventory/workspace-reads.ts");
  const countReads = reads.slice(reads.indexOf("// Phase 7B.2"), reads.indexOf("// Owner: revoke"));
  assert.deepEqual(
    [...countReads.matchAll(/db\.(rpc|from)\("(\w+)"/g)].map((m) => `${m[1]}:${m[2]}`),
    ["rpc:list_inventory_count_history", "rpc:get_inventory_count_session"],
    "no raw table reads",
  );
});

// ---------------------------------------------------------------------------------------
// Rendered UI. Owners and admins get the same read-only view: these components take no
// role and render no controls that change anything.
// ---------------------------------------------------------------------------------------
test("history table: date, location, who, lines, corrections and per-unit summary", () => {
  const rows = [
    historyRow(),
    historyRow({
      sessionId: "7b200000-0000-4000-8000-0000000000a2",
      locationName: "Old Closet",
      locationActive: false,
      countedByName: "Former member",
      lineCount: 1,
      changedCount: 0,
      correctionSummary: [],
    }),
  ];
  const html = render(ui.CountHistoryTable, { rows, showLocation: true, emptyMessage: "x" });
  const plain = text(html);
  for (const heading of [
    "Date / time",
    "Location",
    "Counted by",
    "Lines",
    "Corrections",
    "Correction summary",
  ])
    assert.ok(plain.includes(heading), heading);
  assert.ok(plain.includes(formatCountDateTime("2026-10-29T15:04:00Z")));
  assert.ok(plain.includes("-0.25 bottle · +1 box · +1 each · -2 roll"));
  assert.ok(plain.includes("5 corrections"));
  assert.ok(plain.includes("No corrections"));
  assert.ok(plain.includes("Former member"));
  assert.ok(plain.includes("Archived now"));
  assert.ok(plain.includes("Old Closet (archived now)"), "phone card says so too");
  assert.match(html, /href="\/inventory\/counts\/7b200000-0000-4000-8000-0000000000a1"/);
  assert.match(html, /class="divide-y md:hidden"/, "phone cards");
  assert.match(html, /class="hidden overflow-x-auto md:block"/, "table scrolls in its panel");
  assert.doesNotMatch(html, /<button|<input|<select/, "no mutation controls");

  const locationHtml = render(ui.CountHistoryTable, {
    rows,
    showLocation: false,
    emptyMessage: "x",
  });
  assert.doesNotMatch(text(locationHtml), /Location /, "location column hidden on a location");

  const empty = render(ui.CountHistoryTable, {
    rows: [],
    showLocation: true,
    emptyMessage: "No physical counts have been submitted yet.",
  });
  assert.ok(text(empty).includes("No physical counts have been submitted yet."));
});

test("session detail: corrections first, then unchanged; recorded, counted, correction", () => {
  const html = render(ui.CountSessionView, { session: mixedSession });
  const plain = text(html);
  assert.ok(plain.includes(COUNT_HISTORY_EXPLAINER));
  for (const fact of [
    "Submitted",
    "Counted by Sam Staff",
    "Lines counted 6",
    "Count corrections 5",
    "Correction by unit -0.25 bottle · +1 box · +1 each · -2 roll",
  ])
    assert.ok(plain.includes(fact), fact);
  assert.ok(plain.indexOf("Corrections") < plain.indexOf("No change"), "changed first");
  assert.ok(plain.includes("3 items changed"));
  assert.ok(plain.includes("1 item matched the recorded quantity"));
  // Desktop row and phone card both read Recorded / Counted / Correction.
  assert.ok(plain.includes("Recorded 8 · Counted 6 · Correction -2"));
  assert.ok(plain.includes("Recorded 2.5 · Counted 2.25 · Correction -0.25"));
  assert.ok(plain.includes("Recorded 4 · Counted 5 · Correction +1"));
  assert.ok(plain.includes("Recorded 3 · Counted 3 · Correction 0"), "zero-delta line kept");
  for (const heading of ["Item", "SKU", "Unit", "Recorded", "Counted", "Correction"])
    assert.ok(plain.includes(heading), heading);
  assert.ok(plain.includes("Archived Kit Archived now"));
  assert.doesNotMatch(plain, /archived when counted|was archived/i);
  assert.match(
    html,
    /<details class="space-y-2">/,
    "unchanged lines collapsed when there are corrections",
  );
  assert.doesNotMatch(html, /<button|<input|<select|<form/, "no mutation controls");
});

test("a count with no corrections is a positive state and still shows every line", () => {
  const session: CountSessionDetail = {
    ...historyRow({ changedCount: 0, correctionSummary: [], lineCount: 2 }),
    lines: [line("Tape", 4, 4, { unit: "roll" }), line("Wrap", 0, 0)],
  };
  const html = render(ui.CountSessionView, { session });
  const plain = text(html);
  assert.ok(plain.includes("No corrections were needed."));
  assert.ok(plain.includes("2 items matched the recorded quantity"));
  assert.ok(plain.includes("Recorded 4 · Counted 4 · Correction 0"));
  assert.ok(plain.includes("Recorded 0 · Counted 0 · Correction 0"));
  assert.match(html, /<details open="" class="space-y-2">/, "unchanged lines open by default");
  const archivedLocation = render(ui.CountSessionView, {
    session: { ...session, locationActive: false },
  });
  assert.ok(text(archivedLocation).includes("Location archived now"));
});

// ---------------------------------------------------------------------------------------
// Release files.
// ---------------------------------------------------------------------------------------
test("release files: precheck and postcheck end with the shared fingerprint; nothing writes", () => {
  const dir = "supabase/release/phase7b2";
  const fingerprint = read(`${dir}/fingerprint.sql`);
  const select = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM"));
  for (const name of ["precheck.sql", "postcheck.sql"]) {
    const file = read(`${dir}/${name}`);
    assert.ok(file.endsWith(select), `${name} ends with the fingerprint`);
    assert.doesNotMatch(
      file.replace(/--.*$/gm, ""),
      /\b(BEGIN;|COMMIT;|ROLLBACK;|INSERT\s+INTO|UPDATE\s+public|DELETE\s+FROM|CREATE\s|ALTER\s|DROP\s|GRANT\s|REVOKE\s)/i,
      name,
    );
  }
  assert.match(read(`${dir}/precheck.sql`), /'precheck: Phase 7B\.2 objects already exist'/);
  assert.match(read(`${dir}/precheck.sql`), /'precheck: Phase 7B\.1 is not applied'/);
  const post = read(`${dir}/postcheck.sql`);
  for (const name of readFunctions)
    assert.match(
      post,
      new RegExp(`\\('${name}', '[0-9a-f]{32} secdef=true authenticated=true anon=false'\\)`),
    );
  for (const name of readFunctions)
    assert.match(fingerprint, new RegExp(`\\('${name}'\\)`), `${name} fingerprinted`);
  assert.match(read(`${dir}/README.md`), /115 → 117/);
});

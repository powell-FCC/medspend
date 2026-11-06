// Phase 7B.5: optional count cadence. Pure cadence wording; structural checks of the migration,
// server functions and wiring; rendered Settings, Overview and location UI. Database behavior
// is covered by supabase/tests/phase7b5_inventory_count_cadence_behavior.sql (and
// phase7b5_mutation_check.sh); the API with real JWTs by
// run_phase7b5_count_cadence_integration.sh.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  COUNT_CADENCE_EXPLAINER,
  cadenceLabel,
  freshnessStateLabel,
  locationScheduleLine,
  parseIntervalDays,
} from "../src/inventory/count-cadence.ts";
import type { CountFreshness, CountPolicy } from "../src/types/inventory-workspace.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const migration = read("supabase/migrations/20261106120000_phase7b5_inventory_count_cadence.sql");
const migrationCode = migration.replace(/--.*$/gm, "");
const functionBody = (name: string) => {
  const start = migration.indexOf(`CREATE FUNCTION public.${name}(`);
  assert.ok(start >= 0, name);
  return migration.slice(start, migration.indexOf("\n$$;", start));
};
const newSources = [
  "src/inventory/count-cadence.ts",
  "src/components/settings/CountPolicySettings.tsx",
  "src/components/inventory/workspace/CountScheduleAttention.tsx",
  "src/components/inventory/workspace/LocationCountSchedule.tsx",
];

// Bundle the UI before any test is registered, so cleanup cannot race the build.
const cacheDir = join(root, "node_modules/.cache/phase7b5-count-cadence-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));
const pending = "() => new Promise(() => {})";
const stubs: Record<string, string> = {
  "@tanstack/react-router": `
    import { createElement } from "react";
    export const Link = ({ to, params, children, className }) =>
      createElement("a", { href: String(to).replace("$locationId", params?.locationId ?? ""), className }, children);`,
  "@tanstack/react-start": `export const useServerFn = (fn) => fn;`,
  "@/lib/inventory.functions": `export const setCountPolicyFn = ${pending};`,
  "@/lib/inventory-workspace.functions": `
    export const getCountPolicyFn = ${pending}, getCountFreshnessFn = ${pending};`,
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
  export { CountPolicyForm, CountPolicySummary } from "@/components/settings/CountPolicySettings";
  export { CountScheduleSection } from "@/components/inventory/workspace/CountScheduleAttention";
  export { LocationCountScheduleView } from "@/components/inventory/workspace/LocationCountSchedule";
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
      name: "cadence-stubs",
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

const policy = (overrides: Partial<CountPolicy> = {}): CountPolicy => ({
  configured: true,
  enabled: true,
  intervalDays: 30,
  updatedAt: "2026-11-01T15:00:00Z",
  updatedByName: "Olivia Owner",
  ...overrides,
});
const freshness = (overrides: Partial<CountFreshness> = {}): CountFreshness => ({
  policy: { enabled: true, intervalDays: 30 },
  evaluatedAt: "2026-11-06T12:00:00Z",
  summary: { current: 4, due: 1, overdue: 2, neverCounted: 1, counted: 0, nothingToCount: 0 },
  attention: {
    total: 3,
    rows: [
      {
        locationId: "l-closet",
        name: "Closet",
        state: "overdue",
        lastCountedAt: "2026-08-01T12:00:00Z",
        nextDueAt: "2026-08-31T12:00:00Z",
      },
      {
        locationId: "l-cart",
        name: "Away Cart",
        state: "due",
        lastCountedAt: "2026-10-07T18:00:00Z",
        nextDueAt: "2026-11-06T06:00:00Z",
      },
    ],
  },
  nextDue: { locationId: "l-cab", name: "Cabinet", nextDueAt: "2026-11-20T12:00:00Z" },
  location: null,
  ...overrides,
});

// ---------------------------------------------------------------------------------------
// Pure rules.
// ---------------------------------------------------------------------------------------
test("interval input: whole days 1..365, never coerced", () => {
  assert.deepEqual(parseIntervalDays("30"), { ok: true, value: 30 });
  assert.deepEqual(parseIntervalDays(" 1 "), { ok: true, value: 1 });
  assert.deepEqual(parseIntervalDays("365"), { ok: true, value: 365 });
  for (const bad of ["0", "366", "-7", "7.5", "", "abc", "1e2", "30 days"])
    assert.equal(parseIntervalDays(bad).ok, false, bad);
  assert.deepEqual(parseIntervalDays("0"), { ok: false, error: "Count every 1 to 365 days." });
});

test("cadence wording: off, every day, every N days; state labels; schedule lines", () => {
  assert.equal(cadenceLabel({ enabled: false, intervalDays: 30 }), "Off");
  assert.equal(cadenceLabel({ enabled: true, intervalDays: 1 }), "Every day");
  assert.equal(cadenceLabel({ enabled: true, intervalDays: 30 }), "Every 30 days");
  assert.deepEqual(freshnessStateLabel, {
    not_applicable: "Not scheduled",
    nothing_to_count: "Nothing to count",
    never_counted: "Never counted",
    counted: "Counted",
    current: "Current",
    due: "Due",
    overdue: "Overdue",
  });
  const base = { locationId: "l", lastCountedAt: null, countableItemCount: 3 };
  assert.match(
    locationScheduleLine({ ...base, state: "current", nextDueAt: "2026-11-20T12:00:00Z" })!,
    /^Next count due /,
  );
  assert.match(
    locationScheduleLine({ ...base, state: "due", nextDueAt: "2026-11-06T06:00:00Z" })!,
    /^Count due since /,
  );
  assert.match(
    locationScheduleLine({ ...base, state: "overdue", nextDueAt: "2026-08-31T12:00:00Z" })!,
    /^Count was due /,
  );
  assert.equal(
    locationScheduleLine({ ...base, state: "never_counted", nextDueAt: null }),
    "Not counted yet",
  );
  for (const state of ["not_applicable", "nothing_to_count", "counted"] as const)
    assert.equal(locationScheduleLine({ ...base, state, nextDueAt: null }), null, state);
});

test("copy is operational freshness only: no judgement about stock", () => {
  assert.equal(
    COUNT_CADENCE_EXPLAINER,
    "Set how often physical storage locations should be counted. This does not track day-to-day consumption; it identifies when a new physical reconciliation is due.",
  );
  const source = newSources.map(read).join("\n").replace(COUNT_CADENCE_EXPLAINER, "");
  assert.doesNotMatch(
    source,
    /\b(stale|inaccurate|incorrect|wrong|bad inventory|shrink(age)?|waste[ds]?|consum\w*|missing|lost|theft|misuse|remind\w*|notif\w*|email)\b/i,
  );
});

// ---------------------------------------------------------------------------------------
// The migration.
// ---------------------------------------------------------------------------------------
test("the migration adds one table and four functions, and changes nothing existing", () => {
  assert.match(migration, /^BEGIN;$/m);
  assert.match(migration, /^COMMIT;\s*$/m);
  assert.equal(
    migration
      .slice(migration.lastIndexOf("\nCOMMIT;") + 8)
      .replace(/--.*$/gm, "")
      .trim(),
    "",
  );
  assert.doesNotMatch(migrationCode, /CREATE\s+TEMP/i, "no temp tables (SQL Editor path)");
  assert.deepEqual(
    [...migrationCode.matchAll(/CREATE TABLE public\.(\w+)/g)].map((m) => m[1]),
    ["inventory_count_policies"],
  );
  assert.deepEqual(
    [...migrationCode.matchAll(/CREATE FUNCTION public\.(\w+)\(/g)].map((m) => m[1]).sort(),
    [
      "get_inventory_count_freshness",
      "get_inventory_count_policy",
      "inventory_location_count_freshness",
      "set_inventory_count_policy",
    ],
  );
  assert.doesNotMatch(
    migrationCode,
    /CREATE\s+(UNIQUE\s+)?INDEX|CREATE OR REPLACE|ALTER\s+(FUNCTION|POLICY)|CREATE\s+POLICY|CREATE\s+TRIGGER|DROP\s|TRUNCATE|DELETE\s+FROM/i,
  );
  // The only ALTER is enabling RLS on the new table; the only writes are the policy upsert.
  assert.deepEqual(
    [...migrationCode.matchAll(/ALTER TABLE public\.(\w+)/g)].map((m) => m[1]),
    ["inventory_count_policies"],
  );
  assert.deepEqual(
    [...migrationCode.matchAll(/INSERT INTO public\.(\w+)/g)].map((m) => m[1]),
    ["inventory_count_policies"],
  );
  assert.match(
    migration,
    /REVOKE ALL ON public\.inventory_count_policies FROM PUBLIC, anon, authenticated, service_role;/,
  );
  assert.match(migration, /CHECK \(interval_days BETWEEN 1 AND 365\)/);
  assert.match(migration, /CHECK \(NOT enabled OR interval_days IS NOT NULL\)/);
});

test("authorization in every function: reads owner+admin, write owner only, helper internal", () => {
  for (const name of ["get_inventory_count_policy", "get_inventory_count_freshness"]) {
    const body = functionBody(name);
    assert.match(body, /\nSTABLE\nSECURITY DEFINER\nSET search_path = public/, name);
    assert.match(
      body,
      /IF auth\.uid\(\) IS NULL OR NOT public\.is_org_admin\(_organization_id, auth\.uid\(\)\) THEN/,
    );
  }
  const write = functionBody("set_inventory_count_policy");
  assert.match(write, /\nSECURITY DEFINER\nSET search_path = public/);
  assert.match(
    write,
    /public\.has_org_role\(_organization_id, auth\.uid\(\), ARRAY\['owner'\]::public\.org_role\[\]\)/,
  );
  assert.match(
    migration,
    /REVOKE ALL ON FUNCTION public\.inventory_location_count_freshness\(uuid, timestamptz\) FROM PUBLIC, anon, authenticated;/,
  );
  const helper = functionBody("inventory_location_count_freshness");
  assert.doesNotMatch(helper, /SECURITY DEFINER|now\(\)/, "pure: time is a parameter");
  for (const rule of [
    "WHEN NOT scheduled.active THEN 'not_applicable'",
    "WHEN scheduled.countable = 0 THEN 'nothing_to_count'",
    "WHEN scheduled.last_counted_at IS NULL THEN 'never_counted'",
    "WHEN NOT scheduled.enabled THEN 'counted'",
    "WHEN _as_of < scheduled.due_at THEN 'current'",
    "WHEN _as_of < scheduled.due_at + interval '1 day' THEN 'due'",
    "ELSE 'overdue'",
  ])
    assert.ok(helper.includes(rule), rule);
  assert.match(helper, /location\.kind = 'storage'/, "Unassigned never takes part");
  assert.match(helper, /ORDER BY session\.submitted_at DESC LIMIT 1/, "newest count decides");
});

// ---------------------------------------------------------------------------------------
// Server functions and wiring.
// ---------------------------------------------------------------------------------------
test("server functions: reads validated; the write is owner-checked and validated", () => {
  const reads = read("src/lib/inventory-workspace.functions.ts");
  for (const name of ["getCountPolicyFn", "getCountFreshnessFn"]) {
    const block = reads.slice(reads.indexOf(`export const ${name}`));
    assert.match(block, /\.middleware\(\[requireSupabaseAuth\]\)/, name);
  }
  const writes = read("src/lib/inventory.functions.ts");
  const setFn = writes.slice(writes.indexOf("export const setCountPolicyFn"));
  assert.match(setFn, /\.middleware\(\[requireSupabaseAuth\]\)/);
  assert.match(setFn, /intervalDays: z\.number\(\)\.int\(\)\.min\(1\)\.max\(365\)\.nullable\(\)/);
  assert.match(
    setFn,
    /await assertOwner\(context\.supabase, context\.userId, data\.organizationId\);/,
  );
  const workspaceReads = read("src/inventory/workspace-reads.ts");
  const cadence = workspaceReads.slice(
    workspaceReads.indexOf("// Phase 7B.5"),
    workspaceReads.indexOf("// Phase 7B.4"),
  );
  assert.deepEqual(
    [...cadence.matchAll(/db\.(rpc|from)\("(\w+)"/g)].map((m) => `${m[1]}:${m[2]}`),
    [
      "rpc:get_inventory_count_policy",
      "rpc:set_inventory_count_policy",
      "rpc:get_inventory_count_freshness",
    ],
    "RPCs only, no raw table reads",
  );
});

test("wiring: Settings for owners/admins, Overview section, active storage locations only", () => {
  const settings = read("src/routes/_authenticated/settings.tsx");
  assert.match(
    settings,
    /<CountPolicySettings\s+organizationId=\{active\.organizationId\}\s+canManage=\{active\.role === "owner"\}\s+\/>/,
  );
  assert.match(settings, /active\.role !== "owner" && active\.role !== "admin"\)\) return null/);
  assert.match(
    read("src/components/inventory/workspace/InventoryOverviewTab.tsx"),
    /<NeedsAttention overview=\{overview\.data\} \/>\s*<CountScheduleAttention organizationId=\{organizationId\} \/>/,
  );
  assert.match(
    read("src/components/inventory/workspace/LocationDetailPage.tsx"),
    /\{storage && location\.active && \(\s*<LocationCountSchedule organizationId=\{organizationId\} locationId=\{location\.id\} \/>/,
  );
  const gate = read("src/routes/_authenticated/route.tsx");
  assert.match(gate, /const ADMIN_ROUTES = \[[^\]]*"\/settings"/, "staff never reach Settings");
  assert.match(gate, /const STAFF_ROUTES = \["\/staff", "\/profile", "\/count"\];/);
});

// ---------------------------------------------------------------------------------------
// Rendered UI.
// ---------------------------------------------------------------------------------------
test("Settings: owners get the form; admins get a read-only summary", () => {
  const owner = render(ui.CountPolicyForm, { organizationId: "org", policy: policy() });
  const plain = text(owner);
  assert.match(owner, /type="checkbox"[^>]*checked=""/);
  assert.ok(plain.includes("Enable count cadence"));
  assert.match(owner, /id="count-interval-days"[^>]*value="30"/);
  for (const days of [7, 14, 30, 60, 90]) assert.ok(plain.includes(`${days} days`));
  assert.ok(plain.includes("Save count cadence"));
  assert.match(plain, /Last changed .* by Olivia Owner/);
  const off = render(ui.CountPolicyForm, {
    organizationId: "org",
    policy: policy({ enabled: false, intervalDays: null, configured: false, updatedAt: null }),
  });
  assert.match(off, /id="count-interval-days"[^>]*disabled=""/, "interval disabled while off");
  assert.doesNotMatch(off, /type="checkbox"[^>]*checked=""/);

  const admin = render(ui.CountPolicySummary, { policy: policy() });
  assert.ok(text(admin).includes("Count cadence: Every 30 days"));
  assert.ok(text(admin).includes("Only owners can change the count cadence."));
  assert.doesNotMatch(admin, /<input|<button|<form/, "no controls for admins");
  assert.ok(
    text(render(ui.CountPolicySummary, { policy: policy({ enabled: false }) })).includes(
      "Count cadence: Off",
    ),
  );
});

test("Overview: nothing while cadence is off; due and overdue with states while on", () => {
  assert.equal(
    render(ui.CountScheduleSection, {
      freshness: freshness({
        policy: { enabled: false, intervalDays: null },
        summary: { current: 0, due: 0, overdue: 0, neverCounted: 1, counted: 5, nothingToCount: 0 },
        attention: { total: 0, rows: [] },
        nextDue: null,
      }),
    }),
    "",
    "cadence off: no section, no due/overdue words",
  );
  const on = render(ui.CountScheduleSection, { freshness: freshness() });
  const plain = text(on);
  assert.ok(plain.includes("Count schedule Every 30 days"));
  assert.match(plain, /Overdue 2 Due 1 Current 4/);
  assert.ok(plain.indexOf("Closet") < plain.indexOf("Away Cart"), "most overdue first");
  assert.match(on, /href="\/inventory\/locations\/l-closet"/);
  assert.match(plain, /and 1 more/);
  assert.match(plain, /1 location has never been counted \(listed under Needs attention\)/);
  const clear = text(
    render(ui.CountScheduleSection, {
      freshness: freshness({
        summary: { current: 4, due: 0, overdue: 0, neverCounted: 0, counted: 0, nothingToCount: 0 },
        attention: { total: 0, rows: [] },
      }),
    }),
  );
  assert.match(clear, /No counted location is due\. Next count due .* at Cabinet\./);
  assert.doesNotMatch(clear, /never been counted/);
});

test("Location: schedule line only while cadence is on and the location is scheduled", () => {
  const loc = (state: string, nextDueAt: string | null, lastCountedAt: string | null) => ({
    locationId: "l",
    state,
    nextDueAt,
    lastCountedAt,
    countableItemCount: 3,
  });
  const current = text(
    render(ui.LocationCountScheduleView, {
      freshness: freshness({
        location: loc("current", "2026-11-20T12:00:00Z", "2026-10-21T12:00:00Z"),
      }),
    }),
  );
  assert.match(
    current,
    /Current Next count due .* Count cadence: every 30 days · Last counted Oct 21, 2026/,
  );
  assert.match(
    text(
      render(ui.LocationCountScheduleView, {
        freshness: freshness({ location: loc("never_counted", null, null) }),
      }),
    ),
    /Never counted Not counted yet Count cadence: every 30 days/,
  );
  for (const [state, enabled] of [
    ["current", false],
    ["not_applicable", true],
    ["nothing_to_count", true],
  ] as const)
    assert.equal(
      render(ui.LocationCountScheduleView, {
        freshness: freshness({
          policy: { enabled, intervalDays: enabled ? 30 : null },
          location: loc(state, null, null),
        }),
      }),
      "",
      `${state}/${enabled}`,
    );
});

// ---------------------------------------------------------------------------------------
// Release files.
// ---------------------------------------------------------------------------------------
test("release files: shared fingerprint, read-only, pin 7B.4 and the new objects", () => {
  const dir = "supabase/release/phase7b5";
  const fingerprint = read(`${dir}/fingerprint.sql`);
  const select = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM"));
  for (const name of ["precheck.sql", "postcheck.sql"]) {
    const file = read(`${dir}/${name}`);
    assert.ok(file.endsWith(select), `${name} ends with the fingerprint`);
    assert.doesNotMatch(
      // Comments and string literals (expected index definitions) are not statements.
      file.replace(/--.*$/gm, "").replace(/'(?:[^']|'')*'/g, "''"),
      /\b(BEGIN;|COMMIT;|ROLLBACK;|INSERT\s+INTO|UPDATE\s+public|DELETE\s+FROM|CREATE\s|ALTER\s|DROP\s|GRANT\s|REVOKE\s)/i,
      name,
    );
    assert.match(file, /\('get_inventory_overview', '9babd0fab14f87f4654b369a5a6139d0 secdef=true/);
  }
  assert.match(read(`${dir}/precheck.sql`), /'precheck: Phase 7B\.5 objects already exist'/);
  const post = read(`${dir}/postcheck.sql`);
  for (const name of [
    "get_inventory_count_freshness",
    "get_inventory_count_policy",
    "set_inventory_count_policy",
    "inventory_location_count_freshness",
  ]) {
    assert.match(post, new RegExp(`\\('${name}', '[0-9a-f]{32} secdef=(true|false)`), name);
    assert.match(fingerprint, new RegExp(`\\('${name}'\\)`), `${name} fingerprinted`);
  }
  assert.match(
    post,
    /OR EXISTS \(SELECT 1 FROM public\.inventory_count_policies\) THEN/,
    "no rows",
  );
  assert.match(fingerprint, /\('inventory_count_policies_pkey'\)/);
  assert.match(read(`${dir}/README.md`), /functions 120 → 124, tables 42 → 43, indexes 164 → 165/);
});

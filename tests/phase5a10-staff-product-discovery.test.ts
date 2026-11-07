// Phase 5A.10: staff product discovery, Saved Items and deterministic ranking.
//
// Pure presentation rules, rendered Request Supplies states (bundled with esbuild; only the
// framework seams are stubbed, as in tests/staff-workspace-v2.test.ts), and structural checks
// of the migration, server functions and release artifacts. Database behavior is proven by
// supabase/tests/phase5a10_staff_product_discovery_behavior.sql (+ its mutation check) and the
// real-JWT integration test.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import {
  FREQUENTLY_REQUESTED_MIN,
  buildDiscoverySections,
  describeProductVariant,
  effectiveSaved,
  packageLabel,
  productBadges,
  savedIdentityFor,
  type StaffDiscoveryProduct,
} from "../src/supply-requests/product-discovery.ts";
import { createStructuredCartItem } from "../src/supply-requests/staff-request-cart.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

function item(n: number, overrides: Partial<StaffDiscoveryProduct> = {}): StaffDiscoveryProduct {
  return {
    resultId: `catalog-vendor-product:${uuid(n)}`,
    identitySource: "global_catalog",
    productName: "Athletic Tape",
    manufacturer: "Fixture Mfg",
    vendorName: "Henry Schein",
    vendorSku: `AT-${n}`,
    packageDisplay: "24 roll",
    packageStatus: "verified",
    specification: null,
    variantDetail: null,
    unit: null,
    packSize: null,
    inventoryItemId: null,
    productId: null,
    vendorProductId: null,
    catalogVendorProductId: uuid(n),
    isSaved: false,
    approvedRequestCount: 0,
    lastApprovedAt: null,
    purchaseCount: 0,
    lastPurchasedAt: null,
    matchTier: 2,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Rendered Request Supplies (bundled before any test is registered)
// ---------------------------------------------------------------------------

const cacheDir = join(root, "node_modules/.cache/phase5a10-discovery-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));

const stubs: Record<string, string> = {
  "@tanstack/react-router": `
    import { createElement } from "react";
    const t = () => globalThis.__staff;
    export const createFileRoute = () => (options) => ({ options });
    export const Link = ({ to, children, activeProps, ...rest }) => createElement("a", { ...rest, href: String(to) }, children);
    export const useSearch = () => t().search;
    export const useNavigate = () => () => {};`,
  "@tanstack/react-query": `
    export const useQueryClient = () => ({ invalidateQueries: async () => {} });
    export const useQuery = (options) => ({
      data: undefined, isLoading: false, isError: false, isFetching: false, isSuccess: false,
      refetch: () => {}, ...globalThis.__staff.query(options.queryKey, options),
    });`,
  "@tanstack/react-start": `
    const builder = () => { const b = { middleware: () => b, inputValidator: () => b, validator: () => b, handler: (h) => h }; return b; };
    export const createServerFn = () => builder();
    export const createMiddleware = () => ({ server: () => ({}) });
    export const useServerFn = (fn) => fn;`,
  "@/integrations/supabase/auth-middleware": `export const requireSupabaseAuth = {};`,
  "@/integrations/supabase/client": `export const supabase = {};`,
  "@/hooks/use-active-org": `export const useActiveOrg = () => ({ active: globalThis.__staff.org, memberships: [], loading: false });`,
  "@/components/ui/alert-dialog": `
    import { createElement } from "react";
    const passthrough = ({ children }) => createElement("div", null, children);
    export const AlertDialog = ({ open, children }) => (open ? createElement("div", null, children) : null);
    export const AlertDialogContent = passthrough, AlertDialogHeader = passthrough, AlertDialogFooter = passthrough,
      AlertDialogTitle = passthrough, AlertDialogDescription = passthrough, AlertDialogAction = passthrough, AlertDialogCancel = passthrough;`,
};

function resolveSource(base: string) {
  for (const candidate of [`${base}.ts`, `${base}.tsx`, join(base, "index.ts"), base]) {
    if (existsSync(candidate) && /\.(ts|tsx)$/.test(candidate)) return candidate;
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
  export { Route as Workspace } from "@/routes/_authenticated/staff/index";
  export { StaffProductPicker } from "@/components/staff/StaffProductPicker";
  export function render(Component, { items } = {}) {
    return renderToStaticMarkup(createElement(StaffCartProvider, { initialItems: items }, createElement(Component)));
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
      name: "discovery-stubs",
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
const ready = (data: unknown) => ({ data, isSuccess: true });
function setStaff(
  queries: Record<string, Record<string, unknown>>,
  search: Record<string, unknown> = {},
) {
  (globalThis as { __staff?: unknown }).__staff = {
    org,
    search,
    query: (key: unknown[]) => {
      const name = key.map(String).join(":");
      for (const [prefix, result] of Object.entries(queries))
        if (name.includes(prefix)) return result;
      return {};
    },
  };
}

const sections = {
  saved: [
    item(11, { productName: "Prewrap Foam", variantDetail: "Beige", isSaved: true }),
    item(12, {
      productName: "Ice Bag",
      variantDetail: "Large",
      isSaved: true,
      purchaseCount: 1,
      lastPurchasedAt: "2026-10-28T12:00:00Z",
    }),
    item(13, { productName: "Cold Pack", isSaved: true }),
    item(14, { productName: "Kinesiology Tape", isSaved: true }),
    item(15, { productName: "Heel Cups", isSaved: true }),
  ],
  frequent: [
    item(21, {
      productName: "Athletic Tape",
      variantDetail: '2" x 15 yd',
      approvedRequestCount: 9,
    }),
    item(22, {
      productName: "Athletic Tape",
      variantDetail: '3" x 15 yd',
      approvedRequestCount: 2,
    }),
  ],
  purchased: [
    item(31, {
      productName: "Nitrile Gloves",
      variantDetail: "Medium",
      purchaseCount: 2,
      lastPurchasedAt: "2026-11-01T12:00:00Z",
    }),
  ],
};

// ---------------------------------------------------------------------------
// Variant presentation
// ---------------------------------------------------------------------------

test("size / color lead, then package; maker, vendor and SKU stay muted for a unique name", () => {
  const lines = describeProductVariant(item(1, { variantDetail: '2" x 15 yd' }), []);
  assert.deepEqual(lines, {
    primary: '2" x 15 yd · 24 roll',
    secondary: "Fixture Mfg · Henry Schein · SKU AT-1",
  });
  // A trusted specification wins over the description.
  assert.equal(
    describeProductVariant(
      item(1, { specification: "0.25 x 30 mm, Brown Tip", variantDetail: "Box" }),
      [],
    ).primary,
    "0.25 x 30 mm, Brown Tip · 24 roll",
  );
});

test("near-identical variants are told apart by what differs between them", () => {
  const two = item(2, { variantDetail: '2" x 15 yd' });
  const three = item(3, { variantDetail: '3" x 15 yd', packageDisplay: "16 roll" });
  assert.equal(describeProductVariant(two, [two, three]).primary, '2" x 15 yd · 24 roll');
  assert.equal(describeProductVariant(three, [two, three]).primary, '3" x 15 yd · 16 roll');

  // Same name and package, different vendors: the vendor moves up, the maker stays muted.
  const a = item(4, { vendorName: "Henry Schein" });
  const b = item(5, { vendorName: "Medline" });
  assert.deepEqual(describeProductVariant(a, [a, b]), {
    primary: "24 roll · Henry Schein",
    secondary: "Fixture Mfg · SKU AT-4",
  });

  // Nothing but the SKU differs: the SKU is the distinguishing line.
  const c = item(6, { packageDisplay: "Unknown", packageStatus: "unknown" });
  const d = item(7, { packageDisplay: "Unknown", packageStatus: "unknown" });
  assert.deepEqual(describeProductVariant(c, [c, d]), {
    primary: "SKU AT-6",
    secondary: "Fixture Mfg · Henry Schein",
  });
});

test("variant lines never say Unknown and never repeat a value", () => {
  const product = item(8, {
    packageDisplay: "Unknown",
    packageStatus: "unknown",
    packSize: "Case of 12",
    manufacturer: "Henry Schein",
    vendorName: "Henry Schein",
  });
  const lines = describeProductVariant(product, []);
  assert.equal(lines.primary, "Case of 12");
  assert.equal(lines.secondary, "Henry Schein · SKU AT-8");
  assert.equal(packageLabel({ packageDisplay: "unknown", packSize: null }), null);
  const bare = item(9, {
    manufacturer: null,
    vendorName: null,
    vendorSku: null,
    packageDisplay: "Unknown",
    packageStatus: "unknown",
  });
  assert.deepEqual(describeProductVariant(bare, []), { primary: null, secondary: null });
});

// ---------------------------------------------------------------------------
// Badges and signals
// ---------------------------------------------------------------------------

test("badges are quiet, organization-level and at most two", () => {
  assert.deepEqual(productBadges(item(1)), []);
  assert.deepEqual(productBadges(item(1, { approvedRequestCount: 1 })), [
    { kind: "approved", label: "Approved once" },
  ]);
  assert.deepEqual(productBadges(item(1, { approvedRequestCount: FREQUENTLY_REQUESTED_MIN - 1 })), [
    { kind: "approved", label: "Approved 2 times" },
  ]);
  const both = productBadges(
    item(1, {
      approvedRequestCount: 7,
      purchaseCount: 3,
      lastPurchasedAt: "2026-10-03T15:00:00Z",
    }),
  );
  assert.deepEqual(both, [
    { kind: "frequent", label: "Frequently requested" },
    { kind: "purchased", label: "Purchased Oct 3" },
  ]);
  for (const badge of both) assert.doesNotMatch(badge.label, /@|requested by|staff/i);
});

test("Saved Items use the most specific identity, matching the search key", () => {
  assert.deepEqual(
    savedIdentityFor({
      productId: uuid(1),
      catalogVendorProductId: uuid(2),
      inventoryItemId: uuid(3),
    }),
    { productId: uuid(1), catalogVendorProductId: null, inventoryItemId: null },
  );
  assert.deepEqual(
    savedIdentityFor({
      productId: null,
      catalogVendorProductId: uuid(2),
      inventoryItemId: uuid(3),
    }),
    { productId: null, catalogVendorProductId: uuid(2), inventoryItemId: null },
  );
  assert.deepEqual(
    savedIdentityFor({ productId: null, catalogVendorProductId: null, inventoryItemId: uuid(3) }),
    { productId: null, catalogVendorProductId: null, inventoryItemId: uuid(3) },
  );
  assert.equal(
    savedIdentityFor({ productId: null, catalogVendorProductId: null, inventoryItemId: null }),
    null,
  );
  const product = item(1, { isSaved: true });
  assert.equal(effectiveSaved(product, new Map()), true);
  assert.equal(effectiveSaved(product, new Map([[product.resultId, false]])), false);
});

test("discovery sections hold each product once, in section order", () => {
  const saved = item(1, { isSaved: true, approvedRequestCount: 5 });
  const frequent = item(2, { approvedRequestCount: 4 });
  const purchased = item(3, { purchaseCount: 1 });
  const sections = buildDiscoverySections([
    { ...purchased, section: "purchased" },
    { ...frequent, section: "frequent" },
    { ...saved, section: "frequent" },
    { ...saved, section: "saved" },
    { ...frequent, section: "purchased" },
  ]);
  assert.deepEqual(
    sections.saved.map((row) => row.resultId),
    [saved.resultId],
  );
  assert.deepEqual(
    sections.frequent.map((row) => row.resultId),
    [frequent.resultId],
  );
  assert.deepEqual(
    sections.purchased.map((row) => row.resultId),
    [purchased.resultId],
  );
  assert.ok(!("section" in sections.saved[0]!));
});

test("Request Supplies opens on Saved items, Frequently requested and Purchased before", () => {
  setStaff({
    "product-discovery": ready(sections),
    "request-context": ready({ teams: [], locations: [] }),
  });
  const html = ui.render(ui.Composer.options.component);
  assert.match(html, /What do you need\?/);
  const saved = html.indexOf("Saved items");
  const frequent = html.indexOf("Frequently requested</h3>");
  const purchased = html.indexOf("Purchased before</h3>");
  assert.ok(saved > 0 && saved < frequent && frequent < purchased, "sections in priority order");
  assert.ok(
    html.indexOf('placeholder="Search products or supplies…"') < saved,
    "search comes first",
  );
  // Saved shows four rows and expands in place; the count is visible.
  assert.match(html, /· 5/);
  assert.match(html, /Show all 5/);
  assert.match(html, /aria-label="Add Kinesiology Tape"/);
  assert.doesNotMatch(html, /aria-label="Add Heel Cups"/);
  // Save toggles are real buttons with state.
  assert.match(html, /aria-pressed="true" aria-label="Remove Prewrap Foam from saved items"/);
  assert.match(html, /aria-pressed="false" aria-label="Save Athletic Tape"/);
  // Same-name variants are distinguished; badges are quiet and organization-level.
  assert.match(html, /2&quot; x 15 yd · 24 roll/);
  assert.match(html, /3&quot; x 15 yd · 24 roll/);
  assert.match(html, /data-badge="frequent"[^>]*>Frequently requested</);
  assert.match(html, /data-badge="approved"[^>]*>Approved 2 times/);
  assert.match(html, /data-badge="purchased"[^>]*>Purchased Nov 1/);
  assert.doesNotMatch(
    html,
    /Requested \d+ times|Recent<\/h3>/,
    "personal quick picks are not on this page",
  );
  assert.doesNotMatch(html, /type="submit"/);
});

test("discovery loading, error and empty states", () => {
  setStaff({ "product-discovery": { isLoading: true } });
  assert.match(ui.render(ui.Composer.options.component), /aria-label="Loading your items"/);
  setStaff({ "product-discovery": { isError: true } });
  const failed = ui.render(ui.Composer.options.component);
  assert.match(failed, /We couldn&#x27;t load your saved items\./);
  assert.match(failed, /Try again/);
  setStaff({ "product-discovery": ready({ saved: [], frequent: [], purchased: [] }) });
  const empty = ui.render(ui.Composer.options.component);
  assert.match(empty, /Tap the bookmark on any item to save it here/);
  assert.match(empty, /Can&#x27;t find the item\?/);
});

test("an item in the cart shows its quantity in discovery", () => {
  setStaff({ "product-discovery": ready(sections) });
  const inCart = createStructuredCartItem("k", sections.frequent[0]!, 2);
  const html = ui.render(ui.Composer.options.component, { items: [inCart] });
  assert.match(html, /aria-label="Athletic Tape quantity 2"/);
});

test("search results show variant lines, badges and the save control", () => {
  const noop = () => {};
  const saved = {
    isSaved: (product: StaffDiscoveryProduct) =>
      product.resultId === sections.frequent[1]!.resultId,
    isPending: () => false,
    toggle: noop,
    error: null,
  };
  const results = [
    item(21, { variantDetail: '2" x 15 yd', approvedRequestCount: 9, matchTier: 2 }),
    item(22, { variantDetail: '3" x 15 yd', packageDisplay: "16 roll", matchTier: 2 }),
    item(23, { productName: "Tape Athletic Bulk Pack", matchTier: 5, purchaseCount: 1 }),
  ];
  const html = ui.render(() =>
    ui.StaffProductPicker({
      inputId: "s",
      label: "Search supplies",
      query: "athletic tape",
      onQueryChange: noop,
      onAddCustom: noop,
      cartItems: [],
      cartFull: false,
      onAddProduct: noop,
      onChangeQuantity: noop,
      onRemove: noop,
      search: { status: "results", results },
      saved,
    }),
  );
  assert.match(html, /aria-label="Search results"/);
  assert.ok(
    html.indexOf("2&quot; x 15 yd") < html.indexOf("3&quot; x 15 yd"),
    "database order kept",
  );
  assert.ok(html.indexOf("3&quot; x 15 yd") < html.indexOf("Tape Athletic Bulk Pack"));
  assert.match(html, /3&quot; x 15 yd · 16 roll/);
  assert.match(html, /aria-pressed="true" aria-label="Remove Athletic Tape from saved items"/);
  assert.match(html, /data-badge="purchased"/);
  assert.match(html, /overflow-wrap:anywhere/);
  // Without saved controls (the workspace) there is no save button.
  const workspace = ui.render(() =>
    ui.StaffProductPicker({
      inputId: "s",
      label: "Search supplies",
      query: "athletic tape",
      onQueryChange: noop,
      onAddCustom: noop,
      cartItems: [],
      cartFull: false,
      onAddProduct: noop,
      onChangeQuantity: noop,
      onRemove: noop,
      search: { status: "results", results },
    }),
  );
  assert.doesNotMatch(workspace, /aria-pressed/);
  assert.match(workspace, /aria-label="Add Tape Athletic Bulk Pack"/);
});

test("the staff workspace keeps its personal quick picks", () => {
  setStaff({
    requests: ready({
      summary: {},
      openRequests: [],
      pastRequests: [],
      hasMorePastRequests: false,
    }),
    "quick-picks": ready({ frequent: [], recent: [] }),
    "product-discovery": ready(sections),
  });
  const html = ui.render(ui.Workspace.options.component);
  assert.match(html, /Items you request will show up here/);
  assert.doesNotMatch(html, /Saved items|Purchased before/);
});

// ---------------------------------------------------------------------------
// Structure: migration, server functions, authorization surface
// ---------------------------------------------------------------------------

const migration = read("supabase/migrations/20261107120000_phase5a10_staff_product_discovery.sql");

test("the migration is additive, AI-free and keeps the legacy search contract", () => {
  assert.match(migration, /^-- Phase 5A\.10/);
  assert.equal(migration.match(/^BEGIN;$/gm)?.length, 1);
  assert.equal(migration.match(/^COMMIT;$/gm)?.length, 1);
  assert.doesNotMatch(
    migration,
    /CREATE TEMP|DROP TABLE|DROP FUNCTION|ALTER TABLE public\.(?!catalog_vendor_product_search_documents|catalog_search_terms|staff_saved_products)/,
  );
  const sqlOnly = migration.replace(/--.*$/gm, "");
  assert.doesNotMatch(
    sqlOnly,
    /embedding|vector|openai|anthropic|\bllm\b|http_(get|post)|\bnet\./i,
  );
  assert.match(migration, /CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;/);
  // The legacy RPC keeps its exact signature and 12 columns.
  const legacy = migration.match(
    /CREATE OR REPLACE FUNCTION public\.search_supply_request_products\([\s\S]*?\n\$\$;/,
  )?.[0];
  assert.ok(legacy);
  assert.match(legacy, /_limit integer DEFAULT 20/);
  assert.equal(
    legacy.match(/^\s{2}[a-z_]+ (text|uuid),?$/gm)?.length,
    14,
    "uuid + text args and 12 columns",
  );
  assert.doesNotMatch(legacy, /match_tier|is_saved/);
});

test("every new function is SECURITY DEFINER with a fixed search_path and explicit grants", () => {
  const functions = [...migration.matchAll(/CREATE OR REPLACE FUNCTION public\.([a-z_]+)\(/g)].map(
    (m) => m[1]!,
  );
  assert.equal(functions.length, 17);
  for (const name of functions) {
    const block = migration.slice(migration.indexOf(`FUNCTION public.${name}(`));
    const header = block.slice(0, block.indexOf("AS $$"));
    if (name === "catalog_search_text") {
      // Inlinable on purpose: no SET clause, every call schema-qualified, no SECURITY DEFINER.
      assert.doesNotMatch(header, /^(SET |SECURITY DEFINER)/m);
      const body = block.slice(block.indexOf("AS $$"), block.indexOf("\n$$;"));
      assert.ok(
        [...body.matchAll(/\b([a-z_]+)\(/g)].every(
          (m) => ["pg_catalog", "COALESCE"].includes(m[1]!) || body.includes(`pg_catalog.${m[1]}(`),
        ),
      );
    } else {
      assert.match(header, /SET search_path = public/, name);
    }
    assert.match(
      migration,
      new RegExp(`REVOKE ALL ON FUNCTION public\\.${name}\\(`),
      `${name} revokes PUBLIC`,
    );
  }
  const clientCallable = [
    "search_supply_request_products",
    "search_supply_request_products_with_signals",
    "get_staff_product_discovery",
    "save_staff_product",
    "remove_staff_saved_product",
  ];
  for (const name of functions) {
    const granted = new RegExp(
      `GRANT EXECUTE ON FUNCTION public\\.${name}\\([^)]*\\) TO authenticated;`,
    ).test(migration);
    assert.equal(granted, clientCallable.includes(name), `${name} client grant`);
  }
  assert.doesNotMatch(migration, /TO anon/);
  for (const table of [
    "staff_saved_products",
    "catalog_vendor_product_search_documents",
    "catalog_search_terms",
  ]) {
    assert.match(migration, new RegExp(`ALTER TABLE public\\.${table} ENABLE ROW LEVEL SECURITY;`));
    assert.match(
      migration,
      new RegExp(
        `REVOKE ALL ON TABLE public\\.${table} FROM PUBLIC, anon, authenticated, service_role;`,
      ),
    );
    assert.doesNotMatch(migration, new RegExp(`CREATE POLICY [\\s\\S]*? ON public\\.${table}`));
  }
  assert.match(
    migration,
    /CONSTRAINT staff_saved_products_user_identity_uq UNIQUE \(organization_id, user_id, identity_key\)/,
  );
  assert.match(
    migration,
    /num_nonnulls\(product_id, catalog_vendor_product_id, inventory_item_id\) = 1/,
  );
});

test("ranking is tiered first; history and Saved only order rows inside a tier", () => {
  const search = migration.slice(
    migration.indexOf("FUNCTION public.supply_request_product_search("),
  );
  const order = search.slice(
    search.indexOf("  ORDER BY\n    matched.match_rank"),
    search.indexOf("LIMIT _bounded_limit"),
  );
  const position = (text: string) => {
    const at = order.indexOf(text);
    assert.notEqual(at, -1, text);
    return at;
  };
  assert.ok(position("matched.match_rank") < position("(saved.identity_key IS NOT NULL) DESC"));
  assert.ok(
    position("(saved.identity_key IS NOT NULL) DESC") < position("approved_count, 0) DESC"),
  );
  assert.ok(position("approved_count, 0) DESC") < position("purchase_count, 0) DESC"));
  assert.ok(position("purchase_count, 0) DESC") < position("matched.source_priority"));
  // Approved means approved and still standing; never denied, cancelled or pending.
  assert.match(migration, /request\.status IN \('approved', 'ordered', 'received', 'completed'\)/);
  assert.match(
    migration,
    /invoice\.posted_at IS NOT NULL\n\s+AND invoice\.document_type <> 'CREDIT_MEMO'/,
  );
  // Organization-level history never returns who requested.
  const history = migration.slice(
    migration.indexOf("FUNCTION public.supply_request_product_history("),
    migration.indexOf("REVOKE ALL ON FUNCTION public.supply_request_product_history"),
  );
  assert.doesNotMatch(history, /requested_by|author_id|reviewed_by|full_name|email/);
});

test("server functions only call the narrow RPCs and never touch requests, budgets or tables", () => {
  const server =
    read("src/lib/product-discovery.functions.ts") + read("src/supply-requests/discovery-reads.ts");
  assert.doesNotMatch(server, /\.from\(/);
  for (const rpc of [
    "search_supply_request_products_with_signals",
    "get_staff_product_discovery",
    "save_staff_product",
    "remove_staff_saved_product",
    "get_supply_request_product_specifications",
  ]) {
    assert.match(server, new RegExp(`"${rpc}"`));
  }
  const ui = [
    server,
    read("src/components/staff/StaffDiscoveryList.tsx"),
    read("src/components/staff/useStaffProductSearch.ts"),
    read("src/supply-requests/product-discovery.ts"),
  ].join("\n");
  assert.doesNotMatch(
    ui,
    /submit_supply_request|submitSupplyRequestFn|commitment|budget|decide_supply_request|cancel_supply_request|inventory_adjust/i,
  );
  assert.match(server, /requireMembership\(context, data\.organizationId\)/);
  // Request submission is unchanged.
  const route = read("src/routes/_authenticated/staff/request.tsx");
  assert.match(
    route,
    /submitFn\(\{\n\s+data: \{\n\s+organizationId: active!\.organizationId,\n\s+requestType: resolveStaffRequestType\(routeSearch\.type, items\),\n\s+items: items\.map\(toSubmissionItem\),/,
  );
});

test("behavior, mutation, integration and release artifacts exist and are disposable-only", () => {
  const behavior = read("supabase/tests/phase5a10_staff_product_discovery_behavior.sql");
  assert.match(behavior, /^--[\s\S]*?\nBEGIN;/);
  assert.equal(behavior.match(/^ROLLBACK;$/gm)?.length, 1);
  assert.doesNotMatch(behavior, /^COMMIT;/m);
  const mutation = read("supabase/tests/phase5a10_mutation_check.sh");
  assert.match(mutation, /Disposable databases only: never point this at production\./);
  assert.ok((mutation.match(/^ {2}"[^"]+\|/gm)?.length ?? 0) >= 40, "at least 40 mutants");
  for (const name of [
    "exact catalog SKU loses priority",
    "approval history overpowers relevance",
    "search reads Saved Items from every organization",
    "denied requests count as approved",
    "purchase history from every organization",
    "remove deletes another user's Saved Item",
  ]) {
    assert.match(mutation, new RegExp(`"${name}\\|`));
  }
  for (const file of ["precheck.sql", "postcheck.sql", "fingerprint.sql", "README.md"]) {
    assert.ok(existsSync(join(root, "supabase/release/phase5a10", file)), file);
  }
  const fingerprint = read("supabase/release/phase5a10/fingerprint.sql").trim();
  for (const file of ["precheck.sql", "postcheck.sql"]) {
    const text = read(`supabase/release/phase5a10/${file}`);
    assert.ok(
      text.trimEnd().endsWith(fingerprint.slice(fingerprint.indexOf("SELECT section"))),
      `${file} ends with the fingerprint`,
    );
    // Read-only: no writes or transaction control (the DO block's own BEGIN/END aside);
    // phase5a10_release_check.sh also runs every file with default_transaction_read_only=on.
    assert.doesNotMatch(
      text,
      /^\s*(INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|GRANT|REVOKE|COMMIT|ROLLBACK)\b|^\s*BEGIN;/im,
    );
  }
});

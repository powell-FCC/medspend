// Staff Workspace v2: requester-scoped quick picks, request-again availability, the
// shared cart, plain-language statuses, server-side scoping, and rendered states.
//
// Rendered tests bundle the real staff routes and components with esbuild. Only the
// framework seams are stubbed (router, react-query, server-function transport, auth and
// active organization); packages resolve from the repo's node_modules.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { SUPPLY_REQUEST_STATUSES } from "../src/supply-requests/lifecycle.ts";
import {
  STAFF_OPEN_STATUSES,
  STAFF_PAST_STATUSES,
  describeRequestContents,
  translateStaffRequestStatus,
} from "../src/supply-requests/staff-dashboard.ts";
import {
  STAFF_CART_MAX_LINES,
  addProductToCart,
  cartItemFromRequestItem,
  createStructuredCartItem,
  describeCartCount,
  findCartLineForSelection,
  toSubmissionItem,
  type StaffProductSelection,
} from "../src/supply-requests/staff-request-cart.ts";
import {
  QUICK_PICK_LIMIT,
  buildQuickPicks,
  buildRequestAgainLines,
  classifyLineAvailability,
  quickPickKey,
  type AvailabilityLookups,
  type CatalogAvailabilityRow,
  type ProductAvailabilityRow,
  type RequestHistoryLine,
} from "../src/supply-requests/staff-workspace.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const between = (source: string, start: string, end: string) => {
  const from = source.indexOf(start);
  assert.notEqual(from, -1, start);
  const to = source.indexOf(end, from + start.length);
  return source.slice(from, to === -1 ? undefined : to);
};

const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

// Bundle the staff UI before any test is registered, so cleanup cannot race the build.
const cacheDir = join(root, "node_modules/.cache/staff-workspace-v2-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));

const stubs: Record<string, string> = {
  "@tanstack/react-router": `
    import { createElement } from "react";
    const t = () => globalThis.__staff;
    export const createFileRoute = () => (options) => ({ options, useParams: () => t().params });
    export const Link = ({ to, params, search, children, activeProps, ...rest }) =>
      createElement("a", { ...rest, href: String(to).replace("$id", params?.id ?? ""), "data-search": JSON.stringify(search ?? {}) }, children);
    export const Outlet = () => createElement("div", { "data-outlet": true });
    export const useSearch = () => t().search;
    export const useNavigate = () => (target) => { t().navigations.push(target); };
    export const useRouter = () => ({ navigate: () => {} });
    export const useRouterState = ({ select }) => select({ location: { pathname: t().path } });
    export const useMatch = () => t().match ?? undefined;`,
  "@tanstack/react-query": `
    export const keepPreviousData = (value) => value;
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
  "@/hooks/use-auth": `export const useAuth = () => ({ user: { user_metadata: { full_name: "Jordan Lee" } } });`,
};

function resolveSource(base: string) {
  for (const candidate of [base, `${base}.ts`, `${base}.tsx`, join(base, "index.ts")]) {
    if (existsSync(candidate) && !candidate.endsWith("/")) {
      try {
        if (readFileSync(candidate)) return candidate;
      } catch {
        // directory
      }
    }
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
  export { Route as Workspace } from "@/routes/_authenticated/staff/index";
  export { Route as Composer } from "@/routes/_authenticated/staff/request";
  export { Route as History } from "@/routes/_authenticated/staff/requests";
  export { Route as Detail } from "@/routes/_authenticated/staff/requests.$id";
  export { StaffAppShell } from "@/components/app/StaffAppShell";
  export { StaffProductPicker, StaffQuickPicks } from "@/components/staff/StaffProductPicker";
  export { StaffCartList } from "@/components/staff/StaffCartList";
  export { RequestSummaryCard } from "@/components/staff/RequestSummaryCard";
  export function render(Component, { items } = {}) {
    return renderToStaticMarkup(
      createElement(StaffCartProvider, { initialItems: items }, createElement(Component)),
    );
  }
  `,
);
const bundlePath = join(cacheDir, "bundle.cjs");
await build({
  entryPoints: [entry],
  bundle: true,
  // CommonJS output so external CommonJS packages (react/jsx-runtime) load as-is.
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

function product(
  n: number,
  overrides: Partial<ProductAvailabilityRow> = {},
): ProductAvailabilityRow {
  return {
    id: uuid(n),
    name: `Product ${n}`,
    unit_of_measure: "box",
    manufacturer: "Acme",
    pack_size: null,
    active: true,
    staff_requestable: true,
    ...overrides,
  };
}

function catalogRow(
  n: number,
  overrides: Partial<CatalogAvailabilityRow> = {},
): CatalogAvailabilityRow {
  return {
    id: uuid(n),
    active: true,
    discontinued: false,
    vendor_sku: `SKU-${n}`,
    package_status: "verified",
    package_quantity: 12,
    package_unit: "rolls",
    package_description: null,
    product: { name: `Catalog ${n}`, manufacturer: "Global Co", active: true },
    vendor: { name: "Global Vendor", active: true },
    ...overrides,
  };
}

function lookups(
  parts: Partial<{
    products: ProductAvailabilityRow[];
    inventory: Array<{ id: string; name: string }>;
    catalog: CatalogAvailabilityRow[];
  }> = {},
): AvailabilityLookups {
  return {
    products: new Map((parts.products ?? []).map((row) => [row.id, row])),
    inventory: new Map(
      (parts.inventory ?? []).map((row) => [
        row.id,
        { unit: "each", manufacturer: null, vendor_name: null, sku: null, ...row },
      ]),
    ),
    catalog: new Map((parts.catalog ?? []).map((row) => [row.id, row])),
    specifications: new Map(),
  };
}

function line(
  requestNumber: number,
  identity: Partial<RequestHistoryLine>,
  day = requestNumber,
): RequestHistoryLine {
  return {
    requestId: uuid(9000 + requestNumber),
    requestedAt: `2026-10-${String(day).padStart(2, "0")}T12:00:00Z`,
    productId: null,
    inventoryItemId: null,
    vendorProductId: null,
    catalogVendorProductId: null,
    freeTextItem: null,
    quantity: 1,
    unit: null,
    ...identity,
  };
}

// ---------------------------------------------------------------------------
// Product discovery: Frequent / Recent

test("frequent ranks by number of requests, not quantity, and recent never repeats it", () => {
  const products = [product(1), product(2), product(3)];
  const history = [
    // Product 1: two requests, tiny quantities.
    line(1, { productId: uuid(1), quantity: 1 }),
    line(2, { productId: uuid(1), quantity: 1 }),
    // Product 2: one request with a huge quantity.
    line(3, { productId: uuid(2), quantity: 500 }),
    // Product 3: most recent, once.
    line(4, { productId: uuid(3) }),
    // Duplicate line of product 1 inside one request counts once.
    line(2, { productId: uuid(1), quantity: 9 }),
  ];
  const picks = buildQuickPicks(history, lookups({ products }));
  assert.deepEqual(
    picks.frequent.map((pick) => [pick.productName, pick.requestCount]),
    [["Product 1", 2]],
  );
  assert.deepEqual(
    picks.recent.map((pick) => pick.productName),
    ["Product 3", "Product 2"],
  );
  const shown = [...picks.frequent, ...picks.recent].map((pick) => pick.key);
  assert.equal(new Set(shown).size, shown.length, "no product appears twice");
});

test("one product requested through different sources appears once", () => {
  const products = [product(1)];
  const history = [
    line(1, { productId: uuid(1), inventoryItemId: uuid(50) }),
    line(2, { productId: uuid(1), vendorProductId: uuid(60) }),
  ];
  const picks = buildQuickPicks(
    history,
    lookups({ products, inventory: [{ id: uuid(50), name: "Bin item" }] }),
  );
  assert.equal(picks.frequent.length, 1);
  assert.equal(picks.recent.length, 0);
  // The tuple offered is the most recent request's stored identity, unchanged.
  assert.equal(picks.frequent[0].vendorProductId, uuid(60));
  assert.equal(picks.frequent[0].inventoryItemId, null);
});

test("inactive, non-requestable, discontinued and custom items are never offered", () => {
  const history = [
    line(1, { productId: uuid(1) }),
    line(2, { productId: uuid(2) }),
    line(3, { productId: uuid(3) }),
    line(4, { catalogVendorProductId: uuid(4) }),
    line(5, { catalogVendorProductId: uuid(5) }),
    line(6, { inventoryItemId: uuid(6) }),
    line(7, { freeTextItem: "Something custom" }),
    line(8, { productId: uuid(8) }),
  ];
  const picks = buildQuickPicks(
    history,
    lookups({
      products: [
        product(1, { active: false }),
        product(2, { staff_requestable: false }),
        // product 3 is not visible at all (other organization / RLS)
        product(8),
      ],
      catalog: [
        catalogRow(4, { discontinued: true }),
        catalogRow(5, { vendor: { name: "Gone", active: false } }),
      ],
      // inventory 6 is inactive, so row-level security does not return it
    }),
  );
  assert.deepEqual(
    [...picks.frequent, ...picks.recent].map((pick) => pick.productName),
    ["Product 8"],
  );
});

test("quick picks are bounded", () => {
  const products = Array.from({ length: 20 }, (_, index) => product(index + 1));
  const history = products.map((row, index) =>
    line(index + 1, { productId: row.id }, 1 + (index % 28)),
  );
  const picks = buildQuickPicks(history, lookups({ products }));
  assert.equal(picks.recent.length, QUICK_PICK_LIMIT);
  assert.equal(picks.frequent.length, 0);
});

test("quick-pick identity key matches the search deduplication key", () => {
  assert.equal(
    quickPickKey({
      productId: uuid(1),
      inventoryItemId: uuid(2),
      vendorProductId: null,
      catalogVendorProductId: uuid(3),
    }),
    `organization-product:${uuid(1)}`,
  );
  assert.equal(
    quickPickKey({
      productId: null,
      inventoryItemId: null,
      vendorProductId: null,
      catalogVendorProductId: uuid(3),
    }),
    `catalog-vendor-product:${uuid(3)}`,
  );
  assert.equal(
    quickPickKey({
      productId: null,
      inventoryItemId: uuid(2),
      vendorProductId: null,
      catalogVendorProductId: null,
    }),
    `inventory:${uuid(2)}`,
  );
  assert.equal(
    quickPickKey({
      productId: null,
      inventoryItemId: null,
      vendorProductId: null,
      catalogVendorProductId: null,
    }),
    null,
  );
  const search = read(
    "supabase/migrations/20260911120000_phase5a8b_catalog_specification_search.sql",
  );
  assert.match(search, /'organization-product:' \|\| adoption\.product_id::text/);
  assert.match(search, /'catalog-vendor-product:' \|\| catalog_vendor_product\.id::text/);
  assert.match(search, /'inventory:' \|\| inventory\.id::text/);
});

// ---------------------------------------------------------------------------
// Request again

test("request again copies available lines with their stored identity and lists the rest", () => {
  const items = [
    {
      id: "a",
      productId: uuid(1),
      inventoryItemId: uuid(50),
      vendorProductId: null,
      catalogVendorProductId: null,
      name: "Tape",
      quantity: 4,
      unit: "roll",
    },
    {
      id: "b",
      productId: uuid(2),
      inventoryItemId: null,
      vendorProductId: null,
      catalogVendorProductId: null,
      name: "Old gauze",
      quantity: 2,
      unit: null,
    },
    {
      id: "c",
      productId: null,
      inventoryItemId: null,
      vendorProductId: null,
      catalogVendorProductId: null,
      name: "Ankle brace XL",
      freeTextItem: "Ankle brace XL",
      quantity: 1,
      unit: null,
    },
  ];
  const lines = buildRequestAgainLines(
    items,
    lookups({
      products: [product(1), product(2, { active: false })],
      inventory: [{ id: uuid(50), name: "Tape bin" }],
    }),
  );
  assert.deepEqual(
    lines.map((entry) => entry.availability.status),
    ["available", "unavailable", "custom"],
  );
  assert.equal(lines[1].selection, null, "an unavailable line is never substituted");
  assert.equal(lines[2].freeTextItem, "Ankle brace XL");

  const cartLine = createStructuredCartItem("k", lines[0].selection!, lines[0].quantity);
  assert.deepEqual(toSubmissionItem(cartLine), {
    productId: uuid(1),
    inventoryItemId: uuid(50),
    vendorProductId: null,
    catalogVendorProductId: null,
    freeTextItem: null,
    quantity: 4,
  });
  // Same identity tuple the Phase 6C edit path resubmits from a stored line.
  assert.deepEqual(toSubmissionItem(cartItemFromRequestItem(items[0])), toSubmissionItem(cartLine));
});

test("catalog availability follows the submission helper's catalog checks", () => {
  const identity = {
    productId: null,
    inventoryItemId: null,
    vendorProductId: null,
    catalogVendorProductId: uuid(4),
  };
  assert.equal(
    classifyLineAvailability(identity, lookups({ catalog: [catalogRow(4)] })).status,
    "available",
  );
  for (const row of [
    catalogRow(4, { active: false }),
    catalogRow(4, { discontinued: true }),
    catalogRow(4, { product: { name: "x", manufacturer: null, active: false } }),
    catalogRow(4, { vendor: [{ name: "x", active: false }] }),
  ]) {
    assert.equal(
      classifyLineAvailability(identity, lookups({ catalog: [row] })).status,
      "unavailable",
    );
  }
  const helper = read("supabase/migrations/20261009120000_phase6c_staff_request_forgiveness.sql");
  assert.match(
    helper,
    /catalog_vendor_product\.active = true\s+AND catalog_vendor_product\.discontinued = false/,
  );
  assert.match(helper, /AND staff_requestable = true/);
});

// ---------------------------------------------------------------------------
// Cart

const tape: StaffProductSelection = {
  productName: "Tape",
  manufacturer: null,
  vendorName: null,
  vendorSku: null,
  packageDisplay: "",
  specification: null,
  inventoryItemId: null,
  productId: uuid(1),
  vendorProductId: null,
  catalogVendorProductId: null,
};

test("adding the same product again increases quantity; a different identity is its own line", () => {
  let items = addProductToCart([], "one", tape);
  items = addProductToCart(items, "two", tape);
  assert.equal(items.length, 1);
  assert.equal(items[0].quantity, 2);
  items = addProductToCart(items, "three", { ...tape, vendorProductId: uuid(60) });
  assert.equal(items.length, 2, "a different source is never merged into another line");
  assert.equal(findCartLineForSelection(items, tape)?.quantity, 2);
  assert.equal(describeCartCount(items), "2 items");
  assert.equal(describeCartCount(items.slice(0, 1)), "1 item");
});

test("the cart stops at the submission limit instead of building an unsubmittable request", () => {
  let items = Array.from({ length: STAFF_CART_MAX_LINES }, (_, index) =>
    createStructuredCartItem(`k${index}`, { ...tape, productId: uuid(100 + index) }, 1),
  );
  items = addProductToCart(items, "extra", { ...tape, productId: uuid(999) });
  assert.equal(items.length, STAFF_CART_MAX_LINES);
  const validation = read("src/supply-requests/validation.ts");
  assert.match(validation, /items: z\.array\(supplyRequestItemSchema\)\.min\(1\)\.max\(50\)/);
});

// ---------------------------------------------------------------------------
// Statuses

test("every canonical status has one plain-language label that keeps its meaning", () => {
  const expected = {
    submitted: ["Submitted", "Waiting for review", "ACTIVE"],
    under_review: ["Under review", "Being reviewed", "ACTIVE"],
    approved: ["Approved", "Approved, not yet ordered", "ACTIVE"],
    ordered: ["Ordered", "Ordered, waiting for delivery", "ACTIVE"],
    received: ["Ready", "Received and ready for you", "READY"],
    completed: ["Completed", "Request completed", "COMPLETED"],
    denied: ["Declined", "This request was declined", "DECLINED"],
  } as const;
  for (const status of SUPPLY_REQUEST_STATUSES) {
    const result = translateStaffRequestStatus(status);
    assert.deepEqual([result.label, result.description, result.group], expected[status], status);
  }
  // The admin queue already calls 'received' "Ready for Staff".
  assert.match(
    read("src/supply-requests/admin-dashboard.ts"),
    /received: \{ queueGroup: "READY_FOR_STAFF", statusLabel: "Ready for Staff"/,
  );
  assert.deepEqual(
    [...STAFF_OPEN_STATUSES, ...STAFF_PAST_STATUSES].sort(),
    [...SUPPLY_REQUEST_STATUSES].sort(),
    "open and past partition the lifecycle exactly",
  );
});

test("request contents are summarized for cards", () => {
  assert.equal(describeRequestContents([]), "No items");
  assert.equal(describeRequestContents([{ name: "Tape" }]), "Tape");
  assert.equal(describeRequestContents([{ name: "Tape" }, { name: "Gauze" }]), "Tape, Gauze");
  assert.equal(
    describeRequestContents([
      { name: "Tape" },
      { name: "Gauze" },
      { name: "Ice" },
      { name: "Wrap" },
    ]),
    "Tape, Gauze and 2 more",
  );
});

// ---------------------------------------------------------------------------
// Server-side scoping and authorization (source contracts)

const workspaceServer = read("src/lib/staff-workspace.functions.ts");
const requestServer = read("src/lib/supply-requests.functions.ts");

test("quick picks read only the requester's own bounded, organization-scoped history", () => {
  const fn = between(
    workspaceServer,
    "export const getStaffQuickPicksFn",
    "export const getStaffRequestAgainFn",
  );
  assert.match(fn, /requireMembership\(context, data\.organizationId\)/);
  assert.match(
    fn,
    /\.eq\("organization_id", data\.organizationId\)\s+\.eq\("requested_by", context\.userId\)/,
  );
  assert.match(fn, /\.neq\("status", "denied"\)/);
  assert.match(fn, /\.limit\(QUICK_PICK_HISTORY_REQUESTS\)/);
  assert.match(
    fn,
    /from\("supply_request_items"\)[\s\S]*\.eq\("organization_id", data\.organizationId\)[\s\S]*\.in\("supply_request_id"/,
  );
  assert.match(fn, /\.is\("free_text_item", null\)/);
});

test("request again is owner-only, read-only and never submits", () => {
  const fn = between(workspaceServer, "export const getStaffRequestAgainFn", "\n});\n");
  assert.match(fn, /requireMembership\(context, data\.organizationId\)/);
  assert.match(
    fn,
    /\.eq\("id", data\.requestId\)\s+\.eq\("organization_id", data\.organizationId\)\s+\.eq\("requested_by", context\.userId\)/,
  );
  assert.match(fn, /if \(!row\) throw new Error\("Request not found"\)/);
  assert.doesNotMatch(
    workspaceServer,
    /\.insert\(|\.update\(|\.upsert\(|\.delete\(|rpc\("(?:submit|update_submitted|transition|decide)_supply_request/,
  );
  assert.doesNotMatch(workspaceServer, /internal_note|client\.server|SERVICE_ROLE/);
});

test("availability lookups stay inside the caller's organization and row-level security", () => {
  const lookup = between(
    workspaceServer,
    "async function loadAvailabilityLookups",
    "export const getStaffQuickPicksFn",
  );
  assert.match(lookup, /from\("products"\)[\s\S]*?\.eq\("organization_id", organizationId\)/);
  assert.match(
    lookup,
    /from\("inventory_items"\)[\s\S]*?\.eq\("organization_id", organizationId\)\s+\.eq\("active", true\)/,
  );
  assert.match(lookup, /rpc\("get_supply_request_product_specifications"/);
});

test("staff history is bounded and still requester-owned", () => {
  const dashboard = between(
    requestServer,
    "export const getStaffDashboardFn",
    "export const getStaffRequestDetailFn",
  );
  assert.equal((dashboard.match(/\.eq\("requested_by", context\.userId\)/g) ?? []).length, 2);
  assert.match(dashboard, /\.limit\(STAFF_OPEN_REQUEST_LIMIT\)/);
  assert.match(dashboard, /\.limit\(data\.pastLimit \+ 1\)/);
  assert.match(dashboard, /\.max\(STAFF_PAST_REQUEST_MAX\)/);
  // Items and staff-safe updates load once for the whole page, not per request.
  assert.equal((dashboard.match(/loadRequestItems\(/g) ?? []).length, 1);
  assert.equal((dashboard.match(/list_staff_supply_request_updates/g) ?? []).length, 1);
});

test("the staff timeline uses only stored events", () => {
  const detail = between(
    requestServer,
    "export const getStaffRequestDetailFn",
    "export const listOrgRequestsFn",
  );
  assert.match(detail, /\{ label: "Submitted", occurredAt: row\.created_at, message: null \}/);
  assert.match(detail, /if \(!update\.status_to\) return \[\];/);
  assert.doesNotMatch(detail, /ordered_at|received_at|new Date\(\)/);
});

test("staff routes reach no admin mutation, budget, purchasing or QR feature", () => {
  for (const path of [
    "src/routes/_authenticated/staff/index.tsx",
    "src/routes/_authenticated/staff/request.tsx",
    "src/routes/_authenticated/staff/requests.tsx",
    "src/routes/_authenticated/staff/requests.$id.tsx",
    "src/components/app/StaffAppShell.tsx",
    "src/components/staff/StaffProductPicker.tsx",
  ]) {
    const source = read(path).replace(/^\s*\/\/.*$/gm, "");
    assert.doesNotMatch(
      source,
      /decideSupplyRequestFn|updateRequestStatusFn|releaseSupplyRequestCommitmentFn|getSupplyRequestBudgetImpactFn|listOrgRequestsFn|getAdminSupplyRequestDashboardFn/,
      path,
    );
    assert.doesNotMatch(source, /\bQR\b|camera|getUserMedia|inventory adjustment/i, path);
    assert.doesNotMatch(source, /Needs attention/i, path);
  }
});

test("one canonical submission path: only the composer submits, through submitSupplyRequestFn", () => {
  const composer = read("src/routes/_authenticated/staff/request.tsx");
  assert.equal((composer.match(/submitFn\(/g) ?? []).length, 1);
  assert.match(composer, /useServerFn\(submitSupplyRequestFn\)/);
  for (const path of [
    "src/routes/_authenticated/staff/index.tsx",
    "src/routes/_authenticated/staff/requests.$id.tsx",
    "src/components/staff/StaffCartProvider.tsx",
    "src/components/staff/StaffProductPicker.tsx",
  ]) {
    assert.doesNotMatch(
      read(path),
      /submitSupplyRequestFn|updateSubmittedSupplyRequestFn|\.rpc\(/,
      path,
    );
  }
  // Request again only navigates to a new cart.
  const detail = read("src/routes/_authenticated/staff/requests.$id.tsx");
  assert.match(detail, /navigate\(\{ to: "\/staff\/request", search: \{ again: id \} \}\)/);
});

test("submission cannot fire twice and an empty cart cannot submit", () => {
  const composer = read("src/routes/_authenticated/staff/request.tsx");
  const confirm = between(
    composer,
    "async function confirmSubmit()",
    "async function saveChanges()",
  );
  assert.match(
    confirm,
    /if \(submitting\.current \|\| items\.length === 0\) return;\s+submitting\.current = true;/,
  );
  assert.match(confirm, /finally \{\s+submitting\.current = false;/);
  const submit = between(
    composer,
    "function submit(event: React.FormEvent)",
    "async function confirmSubmit()",
  );
  assert.match(submit, /if \(items\.length === 0 \|\| busy\) return;/);
  assert.match(composer, /disabled=\{busy \|\| !hasItems\}/);
});

test("the authenticated layout still sends owners and admins away from staff routes", () => {
  const layout = read("src/routes/_authenticated/route.tsx");
  assert.match(
    layout,
    /if \(isAdmin && pathname\.startsWith\("\/staff"\)\) \{\s+navigate\(\{ to: "\/dashboard", replace: true \}\);/,
  );
  assert.match(layout, /const STAFF_ROUTES = \["\/staff", "\/profile"\];/);
});

// ---------------------------------------------------------------------------
// Rendered states

const org = {
  id: "m-1",
  organizationId: uuid(1),
  role: "staff",
  defaultTeamId: uuid(201),
  defaultLocationId: uuid(301),
  organizationName: "Henry Athletics",
};

type QueryResult = Record<string, unknown>;
function setStaff(options: {
  path?: string;
  search?: Record<string, unknown>;
  params?: Record<string, string>;
  match?: unknown;
  queries?: Record<string, QueryResult>;
}) {
  const state = {
    path: options.path ?? "/staff",
    search: options.search ?? {},
    params: options.params ?? {},
    match: options.match,
    org,
    navigations: [] as unknown[],
    query: (key: unknown[]) => {
      const name = key.map(String).join(":");
      for (const [prefix, result] of Object.entries(options.queries ?? {})) {
        if (name.includes(prefix)) return result;
      }
      return {};
    },
  };
  (globalThis as { __staff?: unknown }).__staff = state;
  return state;
}

const ready = (data: unknown) => ({ data, isSuccess: true });

function request(
  n: number,
  status: Parameters<typeof translateStaffRequestStatus>[0],
  names: string[],
) {
  const translated = translateStaffRequestStatus(status);
  return {
    id: uuid(500 + n),
    itemCount: names.length,
    items: names.map((name, index) => ({
      id: `${n}-${index}`,
      productId: uuid(index + 1),
      inventoryItemId: null,
      vendorProductId: null,
      catalogVendorProductId: null,
      name,
      quantity: 1,
      unit: null,
    })),
    itemName: names.length === 1 ? names[0] : `${names.length} items`,
    quantity: null,
    unit: null,
    statusLabel: translated.label,
    statusDescription: translated.description,
    statusGroup: translated.group,
    submittedAt: "2026-10-17T15:00:00Z",
    lastUpdatedAt: "2026-10-18T15:00:00Z",
    staffMessage: null,
  };
}

const dashboard = (openRequests: unknown[], pastRequests: unknown[] = []) =>
  ready({ summary: {}, openRequests, pastRequests, hasMorePastRequests: false });

const pick = (n: number, count: number) => ({
  ...tape,
  productName: `Quick ${n}`,
  productId: uuid(700 + n),
  key: `organization-product:${uuid(700 + n)}`,
  unit: null,
  requestCount: count,
  lastRequestedAt: "2026-10-16T12:00:00Z",
});

test("staff workspace renders the request action, my requests and usual items", () => {
  setStaff({
    queries: {
      requests: dashboard([
        request(1, "received", ["Cold packs"]),
        request(2, "submitted", ["Tape", "Gauze", "Ice bags"]),
      ]),
      "quick-picks": ready({ frequent: [pick(1, 4)], recent: [pick(2, 1)] }),
    },
  });
  const html = ui.render(ui.Workspace.options.component);
  assert.match(html, /Good (morning|afternoon|evening), Jordan/);
  assert.match(html, /Henry Athletics/);
  assert.match(html, /Request Supplies/);
  assert.match(html, /placeholder="Search products or supplies…"/);
  assert.match(html, /Ready for you/);
  assert.match(html, /Received and ready for you/);
  assert.match(html, /My Requests/);
  assert.match(html, /Tape, Gauze and 1 more/);
  assert.match(html, /Requested Oct 17 · 3 items/);
  assert.match(html, /Frequent/);
  assert.match(html, /Requested 4 times/);
  assert.match(html, /Recent/);
  assert.match(html, /aria-label="Add Quick 1"/);
  assert.doesNotMatch(html, /Needs attention|Scan Inventory/i);
});

test("workspace loading, error and first-time empty states are visible", () => {
  setStaff({ queries: { requests: { isLoading: true }, "quick-picks": {} } });
  let html = ui.render(ui.Workspace.options.component);
  assert.match(html, /aria-label="Loading your requests"/);
  assert.match(html, /aria-label="Loading your items"/);

  setStaff({ queries: { requests: { isError: true }, "quick-picks": { isError: true } } });
  html = ui.render(ui.Workspace.options.component);
  assert.match(html, /We couldn&#x27;t load your requests\./);
  assert.match(html, /We couldn&#x27;t load your usual items\./);
  assert.match(html, /Try again/);

  setStaff({
    queries: { requests: dashboard([]), "quick-picks": ready({ frequent: [], recent: [] }) },
  });
  html = ui.render(ui.Workspace.options.component);
  assert.match(html, /No requests yet/);
  assert.match(html, /Items you request will show up here/);
});

test("an item already in the cart shows its quantity instead of Add", () => {
  setStaff({
    queries: {
      requests: dashboard([]),
      "quick-picks": ready({ frequent: [], recent: [pick(1, 1)] }),
    },
  });
  const inCart = createStructuredCartItem("k", pick(1, 1), 3);
  const html = ui.render(ui.Workspace.options.component, { items: [inCart] });
  assert.doesNotMatch(html, /aria-label="Add Quick 1"/);
  assert.match(html, /aria-label="Quick 1 quantity 3"/);
  assert.match(html, /aria-label="Increase Quick 1"/);
});

test("search shows loading, error, empty-with-custom fallback and results", () => {
  const noop = () => {};
  const base = {
    inputId: "s",
    label: "Search supplies",
    query: "zz",
    onQueryChange: noop,
    onAddCustom: noop,
    cartItems: [],
    cartFull: false,
    onAddProduct: noop,
    onChangeQuantity: noop,
    onRemove: noop,
  };
  const picker = (search: unknown) => ui.render(() => ui.StaffProductPicker({ ...base, search }));
  assert.match(picker({ status: "loading" }), /aria-label="Searching supplies"/);
  assert.match(picker({ status: "error", retry: noop }), /We couldn&#x27;t search supplies/);
  const empty = picker({ status: "empty" });
  assert.match(empty, /No matching supplies found\./);
  assert.match(empty, /Request “zz” as a custom item/);
  assert.match(picker({ status: "typing" }), /Searching after you pause/);
  const results = picker({
    status: "results",
    results: [
      {
        ...tape,
        resultId: "r1",
        identitySource: "organization_product",
        packageStatus: "unknown",
        productName: "Elastic tape 2 in × 5 yd — extra long name that must wrap on narrow phones",
      },
    ],
  });
  assert.match(results, /aria-label="Search results"/);
  assert.match(results, /extra long name that must wrap/);
  assert.match(results, /overflow-wrap:anywhere/);
  assert.match(picker({ status: "idle" }), /Can&#x27;t find the item\?/);
});

test("the composer shows a reviewable cart with a persistent submit action", () => {
  setStaff({
    path: "/staff/request",
    queries: {
      "quick-picks": ready({ frequent: [], recent: [] }),
      "request-context": ready({
        teams: [{ id: uuid(201), name: "Football" }],
        locations: [{ id: uuid(301), name: "Main" }],
      }),
    },
  });
  const items = Array.from({ length: 12 }, (_, index) =>
    createStructuredCartItem(
      `k${index}`,
      { ...tape, productId: uuid(800 + index), productName: `Item ${index}` },
      index + 1,
    ),
  );
  const html = ui.render(ui.Composer.options.component, { items });
  assert.match(html, /Review your request/);
  assert.match(html, /Your request · 12 items/);
  assert.match(html, /aria-label="Remove Item 0"/);
  assert.match(html, /Submit request · 12 items/);
  assert.match(html, /sticky bottom-/);
  assert.match(html, /Add a note/);
  assert.match(html, /Add more items/);
});

test("an empty composer opens on discovery, with no submit action", () => {
  setStaff({
    path: "/staff/request",
    queries: { "quick-picks": ready({ frequent: [], recent: [] }) },
  });
  const html = ui.render(ui.Composer.options.component);
  assert.match(html, /What do you need\?/);
  assert.doesNotMatch(html, /type="submit"/);
});

test("request again shows progress while copying and never submits on its own", () => {
  const state = setStaff({
    path: "/staff/request",
    search: { again: uuid(42) },
    queries: { "request-again": { isLoading: true } },
  });
  const html = ui.render(ui.Composer.options.component);
  assert.match(html, /Copying your items into a new request/);
  assert.deepEqual(state.navigations, []);
});

test("my requests separates open and past requests and pages older history", () => {
  setStaff({
    path: "/staff/requests",
    queries: {
      history: ready({
        summary: {},
        openRequests: [request(1, "under_review", ["Tape"]), request(2, "received", ["Ice"])],
        pastRequests: [request(3, "completed", ["Gauze"]), request(4, "denied", ["Brace"])],
        hasMorePastRequests: true,
      }),
    },
  });
  const html = ui.render(ui.History.options.component);
  assert.match(html, /In progress · 2/);
  assert.ok(html.indexOf("Ice") < html.indexOf("Tape"), "ready requests come first");
  assert.match(html, /Past requests/);
  assert.match(html, /This request was declined/);
  assert.match(html, /Show older requests/);

  setStaff({ path: "/staff/requests", queries: { history: dashboard([]) } });
  assert.match(ui.render(ui.History.options.component), /No requests yet/);
});

test("request detail shows items, note, history and safe actions without internal data", () => {
  const detail = {
    ...request(1, "submitted", ["Tape", "Custom splint"]),
    items: [
      {
        id: "a",
        productId: uuid(1),
        inventoryItemId: null,
        vendorProductId: null,
        catalogVendorProductId: null,
        name: "Tape",
        quantity: 3,
        unit: "roll",
        packageDisplay: "12 rolls",
      },
      {
        id: "b",
        productId: null,
        inventoryItemId: null,
        vendorProductId: null,
        catalogVendorProductId: null,
        name: "Custom splint",
        freeTextItem: "Custom splint",
        quantity: 1,
        unit: null,
      },
    ],
    timeline: [{ label: "Submitted", occurredAt: "2026-10-17T15:00:00Z", message: null }],
    lifecycleStatus: "submitted",
    canEdit: true,
    editGuidance: "You can make changes until this request enters review.",
    requestType: "reorder",
    teamId: uuid(201),
    locationId: uuid(301),
    notes: "For the away game",
    staffMessage: "We'll order Friday",
  };
  setStaff({
    path: `/staff/requests/${uuid(501)}`,
    params: { id: uuid(501) },
    queries: { requests: ready(detail) },
  });
  const html = ui.render(ui.Detail.options.component);
  assert.match(html, /Waiting for review/);
  assert.match(html, /× 3/);
  assert.match(html, /Custom item/);
  assert.match(html, /For the away game/);
  assert.match(html, /We&#x27;ll order Friday/);
  assert.match(html, /aria-label="Request history"/);
  assert.match(html, /Submitted<span[^>]*> · <\/span><time[^>]*>Oct 17<\/time>/);
  assert.match(html, /Edit request/);
  assert.match(html, /Request again/);
  assert.doesNotMatch(html, new RegExp(uuid(1)), "no internal identifiers in the page");
  assert.doesNotMatch(html, /internal|Admins only/i);
});

test("the staff shell keeps a review action docked above the navigation when the cart has items", () => {
  setStaff({ path: "/staff", queries: {} });
  const Shell = () => ui.StaffAppShell({ children: "page" });
  const empty = ui.render(Shell);
  assert.doesNotMatch(empty, /Review request/);
  // Items added from the workspace live in the shell's own provider.
  const source = read("src/components/app/StaffAppShell.tsx");
  assert.match(source, /<StaffCartProvider key=\{active\?\.organizationId \?\? "none"\}>/);
  assert.match(source, /items\.length > 0 && pathname !== "\/staff\/request"/);
  const bar = read("src/components/staff/StaffCartList.tsx");
  assert.match(bar, /bottom-\[calc\(4rem\+env\(safe-area-inset-bottom\)\)\]/);
  assert.match(bar, /Review request/);
});

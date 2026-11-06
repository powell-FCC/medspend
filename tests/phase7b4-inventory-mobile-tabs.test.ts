// Phase 7B.4 hotfix: the five top-level Inventory tabs are wider than a 375px phone, and the
// strip used to widen the whole page. This renders the FULL Inventory workspace page (page
// container, five-tab navigation, active tab) rather than only a tab's contents, and checks
// the layout contract that keeps the page inside the viewport: the tab list sits in a block
// container that is limited to the available width and scrolls on its own. Node cannot
// measure layout, so the pixel check (document width equals viewport width at 375–430px)
// is done in a browser against this same structure.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = fileURLToPath(new URL("../", import.meta.url));
const cacheDir = join(root, "node_modules/.cache/phase7b4-mobile-tabs-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));

// Only the data edges are stubbed: an owner's active organization, server functions that
// never resolve during a static render, and a plain link. The page, tabs and layout are real.
const stubs: Record<string, string> = {
  "@/hooks/use-active-org": `
    export const useActiveOrg = () => ({
      loading: false,
      active: { organizationId: "org-1", organizationName: "FC Test", role: globalThis.__role ?? "owner" },
    });`,
  "@tanstack/react-start": `
    export const useServerFn = (fn) => fn;
    // Other server-function modules the page's dialogs import compile against a chain that is
    // never called during a static render.
    const chain = () => new Proxy(() => new Promise(() => {}), { get: () => chain });
    export const createServerFn = chain, createMiddleware = chain;`,
  "@tanstack/react-router": `
    import { createElement } from "react";
    export const Link = ({ children, className }) => createElement("a", { className }, children);`,
  "@/lib/inventory-workspace.functions": `
    const pending = () => new Promise(() => {});
    export const getInventoryOverviewFn = pending, listCountHistoryFn = pending,
      listTransferHistoryFn = pending, listAdjustmentHistoryFn = pending,
      listWorkspaceLocationsFn = pending, listWorkspaceItemsFn = pending,
      listWorkspaceCategoriesFn = pending, getWorkspaceItemBalancesFn = pending,
      listWorkspaceLocationStockFn = pending, getWorkspaceLocationFn = pending;`,
  "@/lib/orgs.functions": `export const listOrgMembersFn = () => new Promise(() => {});`,
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
  import { InventoryWorkspacePage } from "@/components/inventory/workspace/InventoryWorkspacePage";
  export function renderPage(tab, role) {
    globalThis.__role = role;
    return renderToStaticMarkup(
      createElement(QueryClientProvider, { client: new QueryClient() },
        createElement(InventoryWorkspacePage, { tab, onTabChange: () => {} })));
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
      name: "mobile-tabs-stubs",
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
const { renderPage } = createRequire(import.meta.url)(bundlePath) as {
  renderPage: (tab: string, role: string) => string;
};

const classesOf = (html: string, marker: RegExp) => {
  const match = html.match(marker);
  assert.ok(match, `element ${marker} rendered`);
  return new Set((match[0].match(/class="([^"]*)"/)?.[1] ?? "").split(/\s+/));
};

test("the full Inventory page keeps its five-tab strip inside a width-limited scroller", () => {
  const html = renderPage("overview", "owner");
  // The real page shell rendered: container, heading, tabs and the Overview panel.
  assert.match(html, /<div class="mx-auto max-w-7xl px-5 py-8 sm:px-8" data-page="inventory">/);
  assert.match(html, />Inventory<\/h1>/);
  assert.match(html, /data-testid="inventory-overview"/);

  // The scroller is a block box limited to the available width that scrolls by itself...
  const scroller = classesOf(html, /<div[^>]*data-testid="inventory-tabs-scroller"[^>]*>/);
  assert.ok(scroller.has("max-w-full"), "limited to the available width");
  assert.ok(scroller.has("overflow-x-auto"), "scrolls horizontally on its own");
  for (const unsafe of [
    "inline-flex",
    "flex",
    "w-max",
    "min-w-max",
    "overflow-visible",
    "whitespace-nowrap",
  ])
    assert.ok(!scroller.has(unsafe), `the scroller must not size to its content (${unsafe})`);

  // ...and the tab list is its direct child, so nothing else can widen the page.
  const tablist = html.match(
    /<div[^>]*data-testid="inventory-tabs-scroller"[^>]*>\s*<div role="tablist"[^>]*>/,
  );
  assert.ok(tablist, "the tab list is the scroller's direct child");

  // One row of five readable tabs, in order, unabbreviated.
  const start = html.indexOf('data-testid="inventory-tabs-scroller"');
  const strip = html.slice(start, html.indexOf("</div>", html.indexOf('role="tablist"', start)));
  const tabs = [...strip.matchAll(/<button[^>]*role="tab"[^>]*>([^<]*)<\/button>/g)].map(
    (m) => m[1],
  );
  assert.deepEqual(tabs, ["Overview", "Items", "Locations", "Counts", "Activity"]);
  assert.match(
    tablist[0],
    /class="[^"]*inline-flex[^"]*h-9[^"]*"/,
    "one row, unchanged list styling",
  );
});

test("the active tab keeps its state and styling for every tab, owner and admin alike", () => {
  for (const role of ["owner", "admin"]) {
    for (const tab of ["overview", "items", "locations", "counts", "activity"]) {
      const html = renderPage(tab, role);
      // The top-level strip only (Activity holds its own Transfers | Adjustments tabs).
      const start = html.indexOf('data-testid="inventory-tabs-scroller"');
      const strip = html.slice(
        start,
        html.indexOf("</div>", html.indexOf('role="tablist"', start)),
      );
      const active = [...strip.matchAll(/<button[^>]*role="tab"[^>]*>[^<]*<\/button>/g)]
        .map((m) => m[0])
        .filter((button) => /aria-selected="true"/.test(button));
      assert.equal(active.length, 1, `${role}/${tab}: exactly one selected tab`);
      assert.match(active[0], /data-state="active"/);
      assert.match(active[0], /data-\[state=active\]:bg-background/, "active styling unchanged");
      assert.match(
        html,
        /data-testid="inventory-tabs-scroller"/,
        `${role}/${tab}: the scroller wraps the tabs on every tab`,
      );
    }
  }
});

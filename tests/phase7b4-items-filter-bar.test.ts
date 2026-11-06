// Phase 7B.4 hotfix: the Items filter row (search, category, status, Low Stock) needs about
// 784px as four fixed columns. Beside the 240px sidebar that only fits from xl (1280px); at
// 768–1023px it widened the whole page to ~1039px. This renders the real Items tab and checks
// the layout contract: phones stack, tablet widths use two flexible columns with search on its
// own row, and the rigid four-column grid starts at xl only. Node cannot measure layout, so
// the pixel check (document width equals viewport width at 375–1280px) is done in a browser.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const root = fileURLToPath(new URL("../", import.meta.url));
const cacheDir = join(root, "node_modules/.cache/phase7b4-items-filter-bar-test");
mkdirSync(cacheDir, { recursive: true });
after(() => rmSync(cacheDir, { recursive: true, force: true }));

// Only the data edges are stubbed: server functions that never resolve during a static render
// and a plain link. The Items tab and its filter bar are real.
const pending = "() => new Promise(() => {})";
const stubs: Record<string, string> = {
  "@tanstack/react-start": `
    export const useServerFn = (fn) => fn;
    const chain = () => new Proxy(() => new Promise(() => {}), { get: () => chain });
    export const createServerFn = chain, createMiddleware = chain;`,
  "@tanstack/react-router": `
    import { createElement } from "react";
    export const Link = ({ children, className }) => createElement("a", { className }, children);`,
  "@/lib/inventory-workspace.functions": `
    export const listWorkspaceItemsFn = ${pending}, listWorkspaceCategoriesFn = ${pending},
      getWorkspaceItemBalancesFn = ${pending}, listWorkspaceLocationsFn = ${pending};`,
  "@/lib/inventory.functions": `
    export const saveInventoryItemFn = ${pending}, setInventoryItemActiveFn = ${pending},
      saveInventoryCategoryFn = ${pending}, deleteInventoryCategoryFn = ${pending},
      adjustInventoryQuantityFn = ${pending}, moveInventoryStockFn = ${pending};`,
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
  import { ItemsTab } from "@/components/inventory/workspace/ItemsTab";
  export function renderItems(canManage) {
    return renderToStaticMarkup(
      createElement(QueryClientProvider, { client: new QueryClient() },
        createElement(ItemsTab, { organizationId: "org-1", canManage })));
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
      name: "items-filter-stubs",
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
const { renderItems } = createRequire(import.meta.url)(bundlePath) as {
  renderItems: (canManage: boolean) => string;
};

const classList = (tag: string) => (tag.match(/class="([^"]*)"/)?.[1] ?? "").split(/\s+/);

test("tablet widths never use the rigid four-column filter grid; it starts at xl", () => {
  for (const canManage of [true, false]) {
    const html = renderItems(canManage);
    const open = html.match(/<div[^>]*data-testid="items-filter-bar"[^>]*>/);
    assert.ok(open, "the Items filter bar rendered");
    const classes = classList(open[0]);
    assert.ok(classes.includes("grid"), "a grid");
    // Phones: one column (no unprefixed column template). Tablets: two flexible columns.
    assert.ok(!classes.some((c) => c.startsWith("grid-cols-")), "phones stay one column");
    assert.ok(classes.includes("sm:grid-cols-2"), "two columns from sm");
    // Any template with fixed-width tracks (the ~784px four-column row) only from xl.
    const templates = classes.filter((c) => /(^|:)grid-cols-/.test(c));
    for (const template of templates)
      if (template !== "sm:grid-cols-2")
        assert.match(template, /^xl:/, `${template} must not apply below xl (1280px)`);
    assert.ok(
      templates.includes("xl:grid-cols-[minmax(240px,1fr)_200px_160px_auto]"),
      "the desktop four-column layout is unchanged",
    );

    // Search takes a full row until xl; the other three filters follow it.
    const searchBox = html.slice(html.indexOf(open[0]) + open[0].length).match(/^<div[^>]*>/)?.[0];
    assert.ok(searchBox, "search is the bar's first child");
    const search = classList(searchBox);
    assert.ok(search.includes("sm:col-span-2") && search.includes("xl:col-span-1"));
    const bar = html.slice(html.indexOf(open[0]), html.indexOf("Low Stock") + 40);
    for (const control of [
      /aria-label="Search inventory"/,
      /aria-label="Category filter"/,
      /aria-label="Status filter"/,
      /type="checkbox"[^>]*\/?>Low Stock/,
    ])
      assert.match(bar, control);
    // Filter controls keep their own sizing; nothing forces a fixed width.
    assert.doesNotMatch(bar, /\b(w-\[\d+px\]|min-w-\[\d+px\])/);
  }
});

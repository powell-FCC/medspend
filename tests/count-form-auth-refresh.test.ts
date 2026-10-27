// Regression test: an open inventory count must survive an auth refresh. Phase 7A.2
// production acceptance found the count page restarting itself when a hidden tab became
// visible again: supabase-js sends SIGNED_IN as it recovers the same session, the root
// listener invalidated every query, and the count form was rebuilt from the newest versions.
// Staff entries vanished, and a save after stock moved mid-count was no longer stale.
//
// The real modules are bundled with esbuild and server-rendered. Only their imports are
// stubbed; React's useState keeps its values between renders here (a render-phase update
// renders again, as React does) and effects run during render, so state and subscriptions
// are observable without a DOM.
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build, type Plugin } from "esbuild";

const root = fileURLToPath(new URL("../", import.meta.url));
const work = mkdtempSync(join(tmpdir(), "count-auth-refresh-"));
after(() => rmSync(work, { recursive: true, force: true }));

const reactStub = `
  export * from "react-real";
  export const useEffect = (effect) => { effect(); };
  export const useState = (initial) => {
    const hooks = globalThis.__hooks;
    const index = hooks.index++;
    if (!(index in hooks.values)) hooks.values[index] = typeof initial === "function" ? initial() : initial;
    const set = (update) => {
      const value = typeof update === "function" ? update(hooks.values[index]) : update;
      if (!Object.is(value, hooks.values[index])) {
        hooks.values[index] = value;
        hooks.dirty = true;
      }
    };
    return [hooks.values[index], set];
  };`;

function resolveSource(base: string) {
  for (const candidate of [`${base}.ts`, `${base}.tsx`, join(base, "index.ts"), base]) {
    if (existsSync(candidate)) return candidate;
  }
  throw new Error(`Cannot resolve ${base}`);
}

async function bundle(entry: string, name: string, stubs: Record<string, string>) {
  const outfile = join(work, `${name}.mjs`);
  const plugin: Plugin = {
    name: "stubs",
    setup(pluginBuild) {
      pluginBuild.onResolve({ filter: /^react-real$/ }, () => ({ path: "react", external: true }));
      pluginBuild.onResolve({ filter: /^react\/jsx-runtime$/ }, () => ({
        path: "react/jsx-runtime",
        external: true,
      }));
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
  };
  await build({
    entryPoints: [join(root, entry)],
    bundle: true,
    format: "esm",
    platform: "node",
    jsx: "automatic",
    outfile,
    logLevel: "silent",
    plugins: [plugin],
  });
  writeFileSync(
    outfile,
    readFileSync(outfile, "utf8")
      .replaceAll('from "react"', `from ${JSON.stringify(import.meta.resolve("react"))}`)
      .replaceAll(
        'from "react/jsx-runtime"',
        `from ${JSON.stringify(import.meta.resolve("react/jsx-runtime"))}`,
      ),
  );
  return import(pathToFileURL(outfile).href);
}

const viewModule = await bundle("src/components/count/CountLocationView.tsx", "view", {
  react: reactStub,
  "@tanstack/react-query": `export const useQuery = () => globalThis.__count.query;`,
  "@tanstack/react-router": `export const useNavigate = () => () => {};`,
  "@tanstack/react-start": `export const useServerFn = (fn) => fn;`,
  "@/hooks/use-active-org": `export const useActiveOrg = () => ({ active: { role: "staff" } });`,
  "@/lib/inventory-count.functions": `
    export const getCountLocationFn = async () => { throw new Error("not called"); };
    export const submitCountFn = async () => { throw new Error("not called"); };`,
  "@/components/count/InventoryCountForm": `
    import { createElement } from "react";
    export const InventoryCountForm = (props) => {
      globalThis.__count.form = props;
      return createElement("form", {
        "data-versions": props.page.items.map((item) => item.version).join(","),
        "data-quantities": props.page.items.map((item) => item.quantity).join(","),
      });
    };`,
  "@/components/count/CountUnavailable": `
    import { createElement } from "react";
    export const CountUnavailable = ({ message }) => createElement("p", { "data-unavailable": "" }, message);`,
  "@/components/staff/StaffStates": `
    import { createElement } from "react";
    export const StaffErrorState = ({ message }) => createElement("p", { "data-error": "" }, message);
    export const StaffListSkeleton = ({ label }) => createElement("p", { "data-loading": "" }, label);`,
});

const rootModule = await bundle("src/routes/__root.tsx", "root", {
  react: reactStub,
  "@tanstack/react-query": `
    export class QueryClient {}
    export const QueryClientProvider = ({ children }) => children;`,
  "@tanstack/react-router": `
    export const createRootRouteWithContext = () => (options) => ({
      options,
      useRouteContext: () => ({ queryClient: globalThis.__auth.queryClient }),
    });
    export const useRouter = () => globalThis.__auth.router;
    export const Outlet = () => null, Link = () => null, HeadContent = () => null, Scripts = () => null;`,
  "../styles.css?url": `export default "";`,
  "../lib/lovable-error-reporting": `export const reportLovableError = () => {};`,
  "@/integrations/supabase/client": `
    export const supabase = { auth: {
      onAuthStateChange: (listener) => {
        globalThis.__auth.listeners.push(listener);
        return { data: { subscription: { unsubscribe() {} } } };
      },
      getSession: async () => ({ data: { session: null } }),
    } };`,
});

const { createElement } = await import("react");
const { renderToStaticMarkup } = await import("react-dom/server");
const { buildCountSubmission, initialCountEntries } = await import("../src/inventory/count.ts");

type Item = { inventoryItemId: string; version: number; quantity: string };
const hooks = { index: 0, values: {} as Record<number, unknown>, dirty: false };
const count = {
  query: {} as Record<string, unknown>,
  form: null as null | { page: { items: Item[] }; onReload: () => void },
};
Object.assign(globalThis, { __hooks: hooks, __count: count });

const ITEM = "2e31c531-fa22-41c6-b5d1-bdb4bb821e05";
const page = (version: number, quantity = "1") => ({
  location: { id: "location-1", name: "Phase 7A.2 Final Acceptance", lastCountedAt: null },
  items: [
    {
      inventoryItemId: ITEM,
      name: "Removal Suture Skin Kit",
      unit: "Ea",
      sku: "2677976",
      manufacturer: null,
      archived: false,
      quantity,
      version,
    },
  ],
});

function renderView() {
  for (let pass = 0; pass < 5; pass++) {
    hooks.index = 0;
    hooks.dirty = false;
    const html = renderToStaticMarkup(
      createElement(viewModule.CountLocationView, {
        organizationId: "org-1",
        locationId: "location-1",
      }),
    );
    if (!hooks.dirty) return html;
  }
  throw new Error("CountLocationView kept updating state while rendering");
}
function freshView() {
  hooks.values = {};
  count.form = null;
}
const query = (fields: Record<string, unknown>) => {
  let refetches = 0;
  count.query = {
    data: undefined,
    dataUpdatedAt: 0,
    error: null,
    isLoading: false,
    refetch: () => {
      refetches++;
      return Promise.resolve();
    },
    ...fields,
  };
  return () => refetches;
};

test("a background refetch never swaps the open count form's page or versions", () => {
  freshView();
  query({ data: page(2), dataUpdatedAt: 1_000 });
  assert.match(renderView(), /data-versions="2"/);
  const started = count.form!;

  // The root listener invalidated every query; the location now has version 4.
  query({ data: page(4), dataUpdatedAt: 2_000 });
  const html = renderView();
  assert.match(html, /data-versions="2"/, "the form still holds the version staff were shown");
  assert.equal(count.form!.page, started.page, "the same page, so the same form and entries");

  // Saving checks the versions staff counted against, so the server rejects it as stale.
  const lines = buildCountSubmission(
    count.form!.page.items as never,
    initialCountEntries(count.form!.page.items as never),
  );
  assert.deepEqual(lines, [{ inventoryItemId: ITEM, observedVersion: 2, countedQuantity: "1" }]);
});

test("a failed background refetch leaves the open count form in place", () => {
  freshView();
  query({ data: page(2), dataUpdatedAt: 1_000 });
  renderView();
  query({ data: page(2), dataUpdatedAt: 1_000, error: new Error("Failed to fetch") });
  const html = renderView();
  assert.match(html, /data-versions="2"/);
  assert.doesNotMatch(html, /data-error/);
});

test("only an explicit reload starts a new form from fresh quantities and versions", () => {
  freshView();
  query({ data: page(2), dataUpdatedAt: 1_000 });
  renderView();
  const refetches = query({ data: page(4), dataUpdatedAt: 2_000 });
  assert.match(renderView(), /data-versions="2"/);

  count.form!.onReload();
  assert.equal(refetches(), 1, "reload refetches the location");
  renderView();
  assert.match(renderView(), /data-versions="2"/, "older data does not replace the form");

  query({ data: page(5, "3"), dataUpdatedAt: Date.now() + 1_000 });
  const html = renderView();
  assert.match(html, /data-versions="5"/);
  assert.match(html, /data-quantities="3"/);

  // The reload is spent: the next background refetch is ignored again.
  query({ data: page(6), dataUpdatedAt: Date.now() + 2_000 });
  assert.match(renderView(), /data-versions="5"/);
});

test("first load, load errors and unavailable locations render as before", () => {
  freshView();
  query({ isLoading: true });
  assert.match(renderView(), /data-loading/);
  freshView();
  query({ error: new Error("Failed to fetch") });
  assert.match(renderView(), /data-error/);
  freshView();
  query({ error: new Error("This inventory location is not available for counting") });
  assert.match(renderView(), /data-unavailable/);
});

// ---------------------------------------------------------------------------------------
// The root auth listener.
// ---------------------------------------------------------------------------------------
function mountRoot() {
  const calls = { router: 0, queries: 0 };
  const auth = {
    listeners: [] as Array<(event: string, session: unknown) => void>,
    router: { invalidate: () => calls.router++, navigate: () => {} },
    queryClient: { invalidateQueries: () => calls.queries++ },
  };
  Object.assign(globalThis, { __auth: auth });
  hooks.values = {};
  hooks.index = 0;
  renderToStaticMarkup(createElement(rootModule.Route.options.component));
  const emit = (event: string, userId: string | null) =>
    auth.listeners.forEach((listener) => listener(event, userId ? { user: { id: userId } } : null));
  return { calls, emit };
}

test("recovering the same session (a hidden tab becoming visible) refetches nothing", () => {
  const { calls, emit } = mountRoot();
  emit("INITIAL_SESSION", "staff-1");
  emit("SIGNED_IN", "staff-1");
  emit("TOKEN_REFRESHED", "staff-1");
  emit("SIGNED_IN", "staff-1");
  assert.deepEqual(calls, { router: 0, queries: 0 });
});

test("real sign-ins, user switches, user updates and sign-outs still reload the app", () => {
  const { calls, emit } = mountRoot();
  emit("INITIAL_SESSION", null);
  emit("SIGNED_IN", "staff-1");
  assert.deepEqual(calls, { router: 1, queries: 1 }, "signing in");
  emit("SIGNED_IN", "owner-1");
  assert.deepEqual(calls, { router: 2, queries: 2 }, "a different user");
  emit("USER_UPDATED", "owner-1");
  assert.deepEqual(calls, { router: 3, queries: 3 }, "user updated");
  emit("SIGNED_OUT", null);
  assert.deepEqual(calls, { router: 4, queries: 3 }, "signing out reloads routes only");

  const early = mountRoot();
  early.emit("SIGNED_IN", "staff-1");
  assert.deepEqual(
    early.calls,
    { router: 1, queries: 1 },
    "a SIGNED_IN before any session is known",
  );
});

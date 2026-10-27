// Regression test for the authenticated layout's role/path gate
// (src/routes/_authenticated/route.tsx). An admin page missing from ADMIN_ROUTES renders
// as a blank screen: the layout returns null and the page never mounts. /catalog-vendors
// shipped that way.
//
// The real layout module is bundled with esbuild and server-rendered. Only its imports are
// stubbed: Supabase, the active-organization context, the two shells, and the router hooks.
// Effects run during render so the layout's redirect decisions are observable.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const root = fileURLToPath(new URL("../", import.meta.url));
const work = mkdtempSync(join(tmpdir(), "layout-gate-"));
after(() => rmSync(work, { recursive: true, force: true }));

const stubs: Record<string, string> = {
  "@/integrations/supabase/client": `export const supabase = { auth: { getUser: async () => ({ data: { user: null }, error: null }) } };`,
  "@/hooks/use-active-org": `
    export const ActiveOrgProvider = ({ children }) => children;
    export const useActiveOrg = () => globalThis.__layout.org;`,
  "@/components/app/AdminAppShell": `
    import { createElement } from "react";
    export const AdminAppShell = ({ children }) => createElement("div", { "data-shell": "admin" }, children);`,
  "@/components/app/StaffAppShell": `
    import { createElement } from "react";
    export const StaffAppShell = ({ children }) => createElement("div", { "data-shell": "staff" }, children);`,
  "@tanstack/react-router": `
    import { createElement } from "react";
    export const createFileRoute = () => (options) => ({ options });
    export const redirect = (value) => value;
    export const Outlet = () => createElement("main", { "data-outlet": globalThis.__layout.path });
    export const useRouterState = ({ select }) => select({ location: { pathname: globalThis.__layout.path } });
    export const useNavigate = () => (target) => { globalThis.__layout.navigations.push(target.to); };`,
  // The real React, except that effects run during render.
  react: `
    export * from "react-real";
    export const useEffect = (effect) => { effect(); };`,
};

const bundlePath = join(work, "layout.mjs");
await build({
  entryPoints: [join(root, "src/routes/_authenticated/route.tsx")],
  bundle: true,
  format: "esm",
  platform: "node",
  jsx: "automatic",
  outfile: bundlePath,
  logLevel: "silent",
  plugins: [
    {
      name: "layout-stubs",
      setup(pluginBuild) {
        pluginBuild.onResolve({ filter: /^react-real$/ }, () => ({
          path: "react",
          external: true,
        }));
        pluginBuild.onResolve({ filter: /^react\/jsx-runtime$/ }, () => ({
          path: "react/jsx-runtime",
          external: true,
        }));
        pluginBuild.onResolve({ filter: /.*/ }, (args) =>
          args.path in stubs ? { path: args.path, namespace: "stub" } : undefined,
        );
        pluginBuild.onLoad({ filter: /.*/, namespace: "stub" }, (args) => ({
          contents: stubs[args.path],
          loader: "jsx",
          resolveDir: root,
        }));
      },
    },
  ],
});
// Resolve the externals from the repo's node_modules.
writeFileSync(join(work, "package.json"), "{}");
const bundled = readFileSync(bundlePath, "utf8")
  .replaceAll('from "react"', `from ${JSON.stringify(import.meta.resolve("react"))}`)
  .replaceAll(
    'from "react/jsx-runtime"',
    `from ${JSON.stringify(import.meta.resolve("react/jsx-runtime"))}`,
  );
writeFileSync(bundlePath, bundled);

const { Route } = await import(pathToFileURL(bundlePath).href);
const { createElement } = await import("react");
const { renderToStaticMarkup } = await import("react-dom/server");

type Role = "owner" | "admin" | "staff";

function membership(role: Role) {
  return {
    id: "m-1",
    organizationId: "00000000-0000-4000-8000-000000000101",
    role,
    defaultTeamId: null,
    defaultLocationId: null,
    organizationName: "Henry Athletics",
  };
}

function renderLayout(
  path: string,
  org: { memberships: unknown[]; active: unknown; loading: boolean },
) {
  const state = {
    path,
    org: { ...org, setActiveOrgId: () => {}, refetch: () => {} },
    navigations: [] as string[],
  };
  (globalThis as { __layout?: unknown }).__layout = state;
  const html = renderToStaticMarkup(createElement(Route.options.component));
  return { html, navigations: state.navigations };
}

const asRole = (role: Role, path: string) =>
  renderLayout(path, { memberships: [membership(role)], active: membership(role), loading: false });

// Every route in the admin navigation, read from the shell itself.
const shellSource = readFileSync(join(root, "src/components/app/AdminAppShell.tsx"), "utf8");
const navPaths = [...shellSource.matchAll(/\{ to: "(\/[^"]*)", label:/g)].map((match) => match[1]);

test("owners and admins reach Catalog Vendors through the admin shell", () => {
  for (const role of ["owner", "admin"] as const) {
    const { html, navigations } = asRole(role, "/catalog-vendors");
    assert.notEqual(html, "", `${role} got a blank layout`);
    assert.match(html, /data-shell="admin"/);
    assert.match(html, /data-outlet="\/catalog-vendors"/);
    assert.deepEqual(navigations, [], `${role} was redirected`);
  }
});

test("every admin navigation route renders for owners and admins, never a null layout", () => {
  assert.ok(navPaths.includes("/catalog-vendors"));
  assert.ok(navPaths.includes("/budget-purchasing"));
  assert.ok(navPaths.length >= 10, `parsed ${navPaths.length} navigation routes`);
  for (const path of navPaths) {
    for (const role of ["owner", "admin"] as const) {
      const { html, navigations } = asRole(role, path);
      assert.match(
        html,
        new RegExp(`data-outlet="${path}"`),
        `${role} on ${path} rendered no page`,
      );
      assert.deepEqual(navigations, [], `${role} on ${path} was redirected`);
    }
  }
});

test("staff on Catalog Vendors keep the existing redirect to /staff", () => {
  const { html, navigations } = asRole("staff", "/catalog-vendors");
  assert.equal(html, "");
  assert.deepEqual(navigations, ["/staff"]);
});

test("staff on any admin navigation route are redirected to /staff", () => {
  for (const path of navPaths) {
    const { navigations } = asRole("staff", path);
    assert.deepEqual(navigations, ["/staff"], `staff on ${path}`);
  }
});

// /count is in both allowlists. Phase 7A.2 production acceptance found staff bounced from
// every /count page (the Scan Inventory QR card and scanned labels) to /staff: the
// admin-path redirect ran without consulting the staff allowlist.
const countPaths = [
  "/count",
  `/count/${"A".repeat(21)}_-${"z".repeat(20)}`,
  "/count/location/00000000-0000-4000-8000-000000000201",
];

test("staff reach every /count page in the staff shell without a redirect", () => {
  for (const path of countPaths) {
    const { html, navigations } = asRole("staff", path);
    assert.deepEqual(navigations, [], `staff on ${path} was redirected`);
    assert.match(html, /data-shell="staff"/, `staff on ${path}`);
    assert.match(html, new RegExp(`data-outlet="${path}"`), `staff on ${path} rendered no page`);
  }
});

test("owners and admins still reach every /count page in the admin shell", () => {
  for (const path of countPaths) {
    for (const role of ["owner", "admin"] as const) {
      const { html, navigations } = asRole(role, path);
      assert.deepEqual(navigations, [], `${role} on ${path} was redirected`);
      assert.match(html, /data-shell="admin"/, `${role} on ${path}`);
      assert.match(html, new RegExp(`data-outlet="${path}"`), `${role} on ${path}`);
    }
  }
});

test("existing layout states are unchanged", () => {
  assert.match(
    renderLayout("/catalog-vendors", { memberships: [], active: null, loading: true }).html,
    /Loading…/,
  );
  assert.deepEqual(
    renderLayout("/catalog-vendors", { memberships: [], active: null, loading: false }).navigations,
    ["/onboarding"],
  );
  const staffHome = asRole("staff", "/staff");
  assert.match(staffHome.html, /data-shell="staff"/);
  assert.deepEqual(staffHome.navigations, []);
  assert.deepEqual(asRole("owner", "/staff").navigations, ["/dashboard"]);
  assert.match(asRole("owner", "/budget-purchasing").html, /data-outlet="\/budget-purchasing"/);
});

test("the allowlist keeps the PR #4 pattern and now lists Catalog Vendors", () => {
  const layout = readFileSync(join(root, "src/routes/_authenticated/route.tsx"), "utf8");
  assert.match(
    layout,
    /const ADMIN_ROUTES = \["\/budget-purchasing", "\/budget", [^\]]*"\/products", "\/catalog-vendors", "\/vendors"/,
  );
});

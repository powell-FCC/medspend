// Phase 7A.2: QR inventory physical counts. Pure count, label, scanner and auth-return
// helpers; structural checks of the migrations, release scripts, routes and server functions;
// rendered count, scanner and owner label UI. Database behavior is covered by
// supabase/tests/phase7a2_inventory_physical_counts_behavior.sql, phase7a2_mutation_check.sh,
// phase7a2_race_check.sh and phase7a2_release_check.sh.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import QRCode from "qrcode";
import { prepareZXingModule, readBarcodes } from "zxing-wasm/reader";
import {
  availableLabel,
  buildCountSubmission,
  canonicalQuantity,
  countErrorKind,
  countLabelUrl,
  countTokenFromScan,
  formatSignedDelta,
  initialCountEntries,
  labelUnavailableMessage,
  parseCountQuantity,
  quantityDelta,
  reviewCount,
  stepCountQuantity,
  type CountItem,
  type CountPage,
} from "../src/inventory/count.ts";
import { reconcileMoveSource, stockLocationLabel } from "../src/inventory/locations.ts";
import { printableLabelHtml, qrLabelSvg } from "../src/inventory/labels.ts";
import {
  cameraFailure,
  cameraSupported,
  createQrDetector,
  nativeQrSupported,
} from "../src/count/qr-detector.ts";
import {
  rememberPendingAuthRedirect,
  safeAuthRedirect,
  takePendingAuthRedirect,
} from "../src/lib/auth-ux.ts";
import type { InventoryLocation, InventoryLocationBalance } from "../src/types/inventory.ts";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = (path: string) => readFileSync(join(root, path), "utf8");
const migration = read("supabase/migrations/20261027120000_phase7a2_inventory_physical_counts.sql");
const hardening = read(
  "supabase/migrations/20261027120100_phase7a2_staff_inventory_read_hardening.sql",
);
const behavior = read("supabase/tests/phase7a2_inventory_physical_counts_behavior.sql");
const fingerprint = read("supabase/release/phase7a2/fingerprint.sql");
const precheck = read("supabase/release/phase7a2/precheck.sql");
const postcheck = read("supabase/release/phase7a2/postcheck.sql");
const hardeningPostcheck = read("supabase/release/phase7a2/hardening_postcheck.sql");
const countServer = read("src/lib/inventory-count.functions.ts");
const gate = read("src/routes/_authenticated/route.tsx");
const staffHome = read("src/routes/_authenticated/staff/index.tsx");
const authPage = read("src/routes/auth.tsx");
const rootRoute = read("src/routes/__root.tsx");
const fallback = read("src/count/zxing-fallback.ts");
const pkg = JSON.parse(read("package.json")) as {
  dependencies: Record<string, string>;
  devDependencies: Record<string, string>;
};

const item = (
  overrides: Partial<CountItem> & Pick<CountItem, "inventoryItemId" | "name">,
): CountItem => ({
  sku: null,
  manufacturer: null,
  unit: "each",
  quantity: "0",
  version: 1,
  archived: false,
  ...overrides,
});
const tape = item({
  inventoryItemId: "11111111-1111-4111-8111-111111111111",
  name: "Athletic Tape",
  sku: "TAPE-1",
  unit: "roll",
  quantity: "12",
  version: 4,
});
const gauze = item({
  inventoryItemId: "22222222-2222-4222-8222-222222222222",
  name: "Gauze",
  unit: "box",
  quantity: "2.75",
  version: 2,
});
const empty = item({
  inventoryItemId: "33333333-3333-4333-8333-333333333333",
  name: "Ice Packs",
  quantity: "0",
  version: 7,
});
const archived = item({
  inventoryItemId: "44444444-4444-4444-8444-444444444444",
  name: "Old Splints",
  quantity: "5",
  version: 3,
  archived: true,
});

// Bundle the UI before any test is registered, so cleanup cannot race the build.
const cacheDir = join(root, "node_modules/.cache/phase7a2-count-test");
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
  "@tanstack/react-router": `
    import { createElement } from "react";
    export const Link = ({ to, params, children, className }) =>
      createElement("a", { href: String(to).replace("$locationId", params?.locationId ?? ""), className }, children);`,
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
  export * from "@/components/count/InventoryCountForm";
  export { QrScannerView, PhoneCameraHelp } from "@/components/count/QrScanner";
  export { CountLocationPicker } from "@/components/count/CountLocationPicker";
  export { CountUnavailable } from "@/components/count/CountUnavailable";
  export { LocationLabelsPanel } from "@/components/inventory/workspace/LocationLabelsPanel";
  export { LocationsTable } from "@/components/inventory/workspace/LocationsTable";
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
      name: "count-stubs",
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
const noop = async () => {
  throw new Error("not called");
};
// ---------------------------------------------------------------------------------------
// Quantities.
// ---------------------------------------------------------------------------------------
test("count quantities parse exactly, keep fractions, and never treat blank as zero", () => {
  assert.deepEqual(parseCountQuantity("9"), { ok: true, value: "9" });
  assert.deepEqual(parseCountQuantity(" 3.000 "), { ok: true, value: "3" });
  assert.deepEqual(parseCountQuantity("2,5"), { ok: true, value: "2.5" });
  assert.deepEqual(parseCountQuantity(".5"), { ok: true, value: "0.5" });
  assert.deepEqual(parseCountQuantity("0"), { ok: true, value: "0" });
  assert.deepEqual(parseCountQuantity("0.000001"), { ok: true, value: "0.000001" });
  assert.equal(parseCountQuantity("").ok, false);
  assert.match((parseCountQuantity("   ") as { error: string }).error, /0 if there is none/);
  assert.match((parseCountQuantity("-1") as { error: string }).error, /negative/);
  for (const bad of ["abc", "1e3", "NaN", "1.2.3", "Infinity", "1 000"])
    assert.equal(parseCountQuantity(bad).ok, false, bad);
  assert.match((parseCountQuantity("1.1234567") as { error: string }).error, /6 decimal places/);
  assert.equal(parseCountQuantity("1000000000").ok, true);
  assert.equal(parseCountQuantity("1000000001").ok, false);
  assert.equal(canonicalQuantity("007.250"), "7.25");
  assert.equal(canonicalQuantity("1.0"), canonicalQuantity("1.00"));
});

test("deltas and the +/- control are exact decimal arithmetic", () => {
  assert.equal(quantityDelta("12", "9"), "-3");
  assert.equal(quantityDelta("0.1", "0.3"), "0.2");
  assert.equal(quantityDelta("2.75", "2.75"), "0");
  assert.equal(quantityDelta("0", "0.125"), "0.125");
  assert.equal(stepCountQuantity("2.75", 1), "3.75");
  assert.equal(stepCountQuantity("0.5", -1), "0");
  assert.equal(stepCountQuantity("", 1), "1");
  assert.equal(formatSignedDelta("-3"), "−3");
  assert.equal(formatSignedDelta("0.5"), "+0.5");
});

test("a count review separates changed, unchanged and invalid lines; submission echoes versions", () => {
  const items = [tape, gauze, empty, archived];
  const entries = { ...initialCountEntries(items) };
  assert.deepEqual(entries, {
    [tape.inventoryItemId]: "12",
    [gauze.inventoryItemId]: "2.75",
    [empty.inventoryItemId]: "0",
    [archived.inventoryItemId]: "5",
  });
  const unchanged = reviewCount(items, entries);
  assert.deepEqual(
    [unchanged.changed.length, unchanged.unchanged, unchanged.complete],
    [0, 4, true],
  );

  entries[tape.inventoryItemId] = "9";
  entries[empty.inventoryItemId] = "3";
  entries[gauze.inventoryItemId] = "2.750";
  const review = reviewCount(items, entries);
  assert.deepEqual(
    review.changed.map((line) => [line.item.name, line.counted, line.delta]),
    [
      ["Athletic Tape", "9", "-3"],
      ["Ice Packs", "3", "3"],
    ],
  );
  assert.equal(review.unchanged, 2);
  assert.deepEqual(buildCountSubmission(items, entries), [
    { inventoryItemId: tape.inventoryItemId, observedVersion: 4, countedQuantity: "9" },
    { inventoryItemId: gauze.inventoryItemId, observedVersion: 2, countedQuantity: "2.75" },
    { inventoryItemId: empty.inventoryItemId, observedVersion: 7, countedQuantity: "3" },
    { inventoryItemId: archived.inventoryItemId, observedVersion: 3, countedQuantity: "5" },
  ]);

  entries[archived.inventoryItemId] = "";
  const incomplete = reviewCount(items, entries);
  assert.equal(incomplete.complete, false);
  assert.match(incomplete.errors[archived.inventoryItemId], /0 if there is none/);
  assert.throws(() => buildCountSubmission(items, entries), /0 if there is none/);
  assert.equal(reviewCount([], {}).complete, false, "an empty location has nothing to save");
});

test("count errors and label states map to plain messages", () => {
  assert.equal(
    countErrorKind(
      "Inventory changed while you were counting. Reload this location and confirm the quantities again.",
    ),
    "stale",
  );
  assert.equal(
    countErrorKind("This inventory location is not available for counting"),
    "unavailable",
  );
  assert.equal(countErrorKind("Forbidden: organization membership required"), "forbidden");
  assert.equal(countErrorKind("network down"), "other");
  assert.equal(availableLabel({ status: "unavailable" }), null);
  assert.deepEqual(
    availableLabel({
      status: "available",
      organizationId: "o",
      locationId: "l",
      locationName: "Cabinet",
    })?.locationId,
    "l",
  );
  for (const status of ["unavailable", "replaced", "location_unavailable"] as const) {
    const message = labelUnavailableMessage(status);
    assert.ok(message.length > 0);
    assert.doesNotMatch(message, /organization [A-Z]|Cabinet/);
  }
});

// ---------------------------------------------------------------------------------------
// Tokens, labels and the scanner.
// ---------------------------------------------------------------------------------------
const token = "Abc_DEF-0123456789abcdefghijklmnopqrstuvwxy";
test("only count links and bare tokens are accepted from a scan; nothing else is followed", () => {
  assert.equal(token.length, 43);
  assert.equal(countTokenFromScan(token), token);
  assert.equal(countTokenFromScan(`https://app.sport-spend.com/count/${token}`), token);
  assert.equal(
    countTokenFromScan(`https://medspend.powell-cd0.workers.dev/count/${token}/`),
    token,
  );
  for (const other of [
    "https://example.com/phish",
    `https://app.sport-spend.com/count/${token}/extra`,
    `https://app.sport-spend.com/staff?x=${token}`,
    `javascript:alert(1)//count/${token}`,
    "WIFI:S:gym;T:WPA;P:secret;;",
    token.slice(1),
    "",
  ]) {
    assert.equal(countTokenFromScan(other), null, other);
  }
  assert.equal(
    countLabelUrl("https://app.sport-spend.com", token),
    `https://app.sport-spend.com/count/${token}`,
  );
});

test("a printed label decodes back to the count link with the self-hosted decoder", async () => {
  const wasm = readFileSync(join(root, "node_modules/zxing-wasm/dist/reader/zxing_reader.wasm"));
  await prepareZXingModule({
    overrides: {
      wasmBinary: wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength),
    },
    fireImmediately: true,
  });
  const url = countLabelUrl("https://app.sport-spend.com", token);
  const svg = await qrLabelSvg(url);
  assert.match(svg, /^<svg[^>]*viewBox/);
  // Rasterize the same symbol the SVG draws and decode it, offline.
  const symbol = QRCode.create(url, { errorCorrectionLevel: "M" });
  const size = symbol.modules.size;
  const scale = 6;
  const quiet = 4;
  const width = (size + quiet * 2) * scale;
  const data = new Uint8ClampedArray(width * width * 4).fill(255);
  for (let y = 0; y < size; y++)
    for (let x = 0; x < size; x++)
      if (symbol.modules.get(y, x))
        for (let dy = 0; dy < scale; dy++)
          for (let dx = 0; dx < scale; dx++) {
            const i = (((y + quiet) * scale + dy) * width + (x + quiet) * scale + dx) * 4;
            data[i] = data[i + 1] = data[i + 2] = 0;
          }
  const results = await readBarcodes(
    { data, width, height: width, colorSpace: "srgb" },
    { formats: ["QRCode"] },
  );
  assert.equal(results.length, 1);
  assert.equal(countTokenFromScan(results[0].text), token);
});

test("the printable label escapes the location name", () => {
  const html = printableLabelHtml(`Cabinet <script>alert("x")</script> & 'B'`, "<svg></svg>");
  assert.doesNotMatch(html, /<script>/);
  assert.match(
    html,
    /Cabinet &lt;script&gt;alert\(&quot;x&quot;\)&lt;\/script&gt; &amp; &#39;B&#39;/,
  );
  assert.match(html, /<svg><\/svg>/);
});

test("the scanner prefers native QR detection and falls back to the bundled decoder", async () => {
  class FakeDetector {
    static getSupportedFormats = async () => ["qr_code", "ean_13"];
    async detect() {
      return [{ rawValue: `https://app.sport-spend.com/count/${token}` }];
    }
  }
  const native = await createQrDetector({ BarcodeDetector: FakeDetector });
  assert.equal(native.kind, "native");
  assert.deepEqual(await native.detect({} as CanvasImageSource), [
    `https://app.sport-spend.com/count/${token}`,
  ]);
  class NoQr {
    static getSupportedFormats = async () => ["ean_13"];
  }
  assert.equal(await nativeQrSupported({ BarcodeDetector: NoQr }), false);
  assert.equal(await nativeQrSupported({}), false, "no BarcodeDetector (Safari on iPhone)");
  assert.equal(cameraFailure({ name: "NotAllowedError" }), "denied");
  assert.equal(cameraFailure({ name: "NotFoundError" }), "unavailable");
  assert.equal(cameraFailure(new Error("x")), "unsupported");
  assert.equal(cameraSupported({ navigator: { mediaDevices: { getUserMedia: () => {} } } }), true);
  assert.equal(cameraSupported({ navigator: {} }), false);
});

test("the WASM decoder is pinned, lazy and self-hosted", () => {
  assert.equal(pkg.dependencies["barcode-detector"], "3.2.2");
  assert.equal(pkg.dependencies["zxing-wasm"], "3.1.3");
  assert.equal(pkg.dependencies.qrcode, "1.5.4");
  const barcodeDetector = JSON.parse(read("node_modules/barcode-detector/package.json")) as {
    dependencies: Record<string, string>;
  };
  assert.equal(
    barcodeDetector.dependencies["zxing-wasm"],
    pkg.dependencies["zxing-wasm"],
    "the bundled .wasm matches the ponyfill's decoder",
  );
  assert.match(fallback, /import readerWasmUrl from "zxing-wasm\/reader\/zxing_reader\.wasm\?url"/);
  assert.match(
    fallback,
    /prepareZXingModule\(\{ overrides: \{ locateFile: zxingLocateFile \} \}\)/,
  );
  assert.doesNotMatch(fallback, /jsdelivr|unpkg|https:/);
  const detector = read("src/count/qr-detector.ts");
  assert.match(detector, /await import\("\.\/zxing-fallback"\)/);
  assert.doesNotMatch(detector, /^import .*barcode-detector/m);
});

// ---------------------------------------------------------------------------------------
// Sign-in return path.
// ---------------------------------------------------------------------------------------
function memoryStorage() {
  const values = new Map<string, string>();
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => void values.set(key, value),
    removeItem: (key: string) => void values.delete(key),
    values,
  };
}

test("a QR deep link survives Google sign-in, once, and only as a same-site path", () => {
  const storage = memoryStorage();
  const now = 1_800_000_000_000;
  rememberPendingAuthRedirect(storage, `/count/${token}`, now);
  assert.equal(takePendingAuthRedirect(storage, now + 60_000), `/count/${token}`);
  assert.equal(takePendingAuthRedirect(storage, now + 60_000), undefined, "consumed once");

  rememberPendingAuthRedirect(storage, `/count/${token}`, now);
  assert.equal(takePendingAuthRedirect(storage, now + 16 * 60_000), undefined, "expires");

  for (const unsafe of [
    "https://evil.example/count",
    "//evil.example",
    "/\\evil.example",
    "/\u0000x",
    undefined,
  ]) {
    rememberPendingAuthRedirect(storage, unsafe, now);
    assert.equal(takePendingAuthRedirect(storage, now), undefined, String(unsafe));
  }
  storage.setItem(
    "medspend.pendingAuthRedirect",
    JSON.stringify({ path: "//evil.example", at: now }),
  );
  assert.equal(
    takePendingAuthRedirect(storage, now),
    undefined,
    "tampered storage is re-validated",
  );
  storage.setItem("medspend.pendingAuthRedirect", "not json");
  assert.equal(takePendingAuthRedirect(storage, now), undefined);
  assert.equal(safeAuthRedirect("/count/x"), "/count/x");
  assert.equal(safeAuthRedirect("/\\evil.example"), undefined);

  // Wiring: Google stores the path before leaving; the root route resumes it after sign-in.
  assert.match(
    authPage,
    /rememberPendingAuthRedirect\(window\.sessionStorage, redirect\);\s*\}[^]*?signInWithOAuth\("google"/,
  );
  assert.match(rootRoute, /takePendingAuthRedirect\(window\.sessionStorage\)/);
  assert.match(rootRoute, /event === "SIGNED_IN"/);
  // Email sign-in keeps using the redirect parameter the gate adds.
  assert.match(gate, /redirect\(\{ to: "\/auth", search: \{ redirect: location\.href \} \}\)/);
});

test("/count works in both shells and a label link skips organization selection", () => {
  assert.match(gate, /const ADMIN_ROUTES = \[[^\]]*"\/count"\]/);
  assert.match(gate, /const STAFF_ROUTES = \["\/staff", "\/profile", "\/count"\]/);
  const pattern = /^\/count\/[A-Za-z0-9_-]{43}\/?$/;
  assert.match(gate, /return \/\^\\\/count\\\/\[A-Za-z0-9_-\]\{43\}\\\/\?\$\/\.test\(p\);/);
  assert.ok(pattern.test(`/count/${token}`));
  assert.ok(!pattern.test("/count/location/abc"));
  assert.match(gate, /pathname !== "\/select-organization" && !isCountLabelPath\(pathname\)/);
  assert.match(gate, /if \(isCountLabelPath\(pathname\)\) return <Outlet \/>;/);
  const label = read("src/routes/_authenticated/count.$token.tsx");
  assert.match(label, /setActiveOrgId\(resolved\.organizationId\)/);
  assert.match(
    label,
    /memberships\.some\(\(m\) => m\.organizationId === resolved\.organizationId\)/,
  );
});

// ---------------------------------------------------------------------------------------
// Server functions, migrations and release scripts.
// ---------------------------------------------------------------------------------------
test("count server functions use only the membership-checked RPCs", () => {
  assert.doesNotMatch(countServer, /\.from\(/);
  for (const rpc of [
    "resolve_inventory_count_label",
    "list_countable_inventory_locations",
    "get_inventory_count_location",
    "submit_inventory_count",
    "list_inventory_location_count_status",
    "issue_inventory_location_label",
    "revoke_inventory_location_labels",
  ]) {
    assert.match(countServer, new RegExp(`rpc\\(\\s*"${rpc}"`), rpc);
  }
  assert.match(countServer, /countedQuantity: z\s*\.string\(\)\s*\.trim\(\)\s*\.regex/);
  for (const path of [
    "src/lib/staff-workspace.functions.ts",
    "src/lib/supply-requests.functions.ts",
  ]) {
    const source = read(path);
    assert.doesNotMatch(
      source,
      /from\("inventory_items"\)/,
      `${path} no longer reads inventory_items directly`,
    );
    assert.match(source, /rpc\("get_supply_request_inventory_identities"/, path);
  }
});

test("the migrations are atomic, additive, editor-safe and keep deletion untouched", async () => {
  const rewrite = (await import(
    new URL("../supabase/tests/support/studio_sql_editor_rewrite.mjs", import.meta.url).href
  )) as {
    tablesMissingRLS: (sql: string) => unknown[];
  };
  for (const [name, sql] of [
    ["counts", migration],
    ["hardening", hardening],
  ] as const) {
    assert.match(sql, /^BEGIN;$/m, name);
    assert.match(sql, /^COMMIT;\s*$/m, name);
    assert.equal(
      sql
        .slice(sql.lastIndexOf("\nCOMMIT;") + 8)
        .replace(/--.*$/gm, "")
        .trim(),
      "",
      name,
    );
    assert.doesNotMatch(sql.replace(/--.*$/gm, ""), /CREATE\s+TEMP/i, name);
    assert.deepEqual(rewrite.tablesMissingRLS(sql), [], name);
  }
  for (const table of [
    "inventory_location_labels",
    "inventory_count_sessions",
    "inventory_count_lines",
  ]) {
    assert.match(
      migration,
      new RegExp(`ALTER TABLE public\\.${table} ENABLE ROW LEVEL SECURITY;`),
      table,
    );
  }
  assert.doesNotMatch(
    migration,
    /FUNCTION public\.(delete_invoice_permanently|post_reviewed_invoice|inventory_apply_balance_delta|move_inventory_stock)\(/,
  );
  assert.match(
    migration,
    /reason IN \('Invoice received', 'Manual adjustment', 'Damaged', 'Expired', 'Correction', 'Physical count'\)/,
  );
  assert.match(migration, /AND \(item\.active OR balance\.quantity > 0\);/, "countable rule");
  assert.match(
    migration,
    /_quantities := _quantities \|\| trim_scale\(_quantity\);/,
    "canonical quantities",
  );
  assert.match(migration, /request_hash text NOT NULL/);
  assert.match(
    migration,
    /'Inventory changed while you were counting\. Reload this location and confirm the quantities again\.'/,
  );
  assert.match(migration, /extensions\.gen_random_bytes\(32\)/);
  assert.match(migration, /encode\(extensions\.digest\(_token, 'sha256'\), 'hex'\)/);
  const labelsTable = migration.slice(
    migration.indexOf("CREATE TABLE public.inventory_location_labels ("),
    migration.indexOf(");", migration.indexOf("CREATE TABLE public.inventory_location_labels (")),
  );
  assert.match(labelsTable, /token_hash text NOT NULL/);
  assert.doesNotMatch(labelsTable, /^\s+token\b/m, "no raw token column");
  assert.match(hardening, /DROP POLICY inventory_items_member_select ON public\.inventory_items;/);
  assert.match(hardening, /Apply AFTER the application/);
});

test("release scripts are SQL Editor safe and share one fingerprint", () => {
  const body = fingerprint.slice(fingerprint.indexOf("SELECT section, key, value FROM ("));
  for (const [name, file] of [
    ["precheck", precheck],
    ["postcheck", postcheck],
    ["hardening", hardeningPostcheck],
  ] as const) {
    assert.ok(file.endsWith(body), `${name} ends with the shared fingerprint`);
    assert.doesNotMatch(file, /^\\/m, `${name} has no psql meta-commands`);
    assert.doesNotMatch(
      file.replace(/\$[a-z0-9_]*\$[^]*?\$[a-z0-9_]*\$/g, ""),
      /^\s*(BEGIN|COMMIT|ROLLBACK)\b/im,
      name,
    );
    assert.doesNotMatch(file, /HASH_/, `${name} has every reviewed hash filled in`);
  }
  assert.match(precheck, /precheck: Phase 7A\.2 objects already exist/);
  assert.match(postcheck, /the hardening step runs only after the deploy/);
  assert.match(hardeningPostcheck, /staff can still read inventory_items directly/);
  for (const marker of [
    "zero-delta count bumps the balance version",
    "a zero-delta checkpoint blocks deleting the earlier receipt",
    "active item confirmed at zero stays countable",
    "archived item with stock is countable and flagged",
    "overage entered against a zero system balance",
    "replay returns the original summary",
    "This count request key was already used for a different count",
    "staff can no longer read inventory_items directly",
    "owner learns nothing",
    "SET CONSTRAINTS ALL IMMEDIATE;",
  ]) {
    assert.ok(behavior.includes(marker), marker);
  }
});

// ---------------------------------------------------------------------------------------
// 7A.1 polish: move form and stock-location label.
// ---------------------------------------------------------------------------------------
const loc = (
  id: string,
  name: string,
  kind: "unassigned" | "storage" = "storage",
): InventoryLocation => ({
  id,
  organizationId: "org",
  name,
  description: null,
  kind,
  active: true,
  createdAt: "",
  updatedAt: "",
});
const locations = [
  loc("u", "Unassigned", "unassigned"),
  loc("a", "Cabinet A"),
  loc("b", "Rehab Closet"),
];
const bal = (item: string, location: string, quantity: number): InventoryLocationBalance => ({
  inventoryItemId: item,
  inventoryLocationId: location,
  quantity,
  version: 1,
  updatedAt: "",
});

test("the stock-location label names Unassigned whenever it holds stock", () => {
  const cases: Array<[InventoryLocationBalance[], string]> = [
    [[bal("i", "u", 10)], "Unassigned"],
    [[bal("i", "u", 0), bal("i", "a", 1)], "Cabinet A"],
    [[bal("i", "u", 9), bal("i", "a", 1)], "Cabinet A + Unassigned"],
    [[bal("i", "a", 1), bal("i", "b", 2)], "2 locations"],
    [[bal("i", "u", 1), bal("i", "a", 1), bal("i", "b", 2)], "2 locations + Unassigned"],
    [[bal("i", "u", 0)], "No stock"],
    [[], "No stock"],
  ];
  for (const [balances, label] of cases)
    assert.equal(stockLocationLabel("i", locations, balances), label);
});

test("the move form never keeps an emptied source", () => {
  // The live 7A.1 acceptance case: the last unit moved back out of the cabinet.
  assert.deepEqual(reconcileMoveSource({ fromId: "a", toId: "u" }, ["u"]), {
    fromId: "u",
    toId: "",
  });
  assert.deepEqual(reconcileMoveSource({ fromId: "a", toId: "b" }, ["u", "a"]), {
    fromId: "a",
    toId: "b",
  });
  assert.deepEqual(reconcileMoveSource({ fromId: "", toId: "" }, ["a", "u"]), {
    fromId: "a",
    toId: "",
  });
  assert.deepEqual(reconcileMoveSource({ fromId: "a", toId: "b" }, []), { fromId: "", toId: "" });
  const dialog = read("src/components/inventory/ItemLocationsDialog.tsx");
  assert.match(dialog, /reconcileMoveSource\(\{ fromId, toId \}/);
});

// ---------------------------------------------------------------------------------------
// Rendered UI.
// ---------------------------------------------------------------------------------------
const page: CountPage = {
  location: { id: "loc", name: "Training Room Cabinet A", lastCountedAt: null },
  items: [tape, gauze, empty, archived],
};
const formProps = { page, onSubmit: noop, onReload: () => {}, onDone: () => {}, onBack: () => {} };

test("count form: every item, system quantity prefilled, decimal text inputs, no prices", () => {
  const html = render(ui.InventoryCountForm, formProps);
  assert.match(html, /Physical inventory count/);
  assert.match(html, /Training Room Cabinet A/);
  assert.match(html, /Not counted yet/);
  for (const name of ["Athletic Tape", "Gauze", "Ice Packs", "Old Splints"])
    assert.ok(html.includes(name), name);
  assert.equal(html.match(/inputMode="decimal"/g)?.length, 4);
  assert.doesNotMatch(html, /type="number"/);
  assert.match(html, /value="2\.75"/);
  assert.match(html, /value="0"/);
  assert.match(html, /Archived/);
  assert.match(html, /Saving confirms you counted all 4/);
  assert.match(html, /0<\/span> changed · <span[^>]*>4<\/span> unchanged/);
  assert.match(html, /Review &amp; save/);
  assert.doesNotMatch(html, /\$|price|vendor|budget/i);
});

test("count form: changed lines summarized; blank fields are errors, not zero", () => {
  const changed = render(ui.InventoryCountForm, {
    ...formProps,
    initialEntries: {
      [tape.inventoryItemId]: "9",
      [gauze.inventoryItemId]: "2.75",
      [empty.inventoryItemId]: "3",
      [archived.inventoryItemId]: "5.5",
    },
  });
  assert.match(changed, /3<\/span> changed · <span[^>]*>1<\/span> unchanged/);
  const confirming = render(ui.InventoryCountForm, {
    ...formProps,
    initialPhase: "confirming",
    initialEntries: {
      [tape.inventoryItemId]: "9",
      [gauze.inventoryItemId]: "2.75",
      [empty.inventoryItemId]: "3",
      [archived.inventoryItemId]: "5",
    },
  });
  assert.match(confirming, /Save this count\?/);
  assert.match(
    confirming,
    /You checked all 4 items here\. 2 quantities will change; 2 stay the same\./,
  );
  const changedList = confirming.slice(confirming.indexOf('data-testid="changed-items"'));
  assert.match(changedList, /Athletic Tape/);
  assert.match(changedList, /Ice Packs/);
  assert.doesNotMatch(
    changedList.slice(0, changedList.indexOf("</ul>")),
    /Gauze|Old Splints/,
    "only changed items are listed",
  );
  assert.match(changedList, /−3/);
  assert.match(changedList, /\+3/);
  const allSame = render(ui.CountConfirmation, {
    review: reviewCount(page.items, initialCountEntries(page.items)),
    total: 4,
    saving: false,
    onConfirm: () => {},
    onCancel: () => {},
  });
  assert.match(allSame, /Every quantity matches the system/);
  const saving = render(ui.CountConfirmation, {
    review: reviewCount(page.items, initialCountEntries(page.items)),
    total: 4,
    saving: true,
    onConfirm: () => {},
    onCancel: () => {},
  });
  assert.equal(saving.match(/disabled=""/g)?.length, 2, "no double submit while saving");
  assert.match(saving, /Saving…/);
});

test("count form: stale, empty and saved states", () => {
  const stale = render(ui.InventoryCountForm, { ...formProps, initialPhase: "stale" });
  assert.match(
    stale,
    /Inventory changed while you were counting\. Reload this location and confirm the quantities again\./,
  );
  assert.match(stale, /Reload this location/);
  assert.doesNotMatch(stale, /Review &amp; save/, "a stale count cannot be saved");
  const nothing = render(ui.InventoryCountForm, { ...formProps, page: { ...page, items: [] } });
  assert.match(nothing, /Nothing is stocked here/);
  assert.doesNotMatch(nothing, /Review &amp; save/);
  const saved = render(ui.CountSuccess, {
    summary: {
      sessionId: "s",
      locationId: "loc",
      locationName: "Training Room Cabinet A",
      submittedAt: "2026-10-27T15:04:00Z",
      lineCount: 10,
      changedCount: 3,
      replayed: false,
    },
    onDone: () => {},
    onBack: () => {},
  });
  assert.match(saved, /Inventory count saved/);
  assert.match(saved, /Training Room Cabinet A/);
  assert.match(saved, /Items counted<\/dt><dd[^>]*>10</);
  assert.match(saved, /Adjusted<\/dt><dd[^>]*>3</);
  assert.match(saved, />Done</);
  assert.match(saved, /Back to Staff Workspace/);
  const admin = render(ui.CountSuccess, {
    summary: {
      sessionId: "s",
      locationId: "loc",
      locationName: "X",
      submittedAt: "2026-10-27T15:04:00Z",
      lineCount: 1,
      changedCount: 0,
      replayed: true,
    },
    onDone: () => {},
    onBack: () => {},
    backLabel: "Back to dashboard",
  });
  assert.match(admin, /Back to dashboard/);
});

test("scanner: start, denied, unsupported and unavailable all leave a way forward", () => {
  const idle = render(ui.QrScannerView, { state: "idle", onStart: () => {} });
  assert.match(idle, /Start camera/);
  assert.match(idle, /playsInline=""/);
  assert.match(idle, /muted=""/);
  const scanning = render(ui.QrScannerView, {
    state: "scanning",
    onStart: () => {},
    notice: "That QR code isn't a SportSpend inventory label.",
  });
  assert.match(scanning, /isn&#x27;t a SportSpend inventory label/);
  const denied = render(ui.QrScannerView, { state: "denied", onStart: () => {} });
  assert.match(denied, /Camera access is blocked/);
  assert.match(denied, /Try again/);
  assert.match(denied, /Use your phone&#x27;s camera instead/);
  const unsupported = render(ui.QrScannerView, { state: "unsupported", onStart: () => {} });
  assert.match(unsupported, /This browser can&#x27;t scan here/);
  assert.doesNotMatch(unsupported, /Try again/);
  assert.match(unsupported, /Open the Camera app/);
  assert.match(
    render(ui.QrScannerView, { state: "unavailable", onStart: () => {} }),
    /No camera found/,
  );
});

test("location fallback lists names only; unavailable labels name nothing", () => {
  const html = render(ui.CountLocationPicker, {
    locations: [
      { id: "a", name: "Cabinet A", lastCountedAt: "2026-10-20T12:00:00Z" },
      { id: "b", name: "Rehab Closet", lastCountedAt: null },
    ],
    loading: false,
    error: null,
    onRetry: () => {},
    onSelect: () => {},
  });
  assert.match(html, /No label handy\? Choose the location/);
  assert.match(html, /Cabinet A/);
  assert.match(html, /Not counted yet/);
  const none = render(ui.CountLocationPicker, {
    locations: [],
    loading: false,
    error: null,
    onRetry: () => {},
    onSelect: () => {},
  });
  assert.match(none, /No storage locations are set up yet/);
  const unavailable = render(ui.CountUnavailable, {
    message: labelUnavailableMessage("unavailable"),
    onBack: () => {},
  });
  assert.match(unavailable, /Can&#x27;t open this count/);
  assert.doesNotMatch(unavailable, /Cabinet|organization [A-Z]/);
});

// Phase 7B.1 moved the owner label controls from a dialog into the location's Labels tab;
// tests/phase7b1-inventory-admin-workspace.test.ts covers revoke-only and admin read-only.
test("owner QR labels: issue, print, replace; the locations table shows labels and last count", () => {
  const owner = {
    id: "a",
    name: "Cabinet A",
    description: null,
    kind: "storage",
    active: true,
    stockedItemCount: 1,
    countableItemCount: 1,
    lastCountedAt: null,
    lastCountedByName: null,
    activeLabelCount: 0,
    lastLabelIssuedAt: null,
  };
  const panel = (location: typeof owner, extra: Record<string, unknown> = {}) =>
    render(ui.LocationLabelsPanel, {
      location,
      canManage: true,
      origin: "https://app.sport-spend.com",
      onIssue: noop,
      onReplace: noop,
      onRevoke: noop,
      ...extra,
    });
  const fresh = panel(owner);
  assert.match(fresh, /QR labels/);
  assert.match(fresh, /Issue QR label/);
  assert.match(fresh, /works only for signed-in members of your organization/);
  assert.doesNotMatch(fresh, /Replace labels/);
  const issued = panel(
    { ...owner, activeLabelCount: 2, lastLabelIssuedAt: "2026-10-20T12:00:00Z" },
    {
      initialIssued: {
        url: `https://app.sport-spend.com/count/${token}`,
        svg: '<svg data-qr="1"></svg>',
      },
    },
  );
  assert.match(issued, /<svg data-qr="1"><\/svg>/);
  assert.match(issued, new RegExp(`/count/${token}`));
  assert.match(issued, /Print label/);
  assert.match(issued, /Active labels<\/dt><dd[^>]*>2</);
  assert.match(issued, /Issue another label/);
  assert.match(issued, /Replace labels…/);
  assert.match(issued, /to print another copy later, issue another label/i);
  const row = (id: string, name: string, kind: string, active = true) => ({
    ...owner,
    id,
    name,
    kind,
    active,
    countableItemCount: kind === "unassigned" ? null : 1,
    activeLabelCount: kind === "unassigned" ? null : 1,
  });
  const table = render(ui.LocationsTable, {
    locations: [
      row("u", "Unassigned", "unassigned"),
      { ...row("a", "Cabinet A", "storage"), lastCountedAt: "2026-10-20T12:00:00Z" },
      row("z", "Old Bin", "storage", false),
    ],
    canManage: true,
    now: new Date("2026-10-23T12:00:00Z"),
  });
  assert.match(table, /Counted 3 days ago/);
  assert.match(table, /Oct 20, 2026/);
  assert.match(table, /Not counted yet/);
  assert.match(table, /Not counted or labeled/, "Unassigned is never counted or labeled");
});

test("Staff Workspace offers Scan Inventory QR beside Request Supplies, with no inventory data", () => {
  const requestSupplies = staffHome.indexOf('id="request-supplies-title"');
  const scan = staffHome.indexOf('to="/count"');
  const myRequests = staffHome.indexOf('aria-labelledby="my-requests-title"');
  assert.ok(
    requestSupplies > 0 && scan > requestSupplies && scan < myRequests,
    "right after Request Supplies",
  );
  assert.match(staffHome, /Scan Inventory QR/);
  assert.doesNotMatch(staffHome, /CountLocationView|getCountLocationFn|inventory_location/);
  assert.doesNotMatch(
    read("src/components/staff/StaffBottomNav.tsx"),
    /"\/count/,
    "no new bottom-nav item",
  );
});

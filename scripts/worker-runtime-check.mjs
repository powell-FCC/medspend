// Loads the BUILT production server (.output/server, the files Workers Builds deploys) into the
// Cloudflare Workers runtime (workerd, through Miniflare) and exercises the invoice-batch server
// functions and pdf-lib there. A successful `vite build` proves nothing about this: the
// production failure (pdf-lib's tslib default import, 2026-11-10) only appeared when the module
// was evaluated by the Worker.
//
// Checks, each reported as ok / failed:
//   * every invoice-batch server function module loads through the server-fn resolver, exactly as
//     a request to /_serverFn/<id> loads it (list, get, provenance, release, intake, process)
//   * pdf-lib: PDFDocument.create() + addPage + save, then the saved bytes load again
//   * structure: no batch server-function module reaches pdf-lib through static imports (only the
//     packet-processing path loads it, on demand), so a pdf-lib failure cannot break the others
//   * with --packet <pdf>: load the packet and build page-subset PDFs (the real segment ranges),
//     each reloaded and its page count checked
//   * a full request to the production entry for listInvoiceBatchesFn (no session): it must be
//     refused by the auth middleware ("Unauthorized"), not crash with the generic error page
//
// Usage: node scripts/worker-runtime-check.mjs [--server-dir .output/server] [--packet file.pdf]
//        [--ranges 1-1,4-5,7-10]
// Requires MEDSPEND_MINIFLARE (path to a miniflare package directory); see
// scripts/worker-runtime-check.sh, which installs the pinned Wrangler release that provides it.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(name);
  return index === -1 ? fallback : args[index + 1];
};
const serverDir = resolve(option("--server-dir", ".output/server"));
const packetPath = option("--packet", null);
const ranges = option("--ranges", "1-1,4-5,7-10");
const miniflareDir = process.env.MEDSPEND_MINIFLARE;
if (!miniflareDir) throw new Error("Set MEDSPEND_MINIFLARE to a miniflare package directory");
const { Miniflare } = await import(pathToFileURL(join(miniflareDir, "dist/src/index.js")).href);

const files = [];
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path);
    else if (path.endsWith(".mjs")) files.push(path);
  }
};
walk(serverDir);
const resolverFile = files.find((file) => /tanstack-start-server-fn-resolver/.test(file));
if (!resolverFile) throw new Error("server-fn resolver chunk not found in the build");
// id -> handler name, read from the built resolver (the same table a /_serverFn/<id> request uses).
const serverFnIds = {};
for (const match of readFileSync(resolverFile, "utf8").matchAll(
  /"([0-9a-f]{64})": \{\s*functionName: "(\w+?)_createServerFn_handler"/g,
))
  serverFnIds[match[2]] = match[1];
const pdfLibFiles = files
  .filter((file) => /_libs\/[^/]*pdf-lib[^/]*\.mjs$/.test(file))
  .map((file) => "./" + relative(serverDir, file));

const entry = `
const batchFunctions = ["listInvoiceBatchesFn", "getInvoiceBatchFn", "getInvoiceProvenanceFn",
  "releaseInvoiceBatchSegmentFn", "intakeInvoiceUploadFn", "processInvoiceBatchFn"];
const pdfLibFiles = ${JSON.stringify(pdfLibFiles)};
const ids = ${JSON.stringify(serverFnIds)};
async function check(name, run) {
  try { return { name, ok: true, detail: await run() }; }
  catch (error) { return { name, ok: false, detail: String(error && error.stack || error) }; }
}
async function findPdfDocument() {
  for (const file of pdfLibFiles) {
    const module = await import(file);
    // A direct export, or (when pdf-lib is loaded lazily) inside the module namespace export.
    const candidates = Object.values(module).flatMap((value) =>
      value && typeof value === "object" ? [value.PDFDocument] : [value]);
    for (const value of candidates)
      if (typeof value === "function" && value.name === "PDFDocument" && typeof value.create === "function") return value;
  }
  throw new Error("PDFDocument export not found in " + pdfLibFiles.join(", "));
}
export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/server") {
      const { default: server } = await import("./index.mjs");
      const id = url.searchParams.get("id");
      const response = await server.fetch(new Request("https://app.example/_serverFn/" + id, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/x-tss-framed, application/x-ndjson, application/json", "x-tsr-serverFn": "true", origin: "https://app.example" },
        body: await request.text(),
      }), {}, { waitUntil() {}, passThroughOnException() {} });
      const body = await response.text();
      return Response.json({ status: response.status, errorPage: body.includes("This page didn't load"), body: body.slice(0, 600) });
    }
    const results = [];
    const resolver = await import("./${relative(serverDir, resolverFile)}");
    const getServerFnById = Object.values(resolver).find((value) => typeof value === "function");
    for (const name of batchFunctions) {
      results.push(await check("load " + name, async () => {
        const id = ids[name];
        if (!id) throw new Error("not in the server-fn resolver");
        if (typeof (await getServerFnById(id)) !== "function") throw new Error("handler is not a function");
        return id;
      }));
    }
    results.push(await check("pdf-lib create+save", async () => {
      const PDFDocument = await findPdfDocument();
      const doc = await PDFDocument.create();
      doc.addPage([200, 200]);
      const bytes = await doc.save();
      const again = await PDFDocument.load(bytes);
      if (again.getPageCount() !== 1) throw new Error("saved PDF did not reload with one page");
      return bytes.length + " bytes";
    }));
    if (request.method === "POST") {
      const packet = new Uint8Array(await request.arrayBuffer());
      results.push(await check("packet subsets", async () => {
        const PDFDocument = await findPdfDocument();
        const source = await PDFDocument.load(packet.slice(), { updateMetadata: false });
        const out = [];
        for (const range of url.searchParams.get("ranges").split(",")) {
          const [start, end] = range.split("-").map(Number);
          const subset = await PDFDocument.create({ updateMetadata: false });
          const indices = Array.from({ length: end - start + 1 }, (_, offset) => start - 1 + offset);
          for (const page of await subset.copyPages(source, indices)) subset.addPage(page);
          const bytes = await subset.save();
          const pages = (await PDFDocument.load(bytes)).getPageCount();
          if (pages !== indices.length) throw new Error(range + " produced " + pages + " pages");
          out.push(range + "=" + pages + "p/" + bytes.length + "B");
        }
        return source.getPageCount() + " source pages; " + out.join(" ");
      }));
    }
    return Response.json(results);
  },
};`;

// Static import graph of the built server: which chunks each batch function module evaluates.
const staticImports = (file) =>
  [
    ...readFileSync(file, "utf8").matchAll(
      /^(?:import|export)\b[^;]*?\bfrom\s*"(\.[^"]+)"|^import\s*"(\.[^"]+)"/gm,
    ),
  ].map((match) => resolve(dirname(file), match[1] ?? match[2]));
const reachesPdfLib = (file, seen = new Set()) => {
  if (seen.has(file)) return null;
  seen.add(file);
  if (/_libs\/[^/]*pdf-lib/.test(file)) return [file];
  for (const next of staticImports(file)) {
    const path = reachesPdfLib(next, seen);
    if (path) return [file, ...path];
  }
  return null;
};
const resolverSource = readFileSync(resolverFile, "utf8");
let structureFailed = false;
for (const name of [
  "listInvoiceBatchesFn",
  "getInvoiceBatchFn",
  "getInvoiceProvenanceFn",
  "releaseInvoiceBatchSegmentFn",
  "intakeInvoiceUploadFn",
  "processInvoiceBatchFn",
]) {
  const id = serverFnIds[name];
  const importer =
    id && resolverSource.match(new RegExp(`"${id}": \\{[^}]*?import\\("([^"]+)"\\)`))?.[1];
  if (!importer) {
    console.log(`FAIL static imports ${name}: not in the server-fn resolver`);
    structureFailed = true;
    continue;
  }
  const path = reachesPdfLib(resolve(dirname(resolverFile), importer));
  console.log(
    `${path ? "FAIL" : "ok  "} static imports ${name}: ${path ? "reaches pdf-lib via " + path.map((file) => relative(serverDir, file)).join(" -> ") : "pdf-lib not loaded until used"}`,
  );
  structureFailed ||= Boolean(path);
}

const modules = [
  { type: "ESModule", path: join(serverDir, "__worker_runtime_check.mjs"), contents: entry },
  ...files.map((path) => ({ type: "ESModule", path, contents: readFileSync(path, "utf8") })),
];
const config = JSON.parse(readFileSync(join(serverDir, "wrangler.json"), "utf8"));
const worker = {
  name: "medspend-runtime-check",
  modules,
  modulesRoot: serverDir,
  compatibilityDate: config.compatibility_date,
  compatibilityFlags: config.compatibility_flags,
  // Placeholders so the auth middleware can run; nothing listens on this address and no request
  // carries a session, so nothing ever reaches a real Supabase project.
  bindings: { SUPABASE_URL: "http://127.0.0.1:9", SUPABASE_PUBLISHABLE_KEY: "local-runtime-check" },
};
// Miniflare 5 takes a list of workers; Miniflare 4 takes one worker's options at the top level.
let mf;
try {
  mf = new Miniflare({ workers: [worker] });
} catch {
  mf = new Miniflare(worker);
}
let failed = structureFailed;
try {
  const init = packetPath ? { method: "POST", body: readFileSync(packetPath) } : undefined;
  const response = await mf.dispatchFetch(
    `http://check/?ranges=${encodeURIComponent(ranges)}`,
    init,
  );
  const results = await response.json();
  for (const result of results) {
    console.log(`${result.ok ? "ok  " : "FAIL"} ${result.name}: ${result.detail}`);
    failed ||= !result.ok;
  }
  const listId = serverFnIds.listInvoiceBatchesFn;
  if (listId) {
    // The payload exactly as the browser client serializes it (TanStack Start uses seroval).
    const { toJSONAsync } = await import("seroval");
    const payload = JSON.stringify(
      await toJSONAsync({ data: { organizationId: "00000000-0000-4000-8000-000000000000" } }),
    );
    const server = await (
      await mf.dispatchFetch(`http://check/server?id=${listId}`, { method: "POST", body: payload })
    ).json();
    // Without a session the function must load and be refused by requireSupabaseAuth
    // ("Unauthorized: ..."), not crash with the generic error page.
    const refused = !server.errorPage && server.body.includes("Unauthorized");
    console.log(
      `${refused ? "ok  " : "FAIL"} unauthenticated listInvoiceBatchesFn request: HTTP ${server.status}${server.errorPage ? " (generic error page)" : ""} ${server.body.replace(/\s+/g, " ").slice(0, 160)}`,
    );
    failed ||= !refused;
  } else {
    console.log("FAIL unauthenticated listInvoiceBatchesFn request: not in the server-fn resolver");
    failed = true;
  }
} finally {
  await mf.dispose();
}
process.exit(failed ? 1 : 0);

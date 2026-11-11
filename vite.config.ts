// @lovable.dev/vite-tanstack-config already includes the following — do NOT add them manually
// or the app will break with duplicate plugins:
//   - TanStack devtools (dev-only, first), tanstackStart, viteReact, tailwindcss, tsConfigPaths,
//     nitro (build-only using cloudflare as a default target), VITE_* env injection, @ path alias,
//     React/TanStack dedupe, error logger plugins, and sandbox detection (port/host/strictPort).
// You can pass additional config via defineConfig({ vite: { ... }, etc... }) if needed.
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { defineConfig } from "@lovable.dev/vite-tanstack-config";
import type { Plugin } from "vite";

const PDF_LIB_IMPORTER = /[\\/]node_modules[\\/]pdf-lib[\\/]/;

/**
 * pdf-lib 1.17.1 imports tslib 1.x. tslib 1.14's "import" export (modules/index.js) default-imports
 * its own CommonJS build, which the Vite 8.0 server build emits as
 * `__toESM(require_tslib()).default` without Node interop. tslib.js marks itself __esModule, so
 * that default is undefined in the Worker and evaluating pdf-lib throws
 * "Cannot destructure property '__extends'" (production, 2026-11-10). Vite 8.2+ (Rolldown 1.2)
 * no longer emits this, so remove this plugin once the toolchain is on 8.2 or later.
 *
 * Server builds resolve pdf-lib's tslib import to the same tslib package's pure-ESM build
 * (tslib.es6.js, its "module" entry): identical helpers, no CommonJS interop. Only pdf-lib's
 * imports and only server environments are affected; pdf-lib is never in client bundles.
 */
function pdfLibTslibEsm(): Plugin {
  return {
    name: "medspend:pdf-lib-tslib-esm",
    enforce: "pre",
    applyToEnvironment: (environment) => environment.config.consumer === "server",
    resolveId(source, importer) {
      if (source !== "tslib" || !importer || !PDF_LIB_IMPORTER.test(importer)) return null;
      // The tslib copy pdf-lib itself resolves (its CommonJS main sits in the package root).
      const tslibMain = createRequire(importer).resolve("tslib");
      return join(dirname(tslibMain), "tslib.es6.js");
    },
  };
}

export default defineConfig({
  plugins: [pdfLibTslibEsm()],
  // Nitro runtime plugins (server only). The Phase 6C.3 plugin handles the Worker's scheduled
  // event; the cron trigger is declared in wrangler.jsonc. The wrapper passes this object to
  // nitro() unchanged (merged over its cloudflare-module default preset); its type only lists
  // preset/output/cloudflare, hence the cast.
  nitro: { plugins: ["./src/server/notification-scheduler.ts"] } as { preset?: string },
  tanstackStart: {
    // Redirect TanStack Start's bundled server entry to src/server.ts (our SSR error wrapper).
    // nitro/vite builds from this
    server: { entry: "server" },
  },
});

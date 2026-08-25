#!/usr/bin/env node

import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  createSupabaseCatalogStore,
  executePreparedImport,
  loadPreparedImport,
  runPreflight,
  writeImportPlan,
  type CatalogStore,
} from "./importer.ts";

export type CliOptions = {
  mode: "dry-run" | "execute";
  confirmProductionImport: boolean;
  resumeIncomplete: boolean;
  preflightLive: boolean;
  inputDir: string;
  outputDir: string;
  help: boolean;
};

const DEFAULT_INPUT_DIR = "outputs/catalog/henry-schein/v28";

export function parseCliArgs(argv: string[], cwd = process.cwd()): CliOptions {
  let mode: CliOptions["mode"] = "dry-run";
  let sawDryRun = false;
  let sawExecute = false;
  let confirmProductionImport = false;
  let resumeIncomplete = false;
  let preflightLive = false;
  let inputDir = path.resolve(cwd, DEFAULT_INPUT_DIR);
  let outputDir: string | null = null;
  let help = false;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--dry-run") {
      sawDryRun = true;
      mode = "dry-run";
    } else if (argument === "--execute") {
      sawExecute = true;
      mode = "execute";
    } else if (argument === "--confirm-production-import") {
      confirmProductionImport = true;
    } else if (argument === "--resume-incomplete") {
      resumeIncomplete = true;
    } else if (argument === "--preflight-live") {
      preflightLive = true;
    } else if (argument === "--input-dir" || argument === "--output-dir") {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) {
        throw new Error(`${argument} requires a path`);
      }
      index += 1;
      if (argument === "--input-dir") inputDir = path.resolve(cwd, value);
      else outputDir = path.resolve(cwd, value);
    } else if (argument === "--help" || argument === "-h") {
      help = true;
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }

  if (sawDryRun && sawExecute) {
    throw new Error("--dry-run and --execute are mutually exclusive");
  }
  outputDir ??= path.join(inputDir, "import-plan");
  return {
    mode,
    confirmProductionImport,
    resumeIncomplete,
    preflightLive,
    inputDir,
    outputDir,
    help,
  };
}

export function assertCliSafety(options: CliOptions, environment: NodeJS.ProcessEnv): void {
  if (options.confirmProductionImport && options.mode !== "execute") {
    throw new Error("--confirm-production-import is valid only with --execute");
  }
  if (options.resumeIncomplete && options.mode !== "execute") {
    throw new Error("--resume-incomplete is valid only with --execute");
  }
  if (options.mode === "execute" && !options.confirmProductionImport) {
    throw new Error("Execute mode requires --confirm-production-import");
  }
  const liveAccessRequired = options.mode === "execute" || options.preflightLive;
  if (liveAccessRequired) {
    const missing = [
      ...(!environment.SUPABASE_URL ? ["SUPABASE_URL"] : []),
      ...(!environment.SUPABASE_SERVICE_ROLE_KEY ? ["SUPABASE_SERVICE_ROLE_KEY"] : []),
    ];
    if (missing.length > 0) {
      throw new Error(
        `${options.mode === "execute" ? "Execute mode" : "Live preflight"} requires service-role environment variable(s): ${missing.join(", ")}`,
      );
    }
  }
}

function usage(): string {
  return `Henry Schein v28 catalog importer

Usage:
  node scripts/catalog/henry-schein/import.ts [options]

Options:
  --dry-run                    Validate and write an offline import plan (default)
  --preflight-live             Add read-only live catalog classification
  --execute                    Enable the guarded mutation path
  --confirm-production-import  Required with --execute
  --resume-incomplete          Explicitly resume an equivalent failed/incomplete batch
  --input-dir PATH             Override the Phase 5A.4B artifact directory
  --output-dir PATH            Override the import-plan directory
  --help                       Show this help
`;
}

export async function runCli(
  argv: string[],
  dependencies: {
    environment?: NodeJS.ProcessEnv;
    createStore?: () => Promise<CatalogStore>;
    log?: (message: string) => void;
  } = {},
): Promise<{ mode: string; result: string; mutationCalls: number; planFiles: string[] }> {
  const options = parseCliArgs(argv);
  if (options.help) {
    (dependencies.log ?? console.log)(usage());
    return { mode: "help", result: "help", mutationCalls: 0, planFiles: [] };
  }
  const environment = dependencies.environment ?? process.env;
  assertCliSafety(options, environment);
  const prepared = loadPreparedImport(options.inputDir);
  const needsStore = options.preflightLive || options.mode === "execute";
  const store = needsStore
    ? await (dependencies.createStore ?? createSupabaseCatalogStore)()
    : undefined;
  const preflight = await runPreflight(prepared, store);
  const planFiles = writeImportPlan(options.outputDir, prepared, preflight);

  if (options.mode === "dry-run") {
    const result = {
      mode: "dry-run",
      result: preflight.result,
      databaseMode: preflight.databaseMode,
      manifestSha256: prepared.manifestSha256,
      plannedInsertedRows: preflight.plannedMutations.insertedRows,
      mutationCalls: store?.mutationCalls ?? 0,
      planFiles,
    };
    (dependencies.log ?? console.log)(JSON.stringify(result, null, 2));
    return {
      mode: result.mode,
      result: result.result,
      mutationCalls: result.mutationCalls,
      planFiles,
    };
  }

  if (preflight.result !== "PASS") {
    throw new Error("Execute mode blocked by preflight conflicts");
  }
  if (!store) throw new Error("Execute mode requires a catalog store");
  const execution = await executePreparedImport(prepared, store, {
    resumeIncomplete: options.resumeIncomplete,
  });
  const result = {
    mode: "execute",
    result: execution.result,
    mutationCalls: execution.mutationCalls,
    reconciliation: execution.reconciliation.result,
    planFiles,
  };
  (dependencies.log ?? console.log)(JSON.stringify(result, null, 2));
  return {
    mode: result.mode,
    result: result.result,
    mutationCalls: result.mutationCalls,
    planFiles,
  };
}

const isMain = process.argv[1]
  ? import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
  : false;

if (isMain) {
  runCli(process.argv.slice(2)).catch((error) => {
    console.error(
      `Henry Schein import failed: ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 1;
  });
}

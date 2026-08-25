import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  CATALOG_TABLES,
  EXPECTED_COUNTS,
  EXPECTED_MANIFEST_SHA256,
  ImportCollisionError,
  ImportValidationError,
  assertReconciliationReport,
  canonicalJson,
  chunkRows,
  classifyRows,
  deterministicId,
  executePreparedImport,
  freshPlannedMutations,
  loadPreparedImport,
  reconcileImportedCatalog,
  runPreflight,
  uuidV5,
  type CatalogStore,
  type CatalogTable,
  type DbRow,
  type PreparedImport,
  type ReadCountTable,
} from "../scripts/catalog/henry-schein/importer.ts";
import { assertCliSafety, parseCliArgs, runCli } from "../scripts/catalog/henry-schein/import.ts";

const repository = process.cwd();
const inputDir = path.join(repository, "outputs/catalog/henry-schein/v28");
const prepared = loadPreparedImport(inputDir);

function cloneRows(rows: DbRow[]): DbRow[] {
  return structuredClone(rows);
}

class MemoryCatalogStore implements CatalogStore {
  mutationCalls = 0;
  readonly tables = new Map<string, DbRow[]>();
  readonly batchStatuses: string[] = [];
  failInsertTable: CatalogTable | null = null;

  constructor(seed: Partial<Record<CatalogTable, DbRow[]>> = {}) {
    for (const table of CATALOG_TABLES) this.tables.set(table, cloneRows(seed[table] ?? []));
    this.tables.set("catalog_categories", []);
  }

  rows(table: string): DbRow[] {
    return this.tables.get(table) ?? [];
  }

  async count(table: ReadCountTable): Promise<number> {
    return this.rows(table).length;
  }

  async findVendorsByNormalizedName(normalizedName: string): Promise<DbRow[]> {
    return cloneRows(
      this.rows("catalog_vendors").filter((row) => row.normalized_name === normalizedName),
    );
  }

  async findBatchesByArtifactSha(artifactSha256: string): Promise<DbRow[]> {
    return cloneRows(
      this.rows("catalog_import_batches").filter(
        (row) => String(row.artifact_sha256).toLowerCase() === artifactSha256.toLowerCase(),
      ),
    );
  }

  async findRowsByIds(table: CatalogTable, ids: string[]): Promise<DbRow[]> {
    const expected = new Set(ids);
    return cloneRows(this.rows(table).filter((row) => expected.has(row.id)));
  }

  async findVendorProductsBySkus(vendorId: string, normalizedSkus: string[]): Promise<DbRow[]> {
    const expected = new Set(normalizedSkus);
    return cloneRows(
      this.rows("catalog_vendor_products").filter(
        (row) =>
          row.catalog_vendor_id === vendorId && expected.has(row.normalized_vendor_sku as string),
      ),
    );
  }

  async findSourceRecordsByBatch(batchId: string): Promise<DbRow[]> {
    return cloneRows(
      this.rows("catalog_source_records")
        .filter((row) => row.import_batch_id === batchId)
        .sort((left, right) => (left.source_ordinal as number) - (right.source_ordinal as number)),
    );
  }

  async findOverridesByBatch(batchId: string): Promise<DbRow[]> {
    return cloneRows(
      this.rows("catalog_verification_overrides").filter((row) => row.import_batch_id === batchId),
    );
  }

  async findVendorProductsByVendor(vendorId: string): Promise<DbRow[]> {
    return cloneRows(
      this.rows("catalog_vendor_products").filter((row) => row.catalog_vendor_id === vendorId),
    );
  }

  async insert(table: CatalogTable, rows: DbRow[]): Promise<void> {
    this.mutationCalls += 1;
    if (this.failInsertTable === table) throw new Error(`forced ${table} insert failure`);
    const target = this.rows(table);
    const ids = new Set(target.map((row) => row.id));
    for (const row of rows) {
      if (ids.has(row.id)) throw new Error(`duplicate ${table} id ${row.id}`);
      target.push(structuredClone(row));
      ids.add(row.id);
    }
  }

  async updateBatch(batchId: string, values: Record<string, unknown>): Promise<void> {
    this.mutationCalls += 1;
    const row = this.rows("catalog_import_batches").find((candidate) => candidate.id === batchId);
    if (!row) throw new Error(`missing batch ${batchId}`);
    Object.assign(row, structuredClone(values));
    if (typeof values.status === "string") this.batchStatuses.push(values.status);
  }
}

function batchRow(status: string): DbRow {
  return { ...structuredClone(prepared.batch), status };
}

function completeSeed(source: PreparedImport, status = "completed") {
  return {
    catalog_vendors: [structuredClone(source.vendor)],
    catalog_import_batches: [{ ...structuredClone(source.batch), status }],
    catalog_products: cloneRows(source.products),
    catalog_vendor_products: cloneRows(source.vendorProducts),
    catalog_source_records: cloneRows(source.sourceRecords),
    catalog_verification_overrides: cloneRows(source.overrides),
  } satisfies Partial<Record<CatalogTable, DbRow[]>>;
}

test("importer defaults to offline dry-run mode", () => {
  const options = parseCliArgs([]);
  assert.equal(options.mode, "dry-run");
  assert.equal(options.preflightLive, false);
  assert.equal(options.confirmProductionImport, false);
});

test("execute requires the explicit production confirmation flag", () => {
  const options = parseCliArgs(["--execute"]);
  assert.throws(() => assertCliSafety(options, {}), /confirm-production-import/);
});

test("execute requires service-role credentials", () => {
  const options = parseCliArgs(["--execute", "--confirm-production-import"]);
  assert.throws(() => assertCliSafety(options, {}), /SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY/);
});

test("artifact checksum mismatch blocks validation", () => {
  const temporary = mkdtempSync(path.join(tmpdir(), "medspend-hs-import-hash-"));
  const manifest = JSON.parse(
    readFileSync(path.join(inputDir, "dry_run_manifest.json"), "utf8"),
  ) as { artifacts: Array<{ name: string }> };
  symlinkSync(
    path.join(inputDir, "dry_run_manifest.json"),
    path.join(temporary, "dry_run_manifest.json"),
  );
  for (const artifact of manifest.artifacts) {
    if (artifact.name === "catalog_vendor.json") {
      writeFileSync(path.join(temporary, artifact.name), '{"modified":true}\n');
    } else {
      symlinkSync(path.join(inputDir, artifact.name), path.join(temporary, artifact.name));
    }
  }
  try {
    assert.throws(() => loadPreparedImport(temporary), /checksum mismatch/i);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});

test("manifest identity mismatch blocks validation before artifact loading", () => {
  const temporary = mkdtempSync(path.join(tmpdir(), "medspend-hs-import-manifest-"));
  writeFileSync(path.join(temporary, "dry_run_manifest.json"), "{}\n");
  try {
    assert.throws(() => loadPreparedImport(temporary), /Manifest SHA-256 mismatch/);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});

test("reconciliation FAIL blocks promotion", () => {
  const report = structuredClone(prepared.logical.reconciliation);
  report.result = "FAIL";
  assert.throws(() => assertReconciliationReport(report), /not PASS/);
});

test("deterministic identities repeat exactly", () => {
  const again = loadPreparedImport(inputDir);
  assert.equal(prepared.manifestSha256, EXPECTED_MANIFEST_SHA256);
  assert.equal(prepared.ids.vendorId, again.ids.vendorId);
  assert.equal(prepared.ids.batchId, again.ids.batchId);
  assert.deepEqual([...prepared.ids.productIdsByKey], [...again.ids.productIdsByKey]);
  assert.deepEqual([...prepared.ids.vendorProductIdsByKey], [...again.ids.vendorProductIdsByKey]);
  assert.deepEqual([...prepared.ids.sourceIdsByKey], [...again.ids.sourceIdsByKey]);
  assert.deepEqual([...prepared.ids.overrideIdsByKey], [...again.ids.overrideIdsByKey]);
});

test("UUIDv5 implementation matches the RFC reference vector", () => {
  assert.equal(
    uuidV5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "www.widgets.com"),
    "21f7f8de-8051-5b89-8680-0195ef798b6a",
  );
});

test("unkeyed ordinals are exactly 9269 through 9321", () => {
  const ordinals = prepared.sourceRecords
    .filter((row) => row.resolution_status === "unkeyed")
    .map((row) => row.source_ordinal as number);
  assert.equal(ordinals.length, 53);
  assert.equal(Math.min(...ordinals), 9_269);
  assert.equal(Math.max(...ordinals), 9_321);
  assert.deepEqual(
    ordinals,
    Array.from({ length: 53 }, (_, index) => 9_269 + index),
  );
});

test("all source ordinals are exactly 1 through 9321", () => {
  const ordinals = prepared.sourceRecords.map((row) => row.source_ordinal as number);
  assert.equal(ordinals.length, EXPECTED_COUNTS.sources);
  assert.deepEqual(
    ordinals,
    Array.from({ length: 9_321 }, (_, index) => index + 1),
  );
});

test("same completed batch returns already-imported without mutation", async () => {
  const store = new MemoryCatalogStore(completeSeed(prepared));
  const result = await executePreparedImport(prepared, store, {
    resumeIncomplete: false,
    timestamp: "2026-08-25T12:00:00.000Z",
  });
  assert.equal(result.result, "already_imported");
  assert.equal(result.reconciliation.result, "PASS");
  assert.equal(store.mutationCalls, 0);
});

test("incomplete batch refuses by default", async () => {
  const store = new MemoryCatalogStore({
    catalog_vendors: [structuredClone(prepared.vendor)],
    catalog_import_batches: [batchRow("failed")],
  });
  await assert.rejects(
    executePreparedImport(prepared, store, { resumeIncomplete: false }),
    /resume-incomplete/,
  );
  assert.equal(store.mutationCalls, 0);
});

test("resume-incomplete adopts exact rows and inserts only missing rows", async () => {
  const exactProducts = cloneRows(prepared.products.slice(0, 7));
  const store = new MemoryCatalogStore({
    catalog_vendors: [structuredClone(prepared.vendor)],
    catalog_import_batches: [batchRow("failed")],
    catalog_products: exactProducts,
  });
  const result = await executePreparedImport(prepared, store, {
    resumeIncomplete: true,
    timestamp: "2026-08-25T12:00:00.000Z",
  });
  assert.equal(result.result, "completed");
  assert.equal(store.rows("catalog_products").length, EXPECTED_COUNTS.products);
  assert.equal(store.rows("catalog_source_records").length, EXPECTED_COUNTS.sources);
  assert.deepEqual(store.batchStatuses.slice(-2), ["processing", "completed"]);
});

test("conflicting existing canonical product blocks import", async () => {
  const conflictingProduct = { ...structuredClone(prepared.products[0]), name: "Wrong product" };
  const store = new MemoryCatalogStore({
    catalog_vendors: [structuredClone(prepared.vendor)],
    catalog_import_batches: [batchRow("failed")],
    catalog_products: [conflictingProduct],
  });
  await assert.rejects(
    executePreparedImport(prepared, store, { resumeIncomplete: true }),
    ImportCollisionError,
  );
  assert.equal(store.mutationCalls, 0);
});

test("conflicting vendor-product is classified without overwrite", () => {
  const expected = prepared.vendorProducts[0];
  const actual = { ...structuredClone(expected), package_quantity: 999 };
  const result = classifyRows("catalog_vendor_products", [expected], [actual]);
  assert.equal(result.conflicts.length, 1);
  assert.equal(result.conflicts[0].differences[0].field, "package_quantity");
});

test("conflicting immutable source record is classified without overwrite", () => {
  const expected = prepared.sourceRecords[0];
  const actual = { ...structuredClone(expected), raw_product_name: "Changed raw source" };
  const result = classifyRows("catalog_source_records", [expected], [actual]);
  assert.equal(result.conflicts.length, 1);
  assert.equal(result.conflicts[0].differences[0].field, "raw_product_name");
});

test("conflicting verification override is classified without overwrite", () => {
  const expected = prepared.overrides[0];
  const actual = { ...structuredClone(expected), production_rule: "CONFLICT" };
  const result = classifyRows("catalog_verification_overrides", [expected], [actual]);
  assert.equal(result.conflicts.length, 1);
  assert.equal(result.conflicts[0].differences[0].field, "production_rule");
});

test("exact-existing rows are adopted safely", () => {
  const expected = prepared.products[0];
  const result = classifyRows("catalog_products", [expected], [structuredClone(expected)]);
  assert.equal(result.exact.length, 1);
  assert.equal(result.missing.length, 0);
  assert.equal(result.conflicts.length, 0);
});

test("held SKUs remain unpromoted while their override audits remain", () => {
  const held = ["128-5851", "570-0663", "570-0664", "570-0665", "570-0666"];
  const promoted = new Set(
    prepared.vendorProducts.map((row) => row.normalized_vendor_sku as string),
  );
  assert.deepEqual(
    held.filter((sku) => promoted.has(sku)),
    [],
  );
  assert.deepEqual(
    held.filter((sku) =>
      prepared.overrides.some(
        (row) =>
          row.verified_vendor_sku === sku && row.production_rule === "HOLD FOR SECOND SOURCE",
      ),
    ),
    held,
  );
});

test("special historical and verified identities are preserved", () => {
  const vendorProducts = new Map(
    prepared.vendorProducts.map((row) => [row.normalized_vendor_sku, row]),
  );
  const products = new Map(prepared.logical.productRows.map((row) => [row.source_vendor_sku, row]));
  assert.equal(vendorProducts.get("364-0444")?.active, false);
  assert.equal(vendorProducts.get("364-0444")?.discontinued, true);
  assert.equal(products.get("128-5852")?.name, "Good'N'Cheap Athletic Underwrap / Prewrap");
  assert.equal(products.get("128-5853")?.name, "Good'N'Cheap Adhesive Stretch Tape");
  assert.equal(products.get("139-7157")?.manufacturer, "Felix Storch (Summit)");
});

test("dry-run live preflight makes zero mutation calls", async () => {
  const temporary = mkdtempSync(path.join(tmpdir(), "medspend-hs-import-plan-"));
  const store = new MemoryCatalogStore();
  try {
    const result = await runCli(
      ["--preflight-live", "--input-dir", inputDir, "--output-dir", temporary],
      {
        environment: {
          SUPABASE_URL: "https://example.supabase.co",
          SUPABASE_SERVICE_ROLE_KEY: "test-only",
        },
        createStore: async () => store,
        log: () => undefined,
      },
    );
    assert.equal(result.result, "PASS");
    assert.equal(result.mutationCalls, 0);
    assert.equal(store.mutationCalls, 0);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});

test("importer target allowlist contains no organization-scoped tables", () => {
  assert.deepEqual(
    [...CATALOG_TABLES],
    [
      "catalog_vendors",
      "catalog_products",
      "catalog_vendor_products",
      "catalog_import_batches",
      "catalog_source_records",
      "catalog_verification_overrides",
    ],
  );
  assert.equal(
    CATALOG_TABLES.some((table) => table.includes("organization")),
    false,
  );
});

test("post-import reconciliation is required before the completion update", () => {
  const source = readFileSync(
    path.join(repository, "scripts/catalog/henry-schein/importer.ts"),
    "utf8",
  );
  const reconciliation = source.indexOf(
    'const reconciliation = await reconcileImportedCatalog(store, prepared, "processing")',
  );
  const completion = source.indexOf('status: "completed"', reconciliation);
  assert.ok(reconciliation >= 0);
  assert.ok(completion > reconciliation);
  assert.match(source.slice(reconciliation, completion), /reconciliation\.result !== "PASS"/);
});

test("a write failure cannot mark the batch completed", async () => {
  const store = new MemoryCatalogStore();
  store.failInsertTable = "catalog_verification_overrides";
  await assert.rejects(
    executePreparedImport(prepared, store, {
      resumeIncomplete: false,
      timestamp: "2026-08-25T12:00:00.000Z",
    }),
    /forced catalog_verification_overrides insert failure/,
  );
  assert.equal(store.batchStatuses.includes("completed"), false);
  assert.equal(store.batchStatuses.at(-1), "failed");
});

test("fresh mutation arithmetic is exactly 27,474 rows", () => {
  const plan = freshPlannedMutations();
  assert.equal(plan.insertedRows, 27_474);
  assert.equal(
    plan.vendor.insert +
      plan.batch.insert +
      plan.products.insert +
      plan.vendorProducts.insert +
      plan.sourceRecords.insert +
      plan.overrides.insert,
    27_474,
  );
  assert.equal(plan.finalBatchCompletionUpdates, 1);
});

test("chunking preserves deterministic input ordering", () => {
  const rows = Array.from({ length: 11 }, (_, index) => ({
    id: deterministicId(`chunk-test:${index.toString().padStart(2, "0")}`),
    ordinal: index + 1,
  }));
  const chunks = chunkRows(rows, 4);
  assert.deepEqual(
    chunks.map((chunk) => chunk.length),
    [4, 4, 3],
  );
  assert.deepEqual(
    chunks.flat().map((row) => row.ordinal),
    rows.map((row) => row.ordinal),
  );
});

test("match keys never drive identity or merging", async () => {
  const unrelated = {
    ...structuredClone(prepared.vendorProducts[0]),
    id: deterministicId("unrelated-vendor-product"),
    vendor_sku: "1000145",
    normalized_vendor_sku: "1000145",
    vendor_sku_match_key: prepared.vendorProducts[0].vendor_sku_match_key,
  };
  const store = new MemoryCatalogStore({
    catalog_vendors: [structuredClone(prepared.vendor)],
    catalog_vendor_products: [unrelated],
  });
  const preflight = await runPreflight(prepared, store);
  assert.equal(preflight.conflicts.length, 0);
  assert.equal(preflight.state.classifications?.catalog_vendor_products.exact.length, 0);
  assert.equal(
    canonicalJson(unrelated.vendor_sku_match_key),
    canonicalJson(prepared.vendorProducts[0].vendor_sku_match_key),
  );
});

test("database reconciliation rejects missing rows", async () => {
  const store = new MemoryCatalogStore(completeSeed(prepared, "processing"));
  store.rows("catalog_source_records").pop();
  const result = await reconcileImportedCatalog(store, prepared, "processing");
  assert.equal(result.result, "FAIL");
  assert.equal(result.assertions.find((item) => item.name === "source record count")?.pass, false);
});

test("manifest and special-case assertions all pass before any write", () => {
  assert.equal(prepared.manifestSha256, EXPECTED_MANIFEST_SHA256);
  assert.deepEqual(
    prepared.validationAssertions.filter((item) => !item.pass),
    [],
  );
  assert.deepEqual(
    prepared.specialAssertions.filter((item) => !item.pass),
    [],
  );
});

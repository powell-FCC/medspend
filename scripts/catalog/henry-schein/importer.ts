import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

export const IMPORTER_VERSION = "phase5a4c-1.0.0";
export const EXPECTED_MANIFEST_SHA256 =
  "64283966b4e444273b4b142c7c70e48c490116cd6c47078f12b36967f0ee572d";
export const WRITE_CHUNK_SIZE = 250;
export const CATALOG_TABLES = [
  "catalog_vendors",
  "catalog_products",
  "catalog_vendor_products",
  "catalog_import_batches",
  "catalog_source_records",
  "catalog_verification_overrides",
] as const;
export const READ_ONLY_COUNT_TABLES = [
  "catalog_vendors",
  "catalog_categories",
  "catalog_products",
  "catalog_vendor_products",
  "catalog_import_batches",
  "catalog_source_records",
  "catalog_verification_overrides",
] as const;

export const EXPECTED_COUNTS = {
  vendors: 1,
  batches: 1,
  products: 9_059,
  vendorProducts: 9_059,
  keyedSources: 9_268,
  unkeyedSources: 53,
  sources: 9_321,
  overrides: 33,
  uniqueRawSkus: 9_058,
  packageVerified: 7_614,
  packageSourceOnly: 1_099,
  packageUnknown: 346,
  matchKeyCollisionGroups: 0,
  rejected: 0,
  freshInsertedRows: 27_474,
} as const;

const EXPECTED_ARTIFACT_NAMES = [
  "catalog_products.csv",
  "catalog_source_records.jsonl",
  "catalog_vendor.json",
  "catalog_vendor_products.csv",
  "catalog_verification_overrides.jsonl",
  "import_batch.json",
  "package_normalization_review.csv",
  "reconciliation_report.json",
  "reconciliation_report.md",
  "rejected_records.csv",
  "sku_match_key_collisions.csv",
  "unkeyed_source_records.csv",
] as const;

const UUID_NAMESPACE_URL = "6ba7b811-9dad-11d1-80b4-00c04fd430c8";
export const MEDSPEND_CATALOG_NAMESPACE = uuidV5(
  UUID_NAMESPACE_URL,
  "https://medspend.app/global-catalog/import-identities/v1",
);

export type CatalogTable = (typeof CATALOG_TABLES)[number];
export type ReadCountTable = (typeof READ_ONLY_COUNT_TABLES)[number];
export type DbRow = Record<string, unknown> & { id: string };

type ManifestArtifact = {
  name: string;
  record_count: number;
  sha256: string;
};

type DryRunManifest = {
  artifacts: ManifestArtifact[];
  deterministic: boolean;
  generated_at: null;
  manifest_self_hash: null;
  source_artifacts: Array<{ name: string; sha256: string }>;
  transformer_version: string;
};

type ImportBatchArtifact = {
  artifact_name: string;
  artifact_sha256: string;
  catalog_vendor_key: string;
  error_count: number;
  import_batch_key: string;
  matched_record_count: number;
  metadata: Record<string, unknown>;
  raw_record_count: number;
  source_name: string;
  source_uri: string | null;
  source_version: string;
  status: string;
  unique_key_count: number;
  unmatched_record_count: number;
  warning_count: number;
};

type VendorArtifact = {
  active: boolean;
  catalog_vendor_key: string;
  domain: string | null;
  name: string;
  normalized_name: string;
  website: string | null;
};

type ReconciliationReport = {
  assertions: Array<{
    actual: unknown;
    expected: unknown;
    name: string;
    pass: boolean;
  }>;
  counts: Record<string, number>;
  result: string;
  transformer_version: string;
};

export type ValidationAssertion = {
  name: string;
  expected: unknown;
  actual: unknown;
  pass: boolean;
};

export type DeterministicIds = {
  vendorId: string;
  batchId: string;
  productIdsByKey: Map<string, string>;
  vendorProductIdsByKey: Map<string, string>;
  sourceIdsByKey: Map<string, string>;
  overrideIdsByKey: Map<string, string>;
};

export type PreparedImport = {
  inputDir: string;
  manifestSha256: string;
  manifest: DryRunManifest;
  validationAssertions: ValidationAssertion[];
  specialAssertions: ValidationAssertion[];
  ids: DeterministicIds;
  vendor: DbRow;
  batch: DbRow;
  products: DbRow[];
  vendorProducts: DbRow[];
  sourceRecords: DbRow[];
  overrides: DbRow[];
  logical: {
    productRows: Array<Record<string, string>>;
    vendorProductRows: Array<Record<string, string>>;
    keyedSourceRows: Array<Record<string, unknown>>;
    unkeyedSourceRows: Array<Record<string, string>>;
    overrideRows: Array<Record<string, unknown>>;
    reconciliation: ReconciliationReport;
  };
};

export type RowConflict = {
  table: CatalogTable;
  id: string;
  reason: string;
  differences: Array<{
    field: string;
    expected: unknown;
    actual: unknown;
  }>;
};

export type RowClassification = {
  missing: DbRow[];
  exact: DbRow[];
  conflicts: RowConflict[];
  unexpected: DbRow[];
};

export type CatalogState = {
  mode: "offline" | "live";
  tableCounts: Record<ReadCountTable, number | null>;
  vendorRows: DbRow[];
  batchRows: DbRow[];
  targetSkuRows: DbRow[];
  classifications: Record<CatalogTable, RowClassification> | null;
  lifecycle: "not_queried" | "fresh" | "completed" | "incomplete";
  batchStatus: string | null;
};

export type PreflightResult = {
  result: "PASS" | "BLOCKED";
  artifactValidation: "PASS";
  databaseMode: "offline" | "live";
  state: CatalogState;
  conflicts: RowConflict[];
  plannedMutations: PlannedMutations;
};

export type PlannedMutations = {
  vendor: { insert: number; adopt: number };
  batch: { insert: number; adopt: number };
  products: { insert: number; adopt: number };
  vendorProducts: { insert: number; adopt: number };
  sourceRecords: { insert: number; adopt: number };
  overrides: { insert: number; adopt: number };
  finalBatchCompletionUpdates: number;
  insertedRows: number;
};

export type ReconciliationResult = {
  result: "PASS" | "FAIL";
  assertions: ValidationAssertion[];
};

export type ExecuteResult = {
  result: "completed" | "already_imported";
  reconciliation: ReconciliationResult;
  mutationCalls: number;
};

export interface CatalogStore {
  readonly mutationCalls: number;
  count(table: ReadCountTable): Promise<number>;
  findVendorsByNormalizedName(normalizedName: string): Promise<DbRow[]>;
  findBatchesByArtifactSha(artifactSha256: string): Promise<DbRow[]>;
  findRowsByIds(table: CatalogTable, ids: string[]): Promise<DbRow[]>;
  findVendorProductsBySkus(vendorId: string, normalizedSkus: string[]): Promise<DbRow[]>;
  findSourceRecordsByBatch(batchId: string): Promise<DbRow[]>;
  findOverridesByBatch(batchId: string): Promise<DbRow[]>;
  findVendorProductsByVendor(vendorId: string): Promise<DbRow[]>;
  insert(table: CatalogTable, rows: DbRow[]): Promise<void>;
  updateBatch(batchId: string, values: Record<string, unknown>): Promise<void>;
}

export class ImportValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ImportValidationError";
  }
}

export class ImportCollisionError extends Error {
  readonly conflicts: RowConflict[];

  constructor(message: string, conflicts: RowConflict[]) {
    super(message);
    this.name = "ImportCollisionError";
    this.conflicts = conflicts;
  }
}

function uuidToBytes(uuid: string): Buffer {
  const compact = uuid.replaceAll("-", "");
  if (!/^[0-9a-f]{32}$/i.test(compact)) {
    throw new ImportValidationError(`Invalid UUID namespace: ${uuid}`);
  }
  return Buffer.from(compact, "hex");
}

function bytesToUuid(bytes: Buffer): string {
  const hex = bytes.toString("hex");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join("-");
}

export function uuidV5(namespace: string, name: string): string {
  const digest = createHash("sha1")
    .update(uuidToBytes(namespace))
    .update(Buffer.from(name, "utf8"))
    .digest();
  const bytes = Buffer.from(digest.subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return bytesToUuid(bytes);
}

export function deterministicId(naturalKey: string): string {
  return uuidV5(MEDSPEND_CATALOG_NAMESPACE, naturalKey);
}

export function sha256File(file: string): string {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

export function assertFileHash(file: string, expected: string): void {
  const actual = sha256File(file);
  if (actual !== expected) {
    throw new ImportValidationError(
      `Artifact checksum mismatch for ${path.basename(file)}: expected ${expected}, received ${actual}`,
    );
  }
}

export function parseCsv(content: string): Array<Record<string, string>> {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;

  for (let index = 0; index < content.length; index += 1) {
    const character = content[index];
    if (quoted) {
      if (character === '"' && content[index + 1] === '"') {
        field += '"';
        index += 1;
      } else if (character === '"') {
        quoted = false;
      } else {
        field += character;
      }
    } else if (character === '"') {
      quoted = true;
    } else if (character === ",") {
      row.push(field);
      field = "";
    } else if (character === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else if (character !== "\r") {
      field += character;
    }
  }

  if (quoted) throw new ImportValidationError("CSV ended inside a quoted field");
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }

  const [headers, ...data] = rows;
  if (!headers) return [];
  return data
    .filter((values) => values.length > 1 || values[0] !== "")
    .map((values) =>
      Object.fromEntries(headers.map((header, index) => [header, values[index] ?? ""])),
    );
}

function readCsv(file: string): Array<Record<string, string>> {
  return parseCsv(readFileSync(file, "utf8"));
}

function readJson<T>(file: string): T {
  try {
    return JSON.parse(readFileSync(file, "utf8")) as T;
  } catch (error) {
    throw new ImportValidationError(
      `Invalid JSON in ${path.basename(file)}: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

function readJsonLines(file: string): Array<Record<string, unknown>> {
  return readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line, index) => {
      try {
        return JSON.parse(line) as Record<string, unknown>;
      } catch (error) {
        throw new ImportValidationError(
          `Invalid JSONL in ${path.basename(file)} line ${index + 1}: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    });
}

function asNullable(value: string | null | undefined): string | null {
  return value === undefined || value === null || value === "" ? null : value;
}

function asBoolean(value: string): boolean {
  if (value === "true") return true;
  if (value === "false") return false;
  throw new ImportValidationError(`Expected boolean CSV value, received ${JSON.stringify(value)}`);
}

function asNumber(value: string): number | null {
  if (value === "") return null;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    throw new ImportValidationError(
      `Expected numeric CSV value, received ${JSON.stringify(value)}`,
    );
  }
  return parsed;
}

function asObject(value: string): Record<string, unknown> {
  const parsed = JSON.parse(value) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new ImportValidationError("Expected JSON object in CSV raw_data field");
  }
  return parsed as Record<string, unknown>;
}

function normalizeCatalogText(value: unknown): string {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function normalizeCatalogSku(value: unknown): string {
  return String(value ?? "")
    .trim()
    .toUpperCase();
}

function normalizeCatalogSkuMatchKey(value: unknown): string {
  return normalizeCatalogSku(value).replace(/[^A-Z0-9]+/g, "");
}

function assertion(
  assertions: ValidationAssertion[],
  name: string,
  expected: unknown,
  actual: unknown,
): void {
  assertions.push({
    name,
    expected,
    actual,
    pass: canonicalJson(expected) === canonicalJson(actual),
  });
}

function requirePassing(assertions: ValidationAssertion[], context: string): void {
  const failures = assertions.filter((item) => !item.pass);
  if (failures.length > 0) {
    throw new ImportValidationError(
      `${context} failed: ${failures.map((item) => item.name).join(", ")}`,
    );
  }
}

export function assertReconciliationReport(report: ReconciliationReport): void {
  const failed = report.assertions.filter((item) => !item.pass);
  if (report.result !== "PASS" || failed.length > 0) {
    throw new ImportValidationError(
      `Reconciliation report is not PASS${failed.length ? `: ${failed.map((item) => item.name).join(", ")}` : ""}`,
    );
  }
}

function artifactRecordCount(
  name: string,
  loaded: {
    products: Array<Record<string, string>>;
    keyedSources: Array<Record<string, unknown>>;
    vendorProducts: Array<Record<string, string>>;
    overrides: Array<Record<string, unknown>>;
    unkeyedSources: Array<Record<string, string>>;
    packageReview: Array<Record<string, string>>;
    rejected: Array<Record<string, string>>;
    collisions: Array<Record<string, string>>;
  },
): number {
  const counts: Record<string, number> = {
    "catalog_products.csv": loaded.products.length,
    "catalog_source_records.jsonl": loaded.keyedSources.length,
    "catalog_vendor.json": 1,
    "catalog_vendor_products.csv": loaded.vendorProducts.length,
    "catalog_verification_overrides.jsonl": loaded.overrides.length,
    "import_batch.json": 1,
    "package_normalization_review.csv": loaded.packageReview.length,
    "reconciliation_report.json": 1,
    "reconciliation_report.md": 1,
    "rejected_records.csv": loaded.rejected.length,
    "sku_match_key_collisions.csv": loaded.collisions.length,
    "unkeyed_source_records.csv": loaded.unkeyedSources.length,
  };
  const count = counts[name];
  if (count === undefined) {
    throw new ImportValidationError(`Unexpected manifest artifact: ${name}`);
  }
  return count;
}

function buildIds(
  manifestSha256: string,
  vendor: VendorArtifact,
  batch: ImportBatchArtifact,
  products: Array<Record<string, string>>,
  vendorProducts: Array<Record<string, string>>,
  keyedSources: Array<Record<string, unknown>>,
  unkeyedSources: Array<Record<string, string>>,
  overrides: Array<Record<string, unknown>>,
): DeterministicIds {
  const vendorId = deterministicId(`catalog-vendor:${vendor.normalized_name}`);
  const batchId = deterministicId(
    `catalog-import-batch:${vendor.normalized_name}:${batch.artifact_sha256}:${manifestSha256}`,
  );
  const productIdsByKey = new Map(
    products.map((row) => [
      row.product_key,
      deterministicId(
        `catalog-product:${vendor.normalized_name}:${normalizeCatalogSku(row.source_vendor_sku)}`,
      ),
    ]),
  );
  const vendorProductIdsByKey = new Map(
    vendorProducts.map((row) => [
      row.vendor_product_key,
      deterministicId(
        `catalog-vendor-product:${vendor.normalized_name}:${row.normalized_vendor_sku}`,
      ),
    ]),
  );
  const sourceIdsByKey = new Map<string, string>();
  for (const row of keyedSources) {
    const ordinal = row.source_ordinal as number;
    sourceIdsByKey.set(
      row.source_record_key as string,
      deterministicId(`catalog-source-record:${batchId}:${ordinal}`),
    );
  }
  unkeyedSources.forEach((row, index) => {
    const ordinal = EXPECTED_COUNTS.keyedSources + index + 1;
    sourceIdsByKey.set(
      row.unkeyed_record_key,
      deterministicId(`catalog-source-record:${batchId}:${ordinal}`),
    );
  });
  const overrideIdsByKey = new Map(
    overrides.map((row) => [
      row.override_key as string,
      deterministicId(
        `catalog-verification-override:${vendor.normalized_name}:${batchId}:${row.override_key as string}`,
      ),
    ]),
  );
  return {
    vendorId,
    batchId,
    productIdsByKey,
    vendorProductIdsByKey,
    sourceIdsByKey,
    overrideIdsByKey,
  };
}

function requiredMapValue(map: Map<string, string>, key: string, label: string): string {
  const value = map.get(key);
  if (!value) throw new ImportValidationError(`Unknown ${label} logical key: ${key}`);
  return value;
}

export function loadPreparedImport(inputDir: string): PreparedImport {
  const resolvedInputDir = path.resolve(inputDir);
  const manifestFile = path.join(resolvedInputDir, "dry_run_manifest.json");
  const manifestSha256 = sha256File(manifestFile);
  if (manifestSha256 !== EXPECTED_MANIFEST_SHA256) {
    throw new ImportValidationError(
      `Manifest SHA-256 mismatch: expected ${EXPECTED_MANIFEST_SHA256}, received ${manifestSha256}`,
    );
  }

  const manifest = readJson<DryRunManifest>(manifestFile);
  const manifestNames = manifest.artifacts.map((item) => item.name).sort();
  const expectedNames = [...EXPECTED_ARTIFACT_NAMES].sort();
  if (canonicalJson(manifestNames) !== canonicalJson(expectedNames)) {
    throw new ImportValidationError(
      "Manifest artifact set does not match the pinned v28 artifact set",
    );
  }

  for (const artifact of manifest.artifacts) {
    if (artifact.name.includes("/") || artifact.name.includes("\\")) {
      throw new ImportValidationError(`Unsafe artifact path in manifest: ${artifact.name}`);
    }
    assertFileHash(path.join(resolvedInputDir, artifact.name), artifact.sha256);
  }

  const productRows = readCsv(path.join(resolvedInputDir, "catalog_products.csv"));
  const keyedSourceRows = readJsonLines(
    path.join(resolvedInputDir, "catalog_source_records.jsonl"),
  );
  const vendor = readJson<VendorArtifact>(path.join(resolvedInputDir, "catalog_vendor.json"));
  const vendorProductRows = readCsv(path.join(resolvedInputDir, "catalog_vendor_products.csv"));
  const overrideRows = readJsonLines(
    path.join(resolvedInputDir, "catalog_verification_overrides.jsonl"),
  );
  const batch = readJson<ImportBatchArtifact>(path.join(resolvedInputDir, "import_batch.json"));
  const packageReview = readCsv(path.join(resolvedInputDir, "package_normalization_review.csv"));
  const reconciliation = readJson<ReconciliationReport>(
    path.join(resolvedInputDir, "reconciliation_report.json"),
  );
  const rejected = readCsv(path.join(resolvedInputDir, "rejected_records.csv"));
  const collisions = readCsv(path.join(resolvedInputDir, "sku_match_key_collisions.csv"));
  const unkeyedSourceRows = readCsv(path.join(resolvedInputDir, "unkeyed_source_records.csv"));

  assertReconciliationReport(reconciliation);

  const loadedForCounts = {
    products: productRows,
    keyedSources: keyedSourceRows,
    vendorProducts: vendorProductRows,
    overrides: overrideRows,
    unkeyedSources: unkeyedSourceRows,
    packageReview,
    rejected,
    collisions,
  };
  const validationAssertions: ValidationAssertion[] = [];
  for (const artifact of manifest.artifacts) {
    assertion(
      validationAssertions,
      `manifest record count: ${artifact.name}`,
      artifact.record_count,
      artifactRecordCount(artifact.name, loadedForCounts),
    );
  }
  assertion(validationAssertions, "manifest deterministic", true, manifest.deterministic);
  assertion(validationAssertions, "manifest generated_at", null, manifest.generated_at);
  assertion(validationAssertions, "manifest self hash marker", null, manifest.manifest_self_hash);
  assertion(
    validationAssertions,
    "manifest source artifact matches import batch",
    batch.artifact_sha256,
    manifest.source_artifacts.find((item) => item.name === batch.artifact_name)?.sha256,
  );
  assertion(
    validationAssertions,
    "transformer version matches reconciliation",
    manifest.transformer_version,
    reconciliation.transformer_version,
  );
  assertion(
    validationAssertions,
    "catalog product count",
    EXPECTED_COUNTS.products,
    productRows.length,
  );
  assertion(
    validationAssertions,
    "vendor product count",
    EXPECTED_COUNTS.vendorProducts,
    vendorProductRows.length,
  );
  assertion(
    validationAssertions,
    "keyed source count",
    EXPECTED_COUNTS.keyedSources,
    keyedSourceRows.length,
  );
  assertion(
    validationAssertions,
    "unkeyed source count",
    EXPECTED_COUNTS.unkeyedSources,
    unkeyedSourceRows.length,
  );
  assertion(validationAssertions, "override count", EXPECTED_COUNTS.overrides, overrideRows.length);
  assertion(
    validationAssertions,
    "rejected record count",
    EXPECTED_COUNTS.rejected,
    rejected.length,
  );
  assertion(
    validationAssertions,
    "match-key collision groups",
    EXPECTED_COUNTS.matchKeyCollisionGroups,
    collisions.length,
  );
  assertion(
    validationAssertions,
    "vendor normalization matches database trigger",
    vendor.normalized_name,
    normalizeCatalogText(vendor.name),
  );
  assertion(
    validationAssertions,
    "product normalizations match database trigger",
    0,
    productRows.filter(
      (row) =>
        row.name !== row.name.trim() ||
        row.normalized_name !== normalizeCatalogText(row.name) ||
        asNullable(row.normalized_manufacturer) !==
          (asNullable(row.manufacturer) ? normalizeCatalogText(row.manufacturer) : null),
    ).length,
  );
  assertion(
    validationAssertions,
    "vendor-product normalizations match database trigger",
    0,
    vendorProductRows.filter(
      (row) =>
        row.vendor_sku !== row.vendor_sku.trim() ||
        row.normalized_vendor_sku !== normalizeCatalogSku(row.vendor_sku) ||
        asNullable(row.vendor_sku_match_key) !==
          asNullable(normalizeCatalogSkuMatchKey(row.vendor_sku)) ||
        asNullable(row.normalized_manufacturer_sku) !==
          (asNullable(row.manufacturer_sku) ? normalizeCatalogSku(row.manufacturer_sku) : null),
    ).length,
  );
  assertion(
    validationAssertions,
    "source SKU normalizations match database trigger",
    0,
    keyedSourceRows.filter(
      (row) =>
        (row.normalized_raw_vendor_sku ?? null) !==
          asNullable(normalizeCatalogSku(row.raw_vendor_sku)) ||
        (row.raw_vendor_sku_match_key ?? null) !==
          asNullable(normalizeCatalogSkuMatchKey(row.raw_vendor_sku)),
    ).length,
  );
  assertion(
    validationAssertions,
    "override SKU normalizations match database trigger",
    0,
    overrideRows.filter(
      (row) =>
        (row.normalized_source_vendor_sku ?? null) !==
          asNullable(normalizeCatalogSku(row.source_vendor_sku)) ||
        (row.normalized_verified_vendor_sku ?? null) !==
          asNullable(normalizeCatalogSku(row.verified_vendor_sku)),
    ).length,
  );
  requirePassing(validationAssertions, "Artifact validation");

  const ids = buildIds(
    manifestSha256,
    vendor,
    batch,
    productRows,
    vendorProductRows,
    keyedSourceRows,
    unkeyedSourceRows,
    overrideRows,
  );

  const vendorRow: DbRow = {
    id: ids.vendorId,
    name: vendor.name,
    normalized_name: vendor.normalized_name,
    website: vendor.website,
    domain: vendor.domain,
    active: vendor.active,
  };

  const batchRow: DbRow = {
    id: ids.batchId,
    catalog_vendor_id: ids.vendorId,
    source_name: batch.source_name,
    source_version: batch.source_version,
    artifact_name: batch.artifact_name,
    artifact_sha256: batch.artifact_sha256,
    source_uri: batch.source_uri,
    status: "processing",
    raw_record_count: EXPECTED_COUNTS.sources,
    unique_key_count: batch.unique_key_count,
    matched_record_count: EXPECTED_COUNTS.keyedSources,
    unmatched_record_count: EXPECTED_COUNTS.unkeyedSources,
    warning_count: batch.warning_count,
    error_count: 0,
    metadata: {
      importer_version: IMPORTER_VERSION,
      manifest_sha256: manifestSha256,
      source_import_batch_key: batch.import_batch_key,
      source_catalog_vendor_key: batch.catalog_vendor_key,
      source_dry_run_metadata: batch.metadata,
      persisted_source_counts: {
        keyed: EXPECTED_COUNTS.keyedSources,
        unkeyed: EXPECTED_COUNTS.unkeyedSources,
        total: EXPECTED_COUNTS.sources,
      },
      unkeyed_source_ordinals: {
        first: EXPECTED_COUNTS.keyedSources + 1,
        last: EXPECTED_COUNTS.sources,
        ordering: "preserved v25 unkeyed artifact order",
      },
    },
  };

  const products: DbRow[] = productRows.map((row) => ({
    id: requiredMapValue(ids.productIdsByKey, row.product_key, "product"),
    name: row.name,
    normalized_name: row.normalized_name,
    description: asNullable(row.description),
    manufacturer: asNullable(row.manufacturer),
    normalized_manufacturer: asNullable(row.normalized_manufacturer),
    catalog_category_id: null,
    active: asBoolean(row.active),
    verification_status: row.verification_status,
  }));

  const vendorProducts: DbRow[] = vendorProductRows.map((row) => ({
    id: requiredMapValue(ids.vendorProductIdsByKey, row.vendor_product_key, "vendor product"),
    catalog_product_id: requiredMapValue(ids.productIdsByKey, row.catalog_product_key, "product"),
    catalog_vendor_id: ids.vendorId,
    vendor_sku: row.vendor_sku,
    normalized_vendor_sku: row.normalized_vendor_sku,
    vendor_sku_match_key: asNullable(row.vendor_sku_match_key),
    manufacturer_sku: asNullable(row.manufacturer_sku),
    normalized_manufacturer_sku: asNullable(row.normalized_manufacturer_sku),
    package_description: asNullable(row.package_description),
    package_quantity: asNumber(row.package_quantity),
    package_unit: asNullable(row.package_unit),
    package_status: row.package_status,
    source_catalog_price: asNumber(row.source_catalog_price),
    currency_code: asNullable(row.currency_code),
    active: asBoolean(row.active),
    discontinued: asBoolean(row.discontinued),
    verification_status: row.verification_status,
  }));

  const keyedSourceRecords: DbRow[] = keyedSourceRows.map((row) => ({
    id: requiredMapValue(ids.sourceIdsByKey, row.source_record_key as string, "source record"),
    import_batch_id: ids.batchId,
    catalog_vendor_id: ids.vendorId,
    source_ordinal: row.source_ordinal,
    raw_vendor_sku: row.raw_vendor_sku ?? null,
    normalized_raw_vendor_sku: row.normalized_raw_vendor_sku ?? null,
    raw_vendor_sku_match_key: row.raw_vendor_sku_match_key ?? null,
    raw_product_name: row.raw_product_name ?? null,
    raw_category: row.raw_category ?? null,
    raw_subsection: row.raw_subsection ?? null,
    raw_variant: row.raw_variant ?? null,
    raw_package: row.raw_package ?? null,
    source_page: row.source_page ?? null,
    raw_data: row.raw_data,
    matched_catalog_vendor_product_id: requiredMapValue(
      ids.vendorProductIdsByKey,
      row.matched_catalog_vendor_product_key as string,
      "matched vendor product",
    ),
    resolution_status: row.resolution_status,
  }));

  const unkeyedSourceRecords: DbRow[] = unkeyedSourceRows.map((row, index) => ({
    id: requiredMapValue(ids.sourceIdsByKey, row.unkeyed_record_key, "unkeyed source record"),
    import_batch_id: ids.batchId,
    catalog_vendor_id: ids.vendorId,
    source_ordinal: EXPECTED_COUNTS.keyedSources + index + 1,
    raw_vendor_sku: null,
    normalized_raw_vendor_sku: null,
    raw_vendor_sku_match_key: null,
    raw_product_name: asNullable(row.raw_product_name),
    raw_category: asNullable(row.raw_category),
    raw_subsection: null,
    raw_variant: asNullable(row.raw_model_or_variant),
    raw_package: asNullable(row.raw_package),
    source_page: asNullable(row.source_page),
    raw_data: asObject(row.raw_data),
    matched_catalog_vendor_product_id: null,
    resolution_status: "unkeyed",
  }));
  const sourceRecords = [...keyedSourceRecords, ...unkeyedSourceRecords];

  const overrides: DbRow[] = overrideRows.map((row) => ({
    id: requiredMapValue(ids.overrideIdsByKey, row.override_key as string, "override"),
    catalog_vendor_id: ids.vendorId,
    import_batch_id: ids.batchId,
    source_record_id: row.source_record_key
      ? requiredMapValue(ids.sourceIdsByKey, row.source_record_key as string, "source record")
      : null,
    catalog_vendor_product_id: row.catalog_vendor_product_key
      ? requiredMapValue(
          ids.vendorProductIdsByKey,
          row.catalog_vendor_product_key as string,
          "vendor product",
        )
      : null,
    source_vendor_sku: row.source_vendor_sku ?? null,
    normalized_source_vendor_sku: row.normalized_source_vendor_sku ?? null,
    verified_vendor_sku: row.verified_vendor_sku ?? null,
    normalized_verified_vendor_sku: row.normalized_verified_vendor_sku ?? null,
    override_type: row.override_type,
    evidence_status: row.evidence_status,
    production_rule: row.production_rule,
    evidence: row.evidence,
    notes: row.notes ?? null,
    active: row.active,
    effective_to: null,
    created_by: null,
  }));

  const specialAssertions = validateSpecialCases({
    productRows,
    vendorProductRows,
    keyedSourceRows,
    unkeyedSourceRows,
    overrideRows,
    sourceRecords,
  });

  return {
    inputDir: resolvedInputDir,
    manifestSha256,
    manifest,
    validationAssertions,
    specialAssertions,
    ids,
    vendor: vendorRow,
    batch: batchRow,
    products,
    vendorProducts,
    sourceRecords,
    overrides,
    logical: {
      productRows,
      vendorProductRows,
      keyedSourceRows,
      unkeyedSourceRows,
      overrideRows,
      reconciliation,
    },
  };
}

function validateSpecialCases(input: {
  productRows: Array<Record<string, string>>;
  vendorProductRows: Array<Record<string, string>>;
  keyedSourceRows: Array<Record<string, unknown>>;
  unkeyedSourceRows: Array<Record<string, string>>;
  overrideRows: Array<Record<string, unknown>>;
  sourceRecords: DbRow[];
}): ValidationAssertion[] {
  const assertions: ValidationAssertion[] = [];
  const productsBySku = new Map(input.productRows.map((row) => [row.source_vendor_sku, row]));
  const vendorProductsBySku = new Map(
    input.vendorProductRows.map((row) => [row.normalized_vendor_sku, row]),
  );
  const promotedSkus = new Set(vendorProductsBySku.keys());
  const packageCounts = new Map<string, number>();
  for (const row of input.vendorProductRows) {
    packageCounts.set(row.package_status, (packageCounts.get(row.package_status) ?? 0) + 1);
  }

  assertion(
    assertions,
    "vendor product SKU uniqueness",
    input.vendorProductRows.length,
    new Set(input.vendorProductRows.map((row) => row.normalized_vendor_sku)).size,
  );
  assertion(
    assertions,
    "canonical product logical-key uniqueness",
    input.productRows.length,
    new Set(input.productRows.map((row) => row.product_key)).size,
  );
  assertion(
    assertions,
    "canonical product SKU uniqueness",
    input.productRows.length,
    new Set(input.productRows.map((row) => row.source_vendor_sku)).size,
  );
  assertion(
    assertions,
    "unique raw keyed SKUs",
    EXPECTED_COUNTS.uniqueRawSkus,
    new Set(input.keyedSourceRows.map((row) => row.normalized_raw_vendor_sku)).size,
  );
  assertion(
    assertions,
    "package verified count",
    EXPECTED_COUNTS.packageVerified,
    packageCounts.get("verified") ?? 0,
  );
  assertion(
    assertions,
    "package source_only count",
    EXPECTED_COUNTS.packageSourceOnly,
    packageCounts.get("source_only") ?? 0,
  );
  assertion(
    assertions,
    "package unknown count",
    EXPECTED_COUNTS.packageUnknown,
    packageCounts.get("unknown") ?? 0,
  );
  assertion(
    assertions,
    "verified packages complete",
    0,
    input.vendorProductRows.filter(
      (row) => row.package_status === "verified" && (!row.package_quantity || !row.package_unit),
    ).length,
  );

  const prewrap = productsBySku.get("128-5852");
  assertion(assertions, "128-5852 promoted", true, promotedSkus.has("128-5852"));
  assertion(
    assertions,
    "128-5852 prewrap identity",
    "Good'N'Cheap Athletic Underwrap / Prewrap",
    prewrap?.name,
  );
  const adhesive = productsBySku.get("128-5853");
  assertion(assertions, "128-5853 promoted separately", true, promotedSkus.has("128-5853"));
  assertion(
    assertions,
    "128-5853 adhesive identity",
    "Good'N'Cheap Adhesive Stretch Tape",
    adhesive?.name,
  );
  assertion(
    assertions,
    "raw 128-5853 occurrences preserved",
    2,
    input.keyedSourceRows.filter((row) => row.raw_vendor_sku === "128-5853").length,
  );
  const page22 = input.keyedSourceRows.find(
    (row) => row.raw_vendor_sku === "128-5853" && row.source_page === "22",
  );
  assertion(
    assertions,
    "page-22 typo maps to 128-5852",
    "vendor-product:henry-schein:128-5852",
    page22?.matched_catalog_vendor_product_key,
  );

  const heldSkus = ["128-5851", "570-0663", "570-0664", "570-0665", "570-0666"];
  assertion(
    assertions,
    "held SKUs unpromoted",
    [],
    heldSkus.filter((sku) => promotedSkus.has(sku)),
  );
  assertion(
    assertions,
    "held override audit rows retained",
    heldSkus,
    heldSkus.filter((sku) =>
      input.overrideRows.some(
        (row) =>
          row.verified_vendor_sku === sku && row.production_rule === "HOLD FOR SECOND SOURCE",
      ),
    ),
  );

  const historical = vendorProductsBySku.get("364-0444");
  assertion(assertions, "364-0444 active", "false", historical?.active);
  assertion(assertions, "364-0444 discontinued", "true", historical?.discontinued);
  const accucold = productsBySku.get("139-7157");
  assertion(
    assertions,
    "139-7157 Accucold identity",
    "Accucold Performance Series Pharmacy/Vaccine Refrigerator 2.83 Cu Ft 2 to 8C",
    accucold?.name,
  );
  assertion(assertions, "139-7157 manufacturer", "Felix Storch (Summit)", accucold?.manufacturer);

  const keyedOrdinals = input.keyedSourceRows.map((row) => row.source_ordinal as number);
  const unkeyedOrdinals = input.sourceRecords
    .filter((row) => row.resolution_status === "unkeyed")
    .map((row) => row.source_ordinal as number);
  const allOrdinals = input.sourceRecords.map((row) => row.source_ordinal as number);
  assertion(assertions, "keyed ordinal min", 1, Math.min(...keyedOrdinals));
  assertion(
    assertions,
    "keyed ordinal max",
    EXPECTED_COUNTS.keyedSources,
    Math.max(...keyedOrdinals),
  );
  assertion(
    assertions,
    "unkeyed ordinal min",
    EXPECTED_COUNTS.keyedSources + 1,
    Math.min(...unkeyedOrdinals),
  );
  assertion(
    assertions,
    "unkeyed ordinal max",
    EXPECTED_COUNTS.sources,
    Math.max(...unkeyedOrdinals),
  );
  assertion(
    assertions,
    "unkeyed ordinal count",
    EXPECTED_COUNTS.unkeyedSources,
    unkeyedOrdinals.length,
  );
  assertion(assertions, "total source ordinal min", 1, Math.min(...allOrdinals));
  assertion(
    assertions,
    "total source ordinal max",
    EXPECTED_COUNTS.sources,
    Math.max(...allOrdinals),
  );
  assertion(
    assertions,
    "total distinct source ordinals",
    EXPECTED_COUNTS.sources,
    new Set(allOrdinals).size,
  );
  assertion(
    assertions,
    "total source records",
    EXPECTED_COUNTS.sources,
    input.sourceRecords.length,
  );
  assertion(
    assertions,
    "unkeyed rows have no SKU",
    0,
    input.sourceRecords.filter(
      (row) => row.resolution_status === "unkeyed" && row.raw_vendor_sku !== null,
    ).length,
  );
  assertion(
    assertions,
    "preserved unkeyed source order",
    input.unkeyedSourceRows.map((row) => row.unkeyed_record_key),
    input.sourceRecords
      .filter((row) => row.resolution_status === "unkeyed")
      .map(
        (row) =>
          input.unkeyedSourceRows[(row.source_ordinal as number) - EXPECTED_COUNTS.keyedSources - 1]
            ?.unkeyed_record_key,
      ),
  );
  requirePassing(assertions, "Special-case validation");
  return assertions;
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, nested]) => [key, canonicalize(nested)]),
    );
  }
  return value === undefined ? null : value;
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

const SEMANTIC_FIELDS: Record<CatalogTable, string[]> = {
  catalog_vendors: ["id", "name", "normalized_name", "website", "domain", "active"],
  catalog_import_batches: [
    "id",
    "catalog_vendor_id",
    "source_name",
    "source_version",
    "artifact_name",
    "artifact_sha256",
    "source_uri",
    "raw_record_count",
    "unique_key_count",
    "matched_record_count",
    "unmatched_record_count",
    "warning_count",
    "metadata",
  ],
  catalog_products: [
    "id",
    "name",
    "normalized_name",
    "description",
    "manufacturer",
    "normalized_manufacturer",
    "catalog_category_id",
    "active",
    "verification_status",
  ],
  catalog_vendor_products: [
    "id",
    "catalog_product_id",
    "catalog_vendor_id",
    "vendor_sku",
    "normalized_vendor_sku",
    "vendor_sku_match_key",
    "manufacturer_sku",
    "normalized_manufacturer_sku",
    "package_description",
    "package_quantity",
    "package_unit",
    "package_status",
    "source_catalog_price",
    "currency_code",
    "active",
    "discontinued",
    "verification_status",
  ],
  catalog_source_records: [
    "id",
    "import_batch_id",
    "catalog_vendor_id",
    "source_ordinal",
    "raw_vendor_sku",
    "normalized_raw_vendor_sku",
    "raw_vendor_sku_match_key",
    "raw_product_name",
    "raw_category",
    "raw_subsection",
    "raw_variant",
    "raw_package",
    "source_page",
    "raw_data",
    "matched_catalog_vendor_product_id",
    "resolution_status",
  ],
  catalog_verification_overrides: [
    "id",
    "catalog_vendor_id",
    "import_batch_id",
    "source_record_id",
    "catalog_vendor_product_id",
    "source_vendor_sku",
    "normalized_source_vendor_sku",
    "verified_vendor_sku",
    "normalized_verified_vendor_sku",
    "override_type",
    "evidence_status",
    "production_rule",
    "evidence",
    "notes",
    "active",
    "effective_to",
    "created_by",
  ],
};

function semanticDifferences(
  table: CatalogTable,
  expected: DbRow,
  actual: DbRow,
): RowConflict["differences"] {
  return SEMANTIC_FIELDS[table]
    .filter(
      (field) => canonicalJson(expected[field] ?? null) !== canonicalJson(actual[field] ?? null),
    )
    .map((field) => ({
      field,
      expected: expected[field] ?? null,
      actual: actual[field] ?? null,
    }));
}

export function classifyRows(
  table: CatalogTable,
  expectedRows: DbRow[],
  actualRows: DbRow[],
): RowClassification {
  const expectedById = new Map(expectedRows.map((row) => [row.id, row]));
  const actualById = new Map(actualRows.map((row) => [row.id, row]));
  const missing: DbRow[] = [];
  const exact: DbRow[] = [];
  const conflicts: RowConflict[] = [];

  for (const expected of expectedRows) {
    const actual = actualById.get(expected.id);
    if (!actual) {
      missing.push(expected);
      continue;
    }
    const differences = semanticDifferences(table, expected, actual);
    if (differences.length > 0) {
      conflicts.push({
        table,
        id: expected.id,
        reason: "deterministic ID exists with different semantic attributes",
        differences,
      });
    } else {
      exact.push(actual);
    }
  }

  return {
    missing,
    exact,
    conflicts,
    unexpected: actualRows.filter((row) => !expectedById.has(row.id)),
  };
}

function emptyCounts(): Record<ReadCountTable, null> {
  return Object.fromEntries(READ_ONLY_COUNT_TABLES.map((table) => [table, null])) as Record<
    ReadCountTable,
    null
  >;
}

export function offlineCatalogState(): CatalogState {
  return {
    mode: "offline",
    tableCounts: emptyCounts(),
    vendorRows: [],
    batchRows: [],
    targetSkuRows: [],
    classifications: null,
    lifecycle: "not_queried",
    batchStatus: null,
  };
}

function addUnexpectedConflicts(
  table: CatalogTable,
  classification: RowClassification,
  reason: string,
): void {
  for (const row of classification.unexpected) {
    classification.conflicts.push({
      table,
      id: row.id,
      reason,
      differences: [],
    });
  }
}

export async function inspectLiveCatalog(
  store: CatalogStore,
  prepared: PreparedImport,
): Promise<CatalogState> {
  const tableCountEntries = await Promise.all(
    READ_ONLY_COUNT_TABLES.map(async (table) => [table, await store.count(table)] as const),
  );
  const tableCounts = Object.fromEntries(tableCountEntries) as Record<ReadCountTable, number>;
  const vendorRows = await store.findVendorsByNormalizedName(
    prepared.vendor.normalized_name as string,
  );
  const batchRows = await store.findBatchesByArtifactSha(prepared.batch.artifact_sha256 as string);
  const [productRows, vendorProductIdRows, sourceRows, overrideRows] = await Promise.all([
    store.findRowsByIds(
      "catalog_products",
      prepared.products.map((row) => row.id),
    ),
    store.findRowsByIds(
      "catalog_vendor_products",
      prepared.vendorProducts.map((row) => row.id),
    ),
    store.findSourceRecordsByBatch(prepared.ids.batchId),
    store.findOverridesByBatch(prepared.ids.batchId),
  ]);
  const vendorSkuRows = vendorRows.some((row) => row.id === prepared.ids.vendorId)
    ? await store.findVendorProductsBySkus(
        prepared.ids.vendorId,
        prepared.vendorProducts.map((row) => row.normalized_vendor_sku as string),
      )
    : [];
  const targetSkuRows = vendorSkuRows.filter((row) =>
    [
      "128-5852",
      "128-5853",
      "128-5851",
      "570-0663",
      "570-0664",
      "570-0665",
      "570-0666",
      "364-0444",
      "139-7157",
    ].includes(row.normalized_vendor_sku as string),
  );

  const combinedVendorProducts = new Map<string, DbRow>();
  for (const row of [...vendorProductIdRows, ...vendorSkuRows])
    combinedVendorProducts.set(row.id, row);
  const classifications: Record<CatalogTable, RowClassification> = {
    catalog_vendors: classifyRows("catalog_vendors", [prepared.vendor], vendorRows),
    catalog_import_batches: classifyRows("catalog_import_batches", [prepared.batch], batchRows),
    catalog_products: classifyRows("catalog_products", prepared.products, productRows),
    catalog_vendor_products: classifyRows("catalog_vendor_products", prepared.vendorProducts, [
      ...combinedVendorProducts.values(),
    ]),
    catalog_source_records: classifyRows(
      "catalog_source_records",
      prepared.sourceRecords,
      sourceRows,
    ),
    catalog_verification_overrides: classifyRows(
      "catalog_verification_overrides",
      prepared.overrides,
      overrideRows,
    ),
  };

  addUnexpectedConflicts(
    "catalog_vendors",
    classifications.catalog_vendors,
    "normalized vendor identity exists under a different deterministic ID",
  );
  addUnexpectedConflicts(
    "catalog_import_batches",
    classifications.catalog_import_batches,
    "artifact SHA-256 exists under a different deterministic batch ID",
  );
  addUnexpectedConflicts(
    "catalog_vendor_products",
    classifications.catalog_vendor_products,
    "vendor SKU natural key exists outside the expected deterministic row set",
  );
  addUnexpectedConflicts(
    "catalog_source_records",
    classifications.catalog_source_records,
    "batch contains an unexpected source ordinal/row",
  );
  addUnexpectedConflicts(
    "catalog_verification_overrides",
    classifications.catalog_verification_overrides,
    "batch contains an unexpected verification override",
  );

  const expectedBatch = batchRows.find((row) => row.id === prepared.ids.batchId);
  let lifecycle: CatalogState["lifecycle"] = "fresh";
  let batchStatus: string | null = null;
  if (expectedBatch) {
    batchStatus = expectedBatch.status as string;
    lifecycle = batchStatus === "completed" ? "completed" : "incomplete";
  }

  return {
    mode: "live",
    tableCounts,
    vendorRows,
    batchRows,
    targetSkuRows,
    classifications,
    lifecycle,
    batchStatus,
  };
}

function sumInserted(plan: Omit<PlannedMutations, "insertedRows">): number {
  return (
    plan.vendor.insert +
    plan.batch.insert +
    plan.products.insert +
    plan.vendorProducts.insert +
    plan.sourceRecords.insert +
    plan.overrides.insert
  );
}

export function freshPlannedMutations(): PlannedMutations {
  const base = {
    vendor: { insert: EXPECTED_COUNTS.vendors, adopt: 0 },
    batch: { insert: EXPECTED_COUNTS.batches, adopt: 0 },
    products: { insert: EXPECTED_COUNTS.products, adopt: 0 },
    vendorProducts: { insert: EXPECTED_COUNTS.vendorProducts, adopt: 0 },
    sourceRecords: { insert: EXPECTED_COUNTS.sources, adopt: 0 },
    overrides: { insert: EXPECTED_COUNTS.overrides, adopt: 0 },
    finalBatchCompletionUpdates: 1,
  };
  return { ...base, insertedRows: sumInserted(base) };
}

function planFromState(state: CatalogState): PlannedMutations {
  if (!state.classifications) return freshPlannedMutations();
  const classification = state.classifications;
  const base = {
    vendor: {
      insert: classification.catalog_vendors.missing.length,
      adopt: classification.catalog_vendors.exact.length,
    },
    batch: {
      insert: classification.catalog_import_batches.missing.length,
      adopt: classification.catalog_import_batches.exact.length,
    },
    products: {
      insert: classification.catalog_products.missing.length,
      adopt: classification.catalog_products.exact.length,
    },
    vendorProducts: {
      insert: classification.catalog_vendor_products.missing.length,
      adopt: classification.catalog_vendor_products.exact.length,
    },
    sourceRecords: {
      insert: classification.catalog_source_records.missing.length,
      adopt: classification.catalog_source_records.exact.length,
    },
    overrides: {
      insert: classification.catalog_verification_overrides.missing.length,
      adopt: classification.catalog_verification_overrides.exact.length,
    },
    finalBatchCompletionUpdates: state.lifecycle === "completed" ? 0 : 1,
  };
  return { ...base, insertedRows: sumInserted(base) };
}

export async function runPreflight(
  prepared: PreparedImport,
  store?: CatalogStore,
): Promise<PreflightResult> {
  const state = store ? await inspectLiveCatalog(store, prepared) : offlineCatalogState();
  const conflicts = state.classifications
    ? CATALOG_TABLES.flatMap((table) => state.classifications![table].conflicts)
    : [];
  return {
    result: conflicts.length === 0 ? "PASS" : "BLOCKED",
    artifactValidation: "PASS",
    databaseMode: store ? "live" : "offline",
    state,
    conflicts,
    plannedMutations: planFromState(state),
  };
}

function jsonForReport(value: unknown): string {
  return JSON.stringify(value, null, 2) + "\n";
}

function markdownPreflight(prepared: PreparedImport, preflight: PreflightResult): string {
  const plan = preflight.plannedMutations;
  return [
    "# Henry Schein v28 production import preflight",
    "",
    `Result: **${preflight.result}**`,
    `Database mode: **${preflight.databaseMode}**`,
    `Manifest SHA-256: \`${prepared.manifestSha256}\``,
    "",
    "## Planned mutations",
    "",
    "| Entity | Insert | Adopt |",
    "|---|---:|---:|",
    `| Catalog vendor | ${plan.vendor.insert} | ${plan.vendor.adopt} |`,
    `| Import batch | ${plan.batch.insert} | ${plan.batch.adopt} |`,
    `| Canonical products | ${plan.products.insert} | ${plan.products.adopt} |`,
    `| Vendor products | ${plan.vendorProducts.insert} | ${plan.vendorProducts.adopt} |`,
    `| Source records | ${plan.sourceRecords.insert} | ${plan.sourceRecords.adopt} |`,
    `| Verification overrides | ${plan.overrides.insert} | ${plan.overrides.adopt} |`,
    "",
    `Inserted rows: **${plan.insertedRows.toLocaleString("en-US")}**`,
    `Final completion updates: **${plan.finalBatchCompletionUpdates}**`,
    "",
    "## Safety",
    "",
    "This report is generated by dry-run/read-only preflight. No database mutations are performed.",
    "Unkeyed source rows retain artifact order and receive appended ordinals 9269–9321.",
    "Match keys are diagnostic only and never drive adoption or merging.",
    "",
  ].join("\n");
}

export function writeImportPlan(
  outputDir: string,
  prepared: PreparedImport,
  preflight: PreflightResult,
): string[] {
  const resolved = path.resolve(outputDir);
  mkdirSync(resolved, { recursive: true });
  const freshPlan = freshPlannedMutations();
  if (freshPlan.insertedRows !== EXPECTED_COUNTS.freshInsertedRows) {
    throw new ImportValidationError(
      `Fresh mutation arithmetic mismatch: expected ${EXPECTED_COUNTS.freshInsertedRows}, received ${freshPlan.insertedRows}`,
    );
  }

  const expectedPostImportState = {
    vendor: 1,
    batch: { count: 1, status: "completed" },
    canonicalProducts: EXPECTED_COUNTS.products,
    vendorProducts: EXPECTED_COUNTS.vendorProducts,
    sourceRecords: {
      keyed: EXPECTED_COUNTS.keyedSources,
      unkeyed: EXPECTED_COUNTS.unkeyedSources,
      total: EXPECTED_COUNTS.sources,
      ordinalMin: 1,
      ordinalMax: EXPECTED_COUNTS.sources,
      distinctOrdinals: EXPECTED_COUNTS.sources,
    },
    verificationOverrides: EXPECTED_COUNTS.overrides,
    packages: {
      verified: EXPECTED_COUNTS.packageVerified,
      source_only: EXPECTED_COUNTS.packageSourceOnly,
      unknown: EXPECTED_COUNTS.packageUnknown,
    },
  };
  const currentCatalogState = {
    mode: preflight.state.mode,
    tableCounts: preflight.state.tableCounts,
    lifecycle: preflight.state.lifecycle,
    batchStatus: preflight.state.batchStatus,
    henryScheinVendorCount: preflight.state.vendorRows.length,
    matchingBatchCount: preflight.state.batchRows.length,
    targetSkuRows: preflight.state.targetSkuRows,
  };
  const preflightReport = {
    result: preflight.result,
    databaseMode: preflight.databaseMode,
    artifactValidation: preflight.artifactValidation,
    manifestSha256: prepared.manifestSha256,
    validationAssertions: prepared.validationAssertions,
    specialAssertions: prepared.specialAssertions,
    lifecycle: preflight.state.lifecycle,
    batchStatus: preflight.state.batchStatus,
    conflicts: preflight.conflicts,
  };

  const files: Array<[string, string]> = [
    ["preflight_report.json", jsonForReport(preflightReport)],
    ["preflight_report.md", markdownPreflight(prepared, preflight)],
    [
      "planned_mutations.json",
      jsonForReport({
        currentPreflight: preflight.plannedMutations,
        freshCatalogExpectation: freshPlan,
      }),
    ],
    ["current_catalog_state.json", jsonForReport(currentCatalogState)],
    ["expected_post_import_state.json", jsonForReport(expectedPostImportState)],
  ];
  for (const [name, contents] of files) writeFileSync(path.join(resolved, name), contents);
  return files.map(([name]) => path.join(resolved, name));
}

export function chunkRows(rows: DbRow[], size = WRITE_CHUNK_SIZE): DbRow[][] {
  if (!Number.isInteger(size) || size <= 0) {
    throw new ImportValidationError(`Invalid chunk size: ${size}`);
  }
  const chunks: DbRow[][] = [];
  for (let index = 0; index < rows.length; index += size) {
    chunks.push(rows.slice(index, index + size));
  }
  return chunks;
}

function executionRows(table: CatalogTable, rows: DbRow[], timestamp: string): DbRow[] {
  if (table === "catalog_source_records") {
    return rows.map((row) => ({ ...row, resolved_at: timestamp }));
  }
  if (table === "catalog_verification_overrides") {
    return rows.map((row) => ({ ...row, effective_from: timestamp }));
  }
  if (table === "catalog_import_batches") {
    return rows.map((row) => ({ ...row, started_at: timestamp }));
  }
  return rows;
}

async function insertMissing(
  store: CatalogStore,
  table: CatalogTable,
  rows: DbRow[],
  timestamp: string,
): Promise<void> {
  const materialized = executionRows(table, rows, timestamp);
  for (const chunk of chunkRows(materialized)) await store.insert(table, chunk);
}

function expectNoConflicts(preflight: PreflightResult): void {
  if (preflight.conflicts.length > 0) {
    throw new ImportCollisionError(
      "Catalog preflight found conflicting existing rows",
      preflight.conflicts,
    );
  }
}

function classificationFor(state: CatalogState, table: CatalogTable): RowClassification {
  if (!state.classifications) {
    throw new ImportValidationError("Live row classifications are required for execute mode");
  }
  return state.classifications[table];
}

async function verifyPhase(
  store: CatalogStore,
  table: CatalogTable,
  expectedRows: DbRow[],
): Promise<void> {
  let actual: DbRow[];
  if (table === "catalog_source_records") {
    actual = await store.findSourceRecordsByBatch(expectedRows[0].import_batch_id as string);
  } else if (table === "catalog_verification_overrides") {
    actual = await store.findOverridesByBatch(expectedRows[0].import_batch_id as string);
  } else if (table === "catalog_vendor_products") {
    actual = await store.findVendorProductsByVendor(expectedRows[0].catalog_vendor_id as string);
  } else {
    actual = await store.findRowsByIds(
      table,
      expectedRows.map((row) => row.id),
    );
  }
  const classified = classifyRows(table, expectedRows, actual);
  if (classified.conflicts.length || classified.missing.length || classified.unexpected.length) {
    const conflicts = [...classified.conflicts];
    for (const row of classified.missing) {
      conflicts.push({
        table,
        id: row.id,
        reason: "row missing after import phase",
        differences: [],
      });
    }
    for (const row of classified.unexpected) {
      conflicts.push({
        table,
        id: row.id,
        reason: "unexpected row after import phase",
        differences: [],
      });
    }
    throw new ImportCollisionError(`Post-phase verification failed for ${table}`, conflicts);
  }
}

function dbAssertion(
  assertions: ValidationAssertion[],
  name: string,
  expected: unknown,
  actual: unknown,
): void {
  assertion(assertions, name, expected, actual);
}

export async function reconcileImportedCatalog(
  store: CatalogStore,
  prepared: PreparedImport,
  expectedBatchStatus: "processing" | "completed",
): Promise<ReconciliationResult> {
  const [vendors, batches, products, vendorProducts, sources, overrides] = await Promise.all([
    store.findVendorsByNormalizedName(prepared.vendor.normalized_name as string),
    store.findBatchesByArtifactSha(prepared.batch.artifact_sha256 as string),
    store.findRowsByIds(
      "catalog_products",
      prepared.products.map((row) => row.id),
    ),
    store.findVendorProductsByVendor(prepared.ids.vendorId),
    store.findSourceRecordsByBatch(prepared.ids.batchId),
    store.findOverridesByBatch(prepared.ids.batchId),
  ]);
  const assertions: ValidationAssertion[] = [];
  dbAssertion(assertions, "Henry Schein vendor count", 1, vendors.length);
  if (vendors[0]) {
    dbAssertion(
      assertions,
      "Henry Schein vendor semantic identity",
      [],
      semanticDifferences("catalog_vendors", prepared.vendor, vendors[0]),
    );
  }
  dbAssertion(assertions, "expected import batch count", 1, batches.length);
  dbAssertion(assertions, "expected import batch status", expectedBatchStatus, batches[0]?.status);
  if (batches[0]) {
    dbAssertion(
      assertions,
      "expected import batch semantic identity",
      [],
      semanticDifferences("catalog_import_batches", prepared.batch, batches[0]),
    );
  }
  const productClassification = classifyRows("catalog_products", prepared.products, products);
  dbAssertion(assertions, "canonical product count", EXPECTED_COUNTS.products, products.length);
  dbAssertion(
    assertions,
    "canonical product semantic equivalence",
    0,
    productClassification.conflicts.length +
      productClassification.missing.length +
      productClassification.unexpected.length,
  );
  const vendorProductClassification = classifyRows(
    "catalog_vendor_products",
    prepared.vendorProducts,
    vendorProducts,
  );
  dbAssertion(
    assertions,
    "Henry Schein vendor product count",
    EXPECTED_COUNTS.vendorProducts,
    vendorProducts.length,
  );
  dbAssertion(
    assertions,
    "vendor product semantic equivalence",
    0,
    vendorProductClassification.conflicts.length +
      vendorProductClassification.missing.length +
      vendorProductClassification.unexpected.length,
  );
  const sourceClassification = classifyRows(
    "catalog_source_records",
    prepared.sourceRecords,
    sources,
  );
  dbAssertion(assertions, "source record count", EXPECTED_COUNTS.sources, sources.length);
  dbAssertion(
    assertions,
    "source record semantic equivalence",
    0,
    sourceClassification.conflicts.length +
      sourceClassification.missing.length +
      sourceClassification.unexpected.length,
  );
  const overrideClassification = classifyRows(
    "catalog_verification_overrides",
    prepared.overrides,
    overrides,
  );
  dbAssertion(
    assertions,
    "verification override count",
    EXPECTED_COUNTS.overrides,
    overrides.length,
  );
  dbAssertion(
    assertions,
    "override semantic equivalence",
    0,
    overrideClassification.conflicts.length +
      overrideClassification.missing.length +
      overrideClassification.unexpected.length,
  );

  const ordinals = sources.map((row) => row.source_ordinal as number);
  dbAssertion(
    assertions,
    "source ordinal minimum",
    1,
    ordinals.length ? Math.min(...ordinals) : null,
  );
  dbAssertion(
    assertions,
    "source ordinal maximum",
    EXPECTED_COUNTS.sources,
    ordinals.length ? Math.max(...ordinals) : null,
  );
  dbAssertion(
    assertions,
    "distinct source ordinals",
    EXPECTED_COUNTS.sources,
    new Set(ordinals).size,
  );
  const packageCounts = new Map<string, number>();
  for (const row of vendorProducts) {
    const status = row.package_status as string;
    packageCounts.set(status, (packageCounts.get(status) ?? 0) + 1);
  }
  dbAssertion(
    assertions,
    "package verified",
    EXPECTED_COUNTS.packageVerified,
    packageCounts.get("verified") ?? 0,
  );
  dbAssertion(
    assertions,
    "package source_only",
    EXPECTED_COUNTS.packageSourceOnly,
    packageCounts.get("source_only") ?? 0,
  );
  dbAssertion(
    assertions,
    "package unknown",
    EXPECTED_COUNTS.packageUnknown,
    packageCounts.get("unknown") ?? 0,
  );
  dbAssertion(
    assertions,
    "duplicate vendor + normalized SKU",
    0,
    vendorProducts.length - new Set(vendorProducts.map((row) => row.normalized_vendor_sku)).size,
  );
  dbAssertion(assertions, "duplicate source ordinal", 0, sources.length - new Set(ordinals).size);
  dbAssertion(
    assertions,
    "unkeyed source synthetic SKU count",
    0,
    sources.filter((row) => row.resolution_status === "unkeyed" && row.raw_vendor_sku !== null)
      .length,
  );

  const vendorProductsBySku = new Map(
    vendorProducts.map((row) => [row.normalized_vendor_sku as string, row]),
  );
  const productsById = new Map(products.map((row) => [row.id, row]));
  const productForSku = (sku: string) => {
    const vendorProduct = vendorProductsBySku.get(sku);
    return vendorProduct ? productsById.get(vendorProduct.catalog_product_id as string) : undefined;
  };
  dbAssertion(
    assertions,
    "128-5852 prewrap",
    "Good'N'Cheap Athletic Underwrap / Prewrap",
    productForSku("128-5852")?.name,
  );
  dbAssertion(
    assertions,
    "128-5853 adhesive",
    "Good'N'Cheap Adhesive Stretch Tape",
    productForSku("128-5853")?.name,
  );
  dbAssertion(
    assertions,
    "held SKUs promoted",
    [],
    ["128-5851", "570-0663", "570-0664", "570-0665", "570-0666"].filter((sku) =>
      vendorProductsBySku.has(sku),
    ),
  );
  dbAssertion(assertions, "364-0444 active", false, vendorProductsBySku.get("364-0444")?.active);
  dbAssertion(
    assertions,
    "364-0444 discontinued",
    true,
    vendorProductsBySku.get("364-0444")?.discontinued,
  );
  dbAssertion(
    assertions,
    "139-7157 Accucold identity",
    "Accucold Performance Series Pharmacy/Vaccine Refrigerator 2.83 Cu Ft 2 to 8C",
    productForSku("139-7157")?.name,
  );
  dbAssertion(
    assertions,
    "139-7157 Felix Storch manufacturer",
    "Felix Storch (Summit)",
    productForSku("139-7157")?.manufacturer,
  );
  return {
    result: assertions.every((item) => item.pass) ? "PASS" : "FAIL",
    assertions,
  };
}

export async function executePreparedImport(
  prepared: PreparedImport,
  store: CatalogStore,
  options: { resumeIncomplete: boolean; timestamp?: string },
): Promise<ExecuteResult> {
  const timestamp = options.timestamp ?? new Date().toISOString();
  const initialMutationCalls = store.mutationCalls;
  const preflight = await runPreflight(prepared, store);
  expectNoConflicts(preflight);

  if (preflight.state.lifecycle === "completed") {
    const reconciliation = await reconcileImportedCatalog(store, prepared, "completed");
    if (reconciliation.result !== "PASS") {
      throw new ImportValidationError("Completed batch failed post-import reconciliation");
    }
    return {
      result: "already_imported",
      reconciliation,
      mutationCalls: store.mutationCalls - initialMutationCalls,
    };
  }

  if (preflight.state.lifecycle === "incomplete" && !options.resumeIncomplete) {
    throw new ImportValidationError(
      `Existing batch is ${preflight.state.batchStatus}; rerun requires --resume-incomplete after reviewing the preflight report`,
    );
  }

  let batchExists = preflight.state.lifecycle === "incomplete";
  try {
    const vendorClassification = classificationFor(preflight.state, "catalog_vendors");
    await insertMissing(store, "catalog_vendors", vendorClassification.missing, timestamp);
    await verifyPhase(store, "catalog_vendors", [prepared.vendor]);

    const batchClassification = classificationFor(preflight.state, "catalog_import_batches");
    if (batchClassification.missing.length > 0) {
      await insertMissing(store, "catalog_import_batches", batchClassification.missing, timestamp);
      batchExists = true;
    } else {
      await store.updateBatch(prepared.ids.batchId, {
        status: "processing",
        error_count: 0,
        completed_at: null,
      });
    }
    const activeBatch = await store.findRowsByIds("catalog_import_batches", [prepared.ids.batchId]);
    if (activeBatch.length !== 1)
      throw new ImportValidationError("Import batch missing after creation/resume");

    const phases: Array<[CatalogTable, DbRow[]]> = [
      ["catalog_products", prepared.products],
      ["catalog_vendor_products", prepared.vendorProducts],
      ["catalog_source_records", prepared.sourceRecords],
      ["catalog_verification_overrides", prepared.overrides],
    ];
    for (const [table, expectedRows] of phases) {
      const currentPreflight = await runPreflight(prepared, store);
      expectNoConflicts(currentPreflight);
      const classification = classificationFor(currentPreflight.state, table);
      await insertMissing(store, table, classification.missing, timestamp);
      await verifyPhase(store, table, expectedRows);
    }

    const reconciliation = await reconcileImportedCatalog(store, prepared, "processing");
    if (reconciliation.result !== "PASS") {
      throw new ImportValidationError(
        `Post-import reconciliation failed: ${reconciliation.assertions
          .filter((item) => !item.pass)
          .map((item) => item.name)
          .join(", ")}`,
      );
    }

    await store.updateBatch(prepared.ids.batchId, {
      status: "completed",
      completed_at: timestamp,
      error_count: 0,
    });
    const completed = await reconcileImportedCatalog(store, prepared, "completed");
    if (completed.result !== "PASS") {
      throw new ImportValidationError("Batch completion verification failed");
    }
    return {
      result: "completed",
      reconciliation: completed,
      mutationCalls: store.mutationCalls - initialMutationCalls,
    };
  } catch (error) {
    if (batchExists) {
      try {
        await store.updateBatch(prepared.ids.batchId, {
          status: "failed",
          error_count: 1,
          completed_at: null,
        });
      } catch {
        // The original error is authoritative. A network failure may leave the
        // batch in processing; either state requires explicit resume.
      }
    }
    throw error;
  }
}

export async function createSupabaseCatalogStore(): Promise<CatalogStore> {
  const { supabaseAdmin } = await import("../../../src/integrations/supabase/client.server.ts");
  type SupabaseOperationResult = {
    data: unknown;
    count: number | null;
    error: { message: string } | null;
  };
  interface SupabaseQuery extends PromiseLike<SupabaseOperationResult> {
    select(columns: string, options?: { count?: "exact"; head?: boolean }): SupabaseQuery;
    eq(column: string, value: unknown): SupabaseQuery;
    ilike(column: string, pattern: string): SupabaseQuery;
    in(column: string, values: unknown[]): SupabaseQuery;
    order(column: string, options: { ascending: boolean }): SupabaseQuery;
    range(from: number, to: number): SupabaseQuery;
    insert(rows: DbRow[]): SupabaseQuery;
    update(values: Record<string, unknown>): SupabaseQuery;
  }
  type SupabaseLike = {
    from(table: string): SupabaseQuery;
  };
  const client = supabaseAdmin as unknown as SupabaseLike;
  let mutationCalls = 0;

  async function requireData<T>(operation: SupabaseQuery): Promise<T> {
    const { data, error } = await operation;
    if (error) throw new Error(error.message);
    return data as T;
  }

  async function paged(
    queryFactory: (from: number, to: number) => SupabaseQuery,
  ): Promise<DbRow[]> {
    const pageSize = 1_000;
    const rows: DbRow[] = [];
    for (let from = 0; ; from += pageSize) {
      const page = await requireData<DbRow[]>(queryFactory(from, from + pageSize - 1));
      rows.push(...page);
      if (page.length < pageSize) return rows;
    }
  }

  async function byIds(table: CatalogTable, ids: string[]): Promise<DbRow[]> {
    const rows: DbRow[] = [];
    for (let index = 0; index < ids.length; index += 200) {
      const chunk = ids.slice(index, index + 200);
      if (chunk.length === 0) continue;
      rows.push(...(await requireData<DbRow[]>(client.from(table).select("*").in("id", chunk))));
    }
    return rows;
  }

  return {
    get mutationCalls() {
      return mutationCalls;
    },
    async count(table) {
      const { count, error } = await client
        .from(table)
        .select("id", { count: "exact", head: true });
      if (error) throw new Error(error.message);
      return count ?? 0;
    },
    findVendorsByNormalizedName(normalizedName) {
      return requireData<DbRow[]>(
        client.from("catalog_vendors").select("*").eq("normalized_name", normalizedName),
      );
    },
    findBatchesByArtifactSha(artifactSha256) {
      return requireData<DbRow[]>(
        client.from("catalog_import_batches").select("*").ilike("artifact_sha256", artifactSha256),
      );
    },
    findRowsByIds: byIds,
    async findVendorProductsBySkus(vendorId, normalizedSkus) {
      const rows: DbRow[] = [];
      for (let index = 0; index < normalizedSkus.length; index += 200) {
        const chunk = normalizedSkus.slice(index, index + 200);
        rows.push(
          ...(await requireData<DbRow[]>(
            client
              .from("catalog_vendor_products")
              .select("*")
              .eq("catalog_vendor_id", vendorId)
              .in("normalized_vendor_sku", chunk),
          )),
        );
      }
      return rows;
    },
    findSourceRecordsByBatch(batchId) {
      return paged((from, to) =>
        client
          .from("catalog_source_records")
          .select("*")
          .eq("import_batch_id", batchId)
          .order("source_ordinal", { ascending: true })
          .range(from, to),
      );
    },
    findOverridesByBatch(batchId) {
      return paged((from, to) =>
        client
          .from("catalog_verification_overrides")
          .select("*")
          .eq("import_batch_id", batchId)
          .order("id", { ascending: true })
          .range(from, to),
      );
    },
    findVendorProductsByVendor(vendorId) {
      return paged((from, to) =>
        client
          .from("catalog_vendor_products")
          .select("*")
          .eq("catalog_vendor_id", vendorId)
          .order("normalized_vendor_sku", { ascending: true })
          .range(from, to),
      );
    },
    async insert(table, rows) {
      if (!CATALOG_TABLES.includes(table)) {
        throw new ImportValidationError(`Importer cannot mutate non-catalog table ${table}`);
      }
      if (rows.length === 0) return;
      mutationCalls += 1;
      const { error } = await client.from(table).insert(rows);
      if (error) throw new Error(error.message);
    },
    async updateBatch(batchId, values) {
      mutationCalls += 1;
      const { error } = await client
        .from("catalog_import_batches")
        .update(values)
        .eq("id", batchId);
      if (error) throw new Error(error.message);
    },
  };
}

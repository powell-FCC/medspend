import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const repository = process.cwd();
const transformer = path.join(repository, "scripts/catalog/henry-schein/transform.py");
const v28 = path.join(repository, "inputs/catalog/henry-schein/Henry_Schein_Product_Registry_Master_v28_QA_Final.xlsx");
const v25 = path.join(repository, "inputs/catalog/henry-schein/Henry_Schein_Product_Registry_Master_v25.xlsx");
const temporaryRoot = mkdtempSync(path.join(tmpdir(), "medspend-hs-transform-test-"));
const runOne = path.join(temporaryRoot, "one");
const runTwo = path.join(temporaryRoot, "two");

type Report = {
  result: string;
  counts: Record<string, number>;
  assertions: Array<{ name: string; pass: boolean }>;
};

let report: Report;
let sourceRecords: Array<Record<string, unknown>>;
let vendorProducts: Array<Record<string, string>>;

function run(output: string) {
  const result = spawnSync("python3", [
    transformer,
    "--v28", v28,
    "--v25", v25,
    "--output-dir", output,
    "--quiet",
  ], { cwd: repository, encoding: "utf8" });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
}

function readJsonLines(file: string) {
  return readFileSync(file, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

function readCsv(file: string) {
  const content = readFileSync(file, "utf8");
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
  if (field || row.length) {
    row.push(field);
    rows.push(row);
  }
  const [headers, ...data] = rows;
  return data.map((values) => Object.fromEntries(headers.map((header, index) => [header, values[index] ?? ""])));
}

function sha256(file: string) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

before(() => {
  run(runOne);
  run(runTwo);
  report = JSON.parse(readFileSync(path.join(runOne, "reconciliation_report.json"), "utf8"));
  sourceRecords = readJsonLines(path.join(runOne, "catalog_source_records.jsonl"));
  vendorProducts = readCsv(path.join(runOne, "catalog_vendor_products.csv"));
});

after(() => rmSync(temporaryRoot, { recursive: true, force: true }));

test("raw occurrence and unique SKU counts reconcile", () => {
  assert.equal(report.result, "PASS");
  assert.equal(report.counts.raw_source_records, 9268);
  assert.equal(report.counts.unique_raw_skus, 9058);
});

test("source ordinals are deterministic, contiguous, and unique", () => {
  const ordinals = sourceRecords.map((row) => row.source_ordinal as number);
  assert.equal(Math.min(...ordinals), 1);
  assert.equal(Math.max(...ordinals), 9268);
  assert.equal(new Set(ordinals).size, 9268);
});

test("repeated SKUs retain multiple source occurrences", () => {
  assert.equal(sourceRecords.filter((row) => row.raw_vendor_sku === "128-5853").length, 2);
});

test("Good'N'Cheap page-22 typo maps to 128-5852 without rewriting raw SKU", () => {
  const row = sourceRecords.find((item) => item.raw_vendor_sku === "128-5853" && item.source_page === "22");
  assert.equal(row?.matched_catalog_vendor_product_key, "vendor-product:henry-schein:128-5852");
  assert.equal(row?.raw_vendor_sku, "128-5853");
});

test("legitimate 128-5853 identity remains promoted", () => {
  assert.ok(vendorProducts.some((row) => row.normalized_vendor_sku === "128-5853"));
});

test("held overrides are not promoted", () => {
  const promoted = new Set(vendorProducts.map((row) => row.normalized_vendor_sku));
  for (const sku of ["128-5851", "570-0663", "570-0664", "570-0665", "570-0666"])
    assert.equal(promoted.has(sku), false);
});

test("364-0444 remains historical, inactive, and discontinued", () => {
  const row = vendorProducts.find((item) => item.normalized_vendor_sku === "364-0444");
  assert.equal(row?.active, "false");
  assert.equal(row?.discontinued, "true");
});

test("139-7157 has the final verified Accucold identity", () => {
  const products = readCsv(path.join(runOne, "catalog_products.csv"));
  const row = products.find((item) => item.source_vendor_sku === "139-7157");
  assert.equal(row?.name, "Accucold Performance Series Pharmacy/Vaccine Refrigerator 2.83 Cu Ft 2 to 8C");
  assert.equal(row?.manufacturer, "Felix Storch (Summit)");
});

test("all package-review identities are retained", () => {
  assert.equal(report.counts.package_review, 346);
  assert.equal(readFileSync(path.join(runOne, "package_normalization_review.csv"), "utf8").trimEnd().split("\n").length - 1, 346);
});

test("verified packages satisfy quantity and unit constraints", () => {
  const invalid = report.assertions.find((item) => item.name === "invalid verified package rows");
  assert.equal(invalid?.pass, true);
});

test("all 53 unkeyed source records remain unkeyed", () => {
  assert.equal(report.counts.unkeyed_records, 53);
  const content = readFileSync(path.join(runOne, "unkeyed_source_records.csv"), "utf8");
  assert.equal((content.match(/,unkeyed,/g) ?? []).length, 53);
});

test("match-key collisions are reported without enforcing uniqueness", () => {
  assert.equal(readFileSync(path.join(runOne, "sku_match_key_collisions.csv"), "utf8").split("\n")[0].includes("match_key"), true);
  assert.equal(report.counts.match_key_collision_groups >= 0, true);
});

test("vendor plus normalized SKU has no duplicates", () => {
  const skus = vendorProducts.map((row) => row.normalized_vendor_sku);
  assert.equal(new Set(skus).size, skus.length);
});

test("every required reconciliation invariant passes", () => {
  assert.deepEqual(report.assertions.filter((item) => !item.pass), []);
});

test("two identical runs produce byte-identical artifacts", () => {
  const filesOne = readdirSync(runOne).sort();
  const filesTwo = readdirSync(runTwo).sort();
  assert.deepEqual(filesOne, filesTwo);
  for (const file of filesOne)
    assert.equal(sha256(path.join(runOne, file)), sha256(path.join(runTwo, file)), file);
});

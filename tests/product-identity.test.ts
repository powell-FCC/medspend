import assert from "node:assert/strict";
import test from "node:test";
import {
  matchInvoiceProduct,
  normalizeDescription,
  normalizePackageSize,
} from "../src/product-identity/matcher.ts";

const org = "org-a";
const vendor = "vendor-a";
const product = (overrides = {}) => ({
  organizationId: org,
  id: "p1",
  name: "Surgical tape 1.5 inch",
  description: "",
  manufacturer: "Acme",
  internalItemCode: null,
  vendorItemNumber: null,
  preferredVendorId: vendor,
  unitOfMeasure: "roll",
  packSize: "10/box",
  ...overrides,
});
const line = (overrides = {}) => ({
  sku: "ABC-123",
  description: 'Surgical Tape 1.5"',
  manufacturer: "Acme",
  unitOfMeasure: "Rl",
  packageSize: "10/Bx",
  ...overrides,
});

test("remembered organization + vendor + SKU mapping is exact", () => {
  const result = matchInvoiceProduct(
    line(),
    org,
    vendor,
    [product()],
    [{ organizationId: org, id: "vp1", vendorId: vendor, productId: "p1", vendorSku: "ABC 123" }],
  );
  assert.equal(result.state, "EXACT");
  assert.equal(result.vendorProductId, "vp1");
});

test("same SKU from another vendor or organization cannot auto-match", () => {
  const mappings = [
    { organizationId: org, id: "vp1", vendorId: "vendor-b", productId: "p1", vendorSku: "ABC-123" },
    { organizationId: "org-b", id: "vp2", vendorId: vendor, productId: "p1", vendorSku: "ABC-123" },
  ];
  assert.notEqual(matchInvoiceProduct(line(), org, vendor, [], mappings).state, "EXACT");
});

test("trusted identifier can auto-match only with compatible physical identity", () => {
  assert.equal(
    matchInvoiceProduct(line(), org, vendor, [product({ vendorItemNumber: "ABC123" })], []).state,
    "EXACT",
  );
  assert.equal(
    matchInvoiceProduct(
      line({ packageSize: "100/Bx" }),
      org,
      vendor,
      [product({ vendorItemNumber: "ABC123" })],
      [],
    ).state,
    "UNRESOLVED",
  );
});

test("strong descriptions are suggestions and never automatic", () => {
  const result = matchInvoiceProduct(line({ sku: "" }), org, vendor, [product()], []);
  assert.equal(result.state, "SUGGESTED");
  assert.equal(result.productId, "p1");
});

test("dimensions, package quantity, and UOM distinctions are preserved", () => {
  assert.equal(
    matchInvoiceProduct(
      line({ sku: "", description: "Surgical tape 1 inch" }),
      org,
      vendor,
      [product()],
      [],
    ).state,
    "UNRESOLVED",
  );
  assert.equal(
    matchInvoiceProduct(line({ sku: "", unitOfMeasure: "each" }), org, vendor, [product()], [])
      .state,
    "UNRESOLVED",
  );
  assert.equal(normalizePackageSize("10 / Bx"), "10/box");
  assert.equal(normalizeDescription("Tape 1.5”"), "tape 1.5 inch");
});

test("ambiguous or weak descriptions remain unresolved", () => {
  const ambiguous = [product(), product({ id: "p2" })];
  assert.equal(
    matchInvoiceProduct(line({ sku: "" }), org, vendor, ambiguous, []).state,
    "UNRESOLVED",
  );
  assert.equal(
    matchInvoiceProduct(
      line({ sku: "", description: "Medical supply" }),
      org,
      vendor,
      [product()],
      [],
    ).state,
    "UNRESOLVED",
  );
});

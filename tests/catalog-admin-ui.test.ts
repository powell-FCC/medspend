import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  catalogPackagePresentation,
  catalogSearchRank,
  isCatalogAdminRole,
  type CatalogAdminResult,
} from "../src/catalog-admin/catalog-admin.ts";

const root = new URL("../", import.meta.url);
const routePath = new URL("src/routes/_authenticated/products.tsx", root);
const pagePath = new URL("src/components/catalog/CatalogAdminPage.tsx", root);
const serverPath = new URL("src/lib/catalog.functions.ts", root);
const shellPath = new URL("src/components/app/AdminAppShell.tsx", root);

function result(overrides: Partial<CatalogAdminResult> = {}): CatalogAdminResult {
  return {
    catalogVendorProductId: "00000000-0000-0000-0000-000000000001",
    catalogProductId: "00000000-0000-0000-0000-000000000002",
    catalogVendorId: "00000000-0000-0000-0000-000000000003",
    productName: "Good'N'Cheap Underwrap",
    description: "Medical prewrap",
    manufacturer: "Good'N'Cheap",
    productActive: true,
    vendorName: "Henry Schein",
    vendorSku: "128-5852",
    normalizedVendorSku: "128-5852",
    manufacturerSku: null,
    packageDescription: "10 rolls",
    packageQuantity: 10,
    packageUnit: "rolls",
    packageStatus: "verified",
    active: true,
    discontinued: false,
    verificationStatus: "verified",
    adoptionState: "not_adopted",
    adoptionIssue: null,
    organizationVendorProductId: null,
    ...overrides,
  };
}

test("catalog roles allow only owners and admins", () => {
  assert.equal(isCatalogAdminRole("owner"), true);
  assert.equal(isCatalogAdminRole("admin"), true);
  assert.equal(isCatalogAdminRole("staff"), false);
  assert.equal(isCatalogAdminRole(undefined), false);
});

test("search ranking keeps exact SKU identities ahead of text matches", () => {
  const exact = result({ vendorSku: "128-5852", normalizedVendorSku: "128-5852" });
  const separate = result({
    catalogVendorProductId: "00000000-0000-0000-0000-000000000004",
    vendorSku: "128-5853",
    normalizedVendorSku: "128-5853",
    productName: "Good'N'Cheap Adhesive Stretch Tape",
  });
  const manufacturer = result({
    catalogVendorProductId: "00000000-0000-0000-0000-000000000005",
    vendorSku: "other",
    normalizedVendorSku: "OTHER",
  });
  assert.equal(catalogSearchRank(exact, "128-5852"), 0);
  assert.equal(catalogSearchRank(separate, "128-5852"), 6);
  assert.ok(catalogSearchRank(exact, "128-5852") < catalogSearchRank(manufacturer, "Good'N'Cheap"));
  assert.notEqual(exact.catalogVendorProductId, separate.catalogVendorProductId);
});

test("package presentation never implies normalized values for source-only or unknown data", () => {
  const verified = catalogPackagePresentation(result());
  assert.deepEqual(verified, { label: "Verified package", detail: "10 rolls", verified: true });
  const sourceOnly = catalogPackagePresentation(
    result({
      packageStatus: "source_only",
      packageQuantity: null,
      packageUnit: null,
      packageDescription: "1 case / 12 each",
    }),
  );
  assert.deepEqual(sourceOnly, {
    label: "Source only",
    detail: "1 case / 12 each",
    verified: false,
  });
  const unknown = catalogPackagePresentation(
    result({
      packageStatus: "unknown",
      packageQuantity: null,
      packageUnit: null,
      packageDescription: null,
    }),
  );
  assert.deepEqual(unknown, {
    label: "Unknown package",
    detail: "Package not specified",
    verified: false,
  });
});

test("catalog admin server functions use auth, database pagination, exclusive ranking buckets, and set-based adoption", async () => {
  const source = await readFile(serverPath, "utf8");
  const adminBlock = source.slice(
    source.indexOf("const catalogLifecycle"),
    source.indexOf("export const saveCategoryFn"),
  );
  for (const functionName of [
    "listCatalogAdminVendorsFn",
    "searchCatalogAdminFn",
    "getCatalogAdminDetailFn",
    "adoptCatalogVendorProductFn",
  ]) {
    const start = adminBlock.indexOf(`export const ${functionName}`);
    const end = adminBlock.indexOf("export const ", start + 1);
    const block = adminBlock.slice(start, end === -1 ? undefined : end);
    assert.match(
      block,
      /middleware\(\[requireSupabaseAuth\]\)/,
      `${functionName} must require auth`,
    );
    assert.match(
      block,
      /await assertAdmin\(db, context\.userId,/,
      `${functionName} must enforce owner/admin server-side`,
    );
  }
  assert.match(adminBlock, /\.select\(catalogAdminSelect\(adoptionInner\), options\)/);
  assert.match(adminBlock, /\.eq\("orgAdoptions\.organization_id", input\.organizationId\)/);
  assert.match(adminBlock, /\.is\("orgAdoptions", null\)/);
  assert.match(adminBlock, /\.in\("catalog_vendor_id", catalogVendorIds\)/);
  assert.match(adminBlock, /\.in\("catalog_product_id", catalogProductIds\)/);
  assert.match(adminBlock, /count: "exact"/);
  assert.match(adminBlock, /\.range\(start, end\)/);
  assert.match(adminBlock, /const totalCount = counts\.reduce/);
  assert.match(adminBlock, /totalPages: Math\.ceil\(totalCount \/ CATALOG_ADMIN_PAGE_SIZE\)/);
  assert.match(adminBlock, /normalized_sku_exact/);
  assert.match(adminBlock, /raw_sku_exact/);
  assert.match(adminBlock, /\.neq\("normalized_vendor_sku", terms\.normalizedSku\)/);
  assert.match(adminBlock, /\.not\("normalized_vendor_sku", "ilike", terms\.skuPrefixPattern\)/);
  assert.match(adminBlock, /\.neq\("vendor_sku", terms\.raw\)/);
  assert.match(adminBlock, /\.not\("product\.normalized_name", "ilike", terms\.namePattern\)/);
  assert.match(adminBlock, /normalized_manufacturer\.not\.ilike/);
  assert.doesNotMatch(
    adminBlock,
    /catalog_source_records|catalog_import_batches|catalog_verification_overrides/,
  );
  assert.doesNotMatch(adminBlock, /inventory_items|inventory_adjustments/);
});

test("catalog admin wrappers invoke only the deployed RPCs with active organization and exact identity", async () => {
  const source = await readFile(serverPath, "utf8");
  const detail = source.slice(
    source.indexOf("export const getCatalogAdminDetailFn"),
    source.indexOf("export const adoptCatalogVendorProductFn"),
  );
  const adoption = source.slice(
    source.indexOf("export const adoptCatalogVendorProductFn"),
    source.indexOf("export const saveCategoryFn"),
  );
  assert.match(detail, /rpc\("get_catalog_vendor_product_admin_detail"/);
  assert.match(detail, /_organization_id: data\.organizationId/);
  assert.match(detail, /_catalog_vendor_product_id: data\.catalogVendorProductId/);
  assert.match(detail, /catalogAdminDetailSchema\.parse\(detail\)/);
  assert.match(adoption, /rpc\("adopt_catalog_vendor_product"/);
  assert.match(adoption, /_organization_id: data\.organizationId/);
  assert.match(adoption, /_catalog_vendor_product_id: data\.catalogVendorProductId/);
  assert.match(adoption, /catalogAdoptionResultSchema\.parse\(result\)/);
  assert.doesNotMatch(
    detail + adoption,
    /from\("catalog_(source_records|import_batches|verification_overrides)"\)/,
  );
  assert.doesNotMatch(detail + adoption, /inventory_items|inventory_adjustments/);
});

test("products route preserves search, filters, and page state and has no category editor", async () => {
  const route = await readFile(routePath, "utf8");
  assert.match(route, /validateSearch: catalogSearchSchema/);
  for (const field of ["q", "vendorId", "lifecycle", "packageStatus", "adoption", "page"])
    assert.match(route, new RegExp(field));
  assert.match(route, /CatalogAdminPage/);
  assert.doesNotMatch(route, /saveCategoryFn|product_categories|Categories/);
});

test("admin navigation exposes Catalog on desktop and mobile while staff navigation is untouched", async () => {
  const shell = await readFile(shellPath, "utf8");
  assert.match(shell, /to: "\/products", label: "Catalog"/);
  assert.match(shell, /aria-label="Admin navigation"/);
  assert.match(
    shell,
    /nav\s*\.filter\(\(item\) => !\("ownerOnly" in item\) \|\| active\?\.role === "owner"\)/,
  );
  const staff = await readFile(new URL("src/components/app/StaffAppShell.tsx", root), "utf8");
  assert.doesNotMatch(staff, /Catalog|\/products/);
});

test("catalog UI renders sanitized detail fields and blocks optimistic or inventory behavior", async () => {
  const page = await readFile(pagePath, "utf8");
  assert.match(page, /data-section="catalog-detail"/);
  for (const field of [
    "Source provenance",
    "Active verification decisions",
    "Raw vendor SKU",
    "Normalized SKU",
    "Production rule",
  ])
    assert.match(page, new RegExp(field));
  assert.match(page, /getCatalogAdminDetailFn/);
  assert.match(page, /invalidateQueries\(\{ queryKey: \["catalog-admin", organizationId\]/);
  assert.match(page, /adoption\.mutate\(row\.catalogVendorProductId\)/);
  assert.doesNotMatch(
    page,
    /inventory_items|inventory_adjustments|catalog_source_records|JSON\.stringify/,
  );
  assert.doesNotMatch(page, /setAdoptingId\(.*\).*adoptionState/);
});

test("known identity presentation keeps the two Good'N'Cheap SKUs separate and preserves discontinued state", async () => {
  const page = await readFile(pagePath, "utf8");
  assert.match(page, /row\.vendorSku/);
  assert.match(page, /row\.discontinued/);
  assert.match(page, /row\.manufacturer/);
  const first = result({ vendorSku: "128-5852", normalizedVendorSku: "128-5852" });
  const second = result({
    catalogVendorProductId: "00000000-0000-0000-0000-000000000006",
    vendorSku: "128-5853",
    normalizedVendorSku: "128-5853",
  });
  const discontinued = result({ discontinued: true, active: false });
  assert.equal(catalogSearchRank(first, "128-5852"), 0);
  assert.equal(catalogSearchRank(second, "128-5852"), 6);
  assert.equal(discontinued.discontinued, true);
  assert.equal(discontinued.active, false);
});

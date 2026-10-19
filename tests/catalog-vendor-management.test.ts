import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import test from "node:test";
import {
  COVERAGE_STATUS_LABELS,
  GLOBAL_CATALOG_PROMOTION_AVAILABLE,
  GLOBAL_CATALOG_PROMOTION_UNAVAILABLE_REASON,
  canLinkOrganizationVendor,
  catalogListingStateLabel,
  catalogVendorLinkBlockReason,
  coverageStatusDetail,
  describeCatalogVendorLinkError,
  filterCoverageRows,
  filterLinkableCatalogVendors,
  isRepresentedInCatalog,
  vendorLinkPresentation,
  type CatalogCoverageRow,
  type LinkableCatalogVendor,
  type OrganizationVendorLink,
} from "../src/catalog-admin/vendor-management.ts";

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const migrationName = "20261019120000_catalog_vendor_management.sql";
const migration = read(`../supabase/migrations/${migrationName}`);
const migrationCode = migration.replace(/--.*$/gm, "");
const behavior = read("../supabase/tests/catalog_vendor_management_behavior.sql");
const mutationCheck = read("../supabase/tests/catalog_vendor_management_mutation_check.sh");
const server = read("../src/lib/catalog-vendor-management.functions.ts");
const sections = read("../src/components/catalog/CatalogVendorSections.tsx");
const page = read("../src/components/catalog/CatalogVendorManagementPage.tsx");
const route = read("../src/routes/_authenticated/catalog-vendors.tsx");
const shell = read("../src/components/app/AdminAppShell.tsx");
const catalogPage = read("../src/components/catalog/CatalogAdminPage.tsx");
const matchDialog = read("../src/components/invoice-processing/ProductMatchDialog.tsx");
const types = read("../src/integrations/supabase/types.ts");

const between = (source: string, start: string, end: string) => {
  const from = source.indexOf(start);
  assert.ok(from >= 0, `missing ${start}`);
  const to = source.indexOf(end, from + start.length);
  assert.ok(to > from, `missing ${end}`);
  return source.slice(from, to);
};
const guard = between(
  migrationCode,
  "CREATE FUNCTION public.guard_vendor_catalog_link",
  "REVOKE ALL ON FUNCTION public.guard_vendor_catalog_link",
);
const linkRpc = between(
  migrationCode,
  "CREATE FUNCTION public.link_organization_vendor_to_catalog_vendor",
  "REVOKE ALL ON FUNCTION public.link_organization_vendor_to_catalog_vendor",
);
const coverageRpc = between(
  migrationCode,
  "CREATE FUNCTION public.get_organization_vendor_catalog_coverage",
  "REVOKE ALL ON FUNCTION public.get_organization_vendor_catalog_coverage",
);

function vendor(overrides: Partial<OrganizationVendorLink> = {}): OrganizationVendorLink {
  return {
    vendorId: "00000000-0000-4000-8000-000000000301",
    vendorName: "Henry Schein",
    vendorActive: true,
    updatedAt: "2026-10-19T12:00:00.123456+00:00",
    catalogVendorId: null,
    catalogVendorName: null,
    catalogVendorActive: null,
    ...overrides,
  };
}

function catalogVendor(overrides: Partial<LinkableCatalogVendor> = {}): LinkableCatalogVendor {
  return {
    id: "00000000-0000-4000-8000-000000000201",
    name: "Henry Schein",
    active: true,
    linkedOrganizationVendorName: null,
    ...overrides,
  };
}

function coverageRow(overrides: Partial<CatalogCoverageRow> = {}): CatalogCoverageRow {
  return {
    vendorProductId: "00000000-0000-4000-8000-000000000501",
    vendorSku: "1439386",
    manufacturerSku: null,
    packageSize: "48 rolls",
    unitOfMeasure: "CS",
    mappingActive: true,
    mappingCreatedAt: "2026-10-01T00:00:00Z",
    productId: "00000000-0000-4000-8000-000000000401",
    productName: "Prewrap 2.75in",
    manufacturer: "Mueller",
    productActive: true,
    status: "not_cataloged",
    listing: null,
    ...overrides,
  };
}

// VENDOR LINKING

test("linked and unlinked vendor states present distinctly", () => {
  assert.deepEqual(
    [
      vendorLinkPresentation(vendor()).label,
      vendorLinkPresentation(
        vendor({
          catalogVendorId: "00000000-0000-4000-8000-000000000201",
          catalogVendorName: "Henry Schein",
          catalogVendorActive: true,
        }),
      ).label,
      vendorLinkPresentation(
        vendor({
          catalogVendorId: "00000000-0000-4000-8000-000000000201",
          catalogVendorName: "Henry Schein",
          catalogVendorActive: false,
        }),
      ).state,
    ],
    ["Needs link", "Linked", "linked_inactive"],
  );
});

test("only unlinked vendors get a link action; existing links are never offered for change", () => {
  assert.equal(canLinkOrganizationVendor(vendor()), true);
  assert.equal(
    canLinkOrganizationVendor(vendor({ catalogVendorId: "00000000-0000-4000-8000-000000000201" })),
    false,
  );
  assert.match(sections, /canLinkOrganizationVendor\(vendor\) \?/);
});

test("catalog vendor choices are filtered by typed text only and never auto-selected", () => {
  const vendors = [
    catalogVendor(),
    catalogVendor({ id: "00000000-0000-4000-8000-000000000202", name: "Medline" }),
  ];
  assert.equal(filterLinkableCatalogVendors(vendors, "").length, 2);
  assert.deepEqual(
    filterLinkableCatalogVendors(vendors, "  schein ").map((row) => row.name),
    ["Henry Schein"],
  );
  // The dialog starts with no choice for each vendor and the page clears the search text.
  assert.match(
    sections,
    /setChosenId\(null\);\s*setConfirming\(false\);\s*\}, \[vendor\?\.vendorId\]\)/,
  );
  assert.match(page, /setCatalogQuery\(""\);\s*setLinkingVendor\(vendor\);/);
  assert.doesNotMatch(page, /setCatalogQuery\(vendor\.vendorName\)/);
});

test("inactive or already-taken catalog vendors cannot be chosen", () => {
  assert.equal(catalogVendorLinkBlockReason(catalogVendor()), null);
  assert.equal(
    catalogVendorLinkBlockReason(catalogVendor({ active: false })),
    "Inactive catalog vendor",
  );
  assert.equal(
    catalogVendorLinkBlockReason(catalogVendor({ linkedOrganizationVendorName: "HS Main" })),
    "Already linked to HS Main",
  );
});

test("linking requires an explicit confirmation step naming both vendors", () => {
  assert.match(sections, /Organization vendor/);
  assert.match(sections, /Will link to catalog vendor/);
  assert.match(sections, /onClick=\{\(\) => setConfirming\(true\)\}/);
  assert.match(sections, /Review link/);
  // Only the confirmation step calls onConfirm.
  assert.equal(sections.match(/onConfirm\(/g)?.length, 1);
  assert.match(sections, /chosen && onConfirm\(chosen\)/);
});

test("link domain errors map to actionable messages", () => {
  assert.match(
    describeCatalogVendorLinkError("42501", "Only organization owners"),
    /owners and admins/,
  );
  assert.match(describeCatalogVendorLinkError("40001", "changed"), /changed since the page loaded/);
  assert.match(
    describeCatalogVendorLinkError("P0002", "Catalog vendor not found"),
    /catalog vendor no longer exists/,
  );
  assert.match(
    describeCatalogVendorLinkError("P0002", "Organization vendor not found"),
    /vendor no longer exists in this organization/,
  );
  assert.match(
    describeCatalogVendorLinkError(
      "55000",
      "Organization vendor is already linked to a different catalog vendor",
    ),
    /cannot be changed here/,
  );
  assert.match(describeCatalogVendorLinkError("55000", "Catalog vendor is inactive"), /inactive/);
  assert.match(describeCatalogVendorLinkError("23505", "Another"), /Another vendor/);
  assert.equal(
    describeCatalogVendorLinkError(undefined, "boom"),
    "Unable to link this vendor to the catalog.",
  );
});

test("server functions are admin-checked and send the stale-write token", () => {
  assert.equal(
    server.match(/await assertAdmin\(db, context\.userId, data\.organizationId\)/g)?.length,
    4,
  );
  assert.match(server, /_expected_updated_at: data\.expectedUpdatedAt/);
  assert.match(page, /expectedUpdatedAt: vendor\.updatedAt/);
  // Links are only written through the RPC, never through a direct table update.
  assert.doesNotMatch(server, /\.update\(/);
  assert.doesNotMatch(server, /\.insert\(/);
  assert.match(server, /rpc\("link_organization_vendor_to_catalog_vendor"/);
  assert.match(server, /escapePostgresLike\(data\.q\)/);
});

test("no source path writes vendors.catalog_vendor_id directly", () => {
  const files = [
    "../src/lib/catalog.functions.ts",
    "../src/lib/catalog-vendor-management.functions.ts",
    "../src/lib/invoice-processing.functions.ts",
    "../src/lib/vendor-invoices.functions.ts",
  ].map(read);
  for (const source of files) {
    assert.doesNotMatch(source, /(^|[^_\w])catalog_vendor_id:\s/m);
  }
});

test("the link RPC is explicit, owner/admin only, stale-safe, and never name-based", () => {
  assert.match(linkRpc, /SECURITY DEFINER/);
  assert.match(linkRpc, /public\.is_org_admin\(_organization_id, auth\.uid\(\)\)/);
  assert.match(
    linkRpc,
    /WHERE id = _vendor_id AND organization_id = _organization_id\s+FOR UPDATE/,
  );
  assert.match(linkRpc, /IF _vendor\.catalog_vendor_id IS NOT NULL THEN/);
  assert.match(linkRpc, /_vendor\.updated_at IS DISTINCT FROM _expected_updated_at/);
  assert.match(linkRpc, /IF NOT _catalog_vendor\.active THEN/);
  assert.match(linkRpc, /hashtextextended\('catalog-adoption:'/);
  assert.doesNotMatch(
    linkRpc,
    /normalized_name|ilike|similarity|INSERT INTO public\.catalog_vendors/i,
  );
});

test("API-role writes cannot set links and nobody repoints an existing link", () => {
  assert.match(guard, /current_user IN \('authenticated', 'anon'\)/);
  assert.match(guard, /TG_OP = 'INSERT' AND NEW\.catalog_vendor_id IS NOT NULL/);
  assert.match(guard, /NEW\.catalog_vendor_id IS DISTINCT FROM OLD\.catalog_vendor_id/);
  assert.match(
    guard,
    /OLD\.catalog_vendor_id IS NOT NULL\s+AND NEW\.catalog_vendor_id IS NOT NULL/,
  );
  assert.match(
    migrationCode,
    /CREATE TRIGGER vendors_guard_catalog_link\s+BEFORE INSERT OR UPDATE OF catalog_vendor_id ON public\.vendors/,
  );
});

// COVERAGE

test("coverage is read-only, caller-privileged, and scoped to the linked catalog vendor", () => {
  assert.match(coverageRpc, /STABLE\s+SECURITY INVOKER/);
  assert.match(coverageRpc, /public\.is_org_admin\(_organization_id, auth\.uid\(\)\)/);
  assert.match(coverageRpc, /vendor_product\.organization_id = _organization_id/);
  assert.match(coverageRpc, /exact\.catalog_vendor_id = _catalog_vendor\.id/);
  assert.match(coverageRpc, /listing\.catalog_vendor_id = _catalog_vendor\.id/);
  assert.match(coverageRpc, /public\.normalize_catalog_sku\(vendor_product\.vendor_sku\)/);
  assert.match(
    coverageRpc,
    /public\.normalize_catalog_sku_match_key\(vendor_product\.vendor_sku\)/,
  );
  // Identity never comes from text similarity.
  assert.doesNotMatch(coverageRpc, /ilike|similarity|normalized_name =|description/i);
});

test("the migration never writes the global catalog", () => {
  assert.doesNotMatch(migrationCode, /(INSERT INTO|UPDATE|DELETE FROM)\s+public\.catalog_/i);
  assert.doesNotMatch(migrationCode, /ALTER TABLE|CREATE TABLE|DROP /i);
  assert.match(
    migrationCode,
    /REVOKE ALL ON FUNCTION public\.link_organization_vendor_to_catalog_vendor\(uuid, uuid, uuid, timestamptz\)\s+FROM PUBLIC, anon;/,
  );
  assert.match(
    migrationCode,
    /REVOKE ALL ON FUNCTION public\.get_organization_vendor_catalog_coverage\(uuid, uuid\) FROM PUBLIC, anon;/,
  );
  assert.match(
    migrationCode,
    /REVOKE ALL ON FUNCTION public\.guard_vendor_catalog_link\(\) FROM PUBLIC, anon, authenticated;/,
  );
});

test("the migration is new, last, and leaves earlier migrations alone", () => {
  const migrations = readdirSync(new URL("../supabase/migrations/", import.meta.url)).sort();
  assert.equal(migrations.at(-1), migrationName);
});

test("coverage statuses: represented means any catalog listing, never a judgment on the product", () => {
  assert.deepEqual(
    (["linked", "exact", "separator_equivalent", "ambiguous", "not_cataloged"] as const).map(
      isRepresentedInCatalog,
    ),
    [true, true, true, true, false],
  );
  assert.equal(COVERAGE_STATUS_LABELS.not_cataloged, "Not in catalog");
  assert.match(coverageStatusDetail(coverageRow()), /does not mean the local product is wrong/);
  assert.match(
    coverageStatusDetail(
      coverageRow({
        status: "separator_equivalent",
        vendorSku: "1127149",
        listing: {
          id: "00000000-0000-4000-8000-000000000222",
          vendorSku: "112-7149",
          productName: "Sharps",
          verificationStatus: "verified",
          active: true,
          discontinued: false,
        },
      }),
    ),
    /112-7149/,
  );
  assert.match(
    coverageStatusDetail(coverageRow({ status: "ambiguous" })),
    /Nothing is chosen automatically/,
  );
});

test("listing state is reported as stored", () => {
  const listing = {
    id: "00000000-0000-4000-8000-000000000225",
    vendorSku: "777-0002",
    productName: "Discontinued",
    verificationStatus: "verified",
    active: false,
    discontinued: true,
  };
  assert.equal(catalogListingStateLabel(listing), "Discontinued");
  assert.equal(catalogListingStateLabel({ ...listing, discontinued: false }), "Inactive");
  assert.equal(
    catalogListingStateLabel({
      ...listing,
      active: true,
      discontinued: false,
      verificationStatus: "rejected",
    }),
    "Rejected",
  );
  assert.equal(
    catalogListingStateLabel({
      ...listing,
      active: true,
      discontinued: false,
      verificationStatus: "pending",
    }),
    "Unverified",
  );
});

test("coverage filter defaults to organization-only rows", () => {
  const rows = [coverageRow(), coverageRow({ vendorProductId: "x", status: "exact" })];
  assert.equal(filterCoverageRows(rows, "not_cataloged").length, 1);
  assert.equal(filterCoverageRows(rows, "all").length, 2);
  assert.match(
    route,
    /coverage: z\.enum\(\["not_cataloged", "all"\]\)\.default\("not_cataloged"\)/,
  );
});

// PROMOTION — deliberately not implemented

test("global promotion is unavailable and the UI offers no promote action", () => {
  assert.equal(GLOBAL_CATALOG_PROMOTION_AVAILABLE, false);
  assert.match(GLOBAL_CATALOG_PROMOTION_UNAVAILABLE_REASON, /platform catalog administrator/);
  assert.match(sections, /data-section="promotion-unavailable"/);
  for (const source of [sections, page, matchDialog, catalogPage]) {
    assert.doesNotMatch(source, /Promote|Add to global catalog/);
  }
  assert.doesNotMatch(server, /catalog_products|catalog_vendor_products/);
});

// UI

test("page renders loading, error, and empty states for vendors and coverage", () => {
  assert.match(page, /Loading vendors…/);
  assert.match(page, /Unable to load organization vendors\./);
  assert.match(sections, /This organization has no vendors yet\./);
  assert.match(sections, /Loading catalog coverage…/);
  assert.match(sections, /Choose a linked vendor above/);
  assert.match(sections, /is not linked to a catalog vendor, so there is no catalog to compare/);
  assert.match(sections, /Every mapped \$\{coverage\.vendorName\} SKU is already in the/);
  assert.match(sections, /No catalog vendors match\. Catalog vendors are not created from here\./);
  assert.match(sections, /Showing the first 1,000 mappings/);
});

test("coverage table shows the requested columns and a review drawer", () => {
  for (const column of [
    "Vendor SKU",
    "Organization product",
    "Manufacturer",
    "Package / UOM",
    "Catalog status",
    "Action",
  ]) {
    assert.match(sections, new RegExp(`>${column.replace("/", "\\/")}<`));
  }
  assert.match(sections, /<SheetContent[^>]*data-sheet="coverage-review"/);
  assert.match(sections, /Private to this organization\. Never shared with other organizations\./);
});

test("route, navigation, and catalog page point at catalog vendor management", () => {
  assert.match(route, /createFileRoute\("\/_authenticated\/catalog-vendors"\)/);
  assert.match(shell, /to: "\/catalog-vendors", label: "Catalog Vendors"/);
  assert.match(catalogPage, /to="\/catalog-vendors"/);
  assert.match(page, /isCatalogAdminRole\(active\.role\)\) return null/);
  assert.match(types, /link_organization_vendor_to_catalog_vendor: \{/);
  assert.match(types, /get_organization_vendor_catalog_coverage: \{/);
});

test("invoice line creation says the product stays organization-only", () => {
  assert.match(matchDialog, /data-hint="organization-only"/);
  assert.match(
    matchDialog,
    /Saved for your organization only\. It is not added to the shared vendor catalog;/,
  );
});

// DATABASE SUITES

test("the behavior suite covers the boundary cases and the mutation check targets the migration", () => {
  for (const expected of [
    "Only organization owners and admins can link catalog vendors",
    "Organization vendor not found",
    "Catalog vendor not found",
    "Catalog vendor is inactive",
    "Organization vendor changed since it was loaded",
    "Organization vendor is already linked to a different catalog vendor",
    "Another organization vendor is already linked to this catalog vendor",
    "Catalog vendor links can only be set through catalog vendor management",
    "An existing catalog vendor link cannot be repointed to a different catalog vendor",
    "same-name catalog vendor was not linked implicitly",
    "organization B mapping is absent from organization A coverage",
    "catalog, existing products and mappings, invoices, inventory, and price history are untouched",
  ]) {
    assert.ok(behavior.includes(expected), `behavior suite covers: ${expected}`);
  }
  assert.match(behavior, /^BEGIN;/m);
  assert.match(behavior, /^ROLLBACK;\s*$/m);
  assert.match(mutationCheck, new RegExp(migrationName.replace(".", "\\.")));
  assert.match(mutationCheck, /never point this at\n# production/);
});

// Catalog vendor management: linking organization vendors to global catalog vendors and
// reviewing which organization SKU mappings the linked catalog already lists.
//
// Nothing here decides an identity. Linking is always an explicit choice by an owner/admin
// and is enforced server-side (link_organization_vendor_to_catalog_vendor). Coverage status
// comes from get_organization_vendor_catalog_coverage and is only displayed here.

export interface OrganizationVendorLink {
  vendorId: string;
  vendorName: string;
  vendorActive: boolean;
  /** The vendor row's updated_at as loaded; sent back as the stale-write token. */
  updatedAt: string;
  catalogVendorId: string | null;
  catalogVendorName: string | null;
  catalogVendorActive: boolean | null;
}

export interface LinkableCatalogVendor {
  id: string;
  name: string;
  active: boolean;
  /** Name of the organization vendor already linked to this catalog vendor, if any. */
  linkedOrganizationVendorName: string | null;
}

export interface CatalogVendorLinkResult {
  organizationId: string;
  vendorId: string;
  catalogVendorId: string;
  catalogVendorName: string;
  alreadyLinked: boolean;
  updatedAt: string;
}

export type CatalogCoverageStatus =
  | "linked"
  | "exact"
  | "separator_equivalent"
  | "ambiguous"
  | "not_cataloged";

export interface CatalogCoverageListing {
  id: string;
  vendorSku: string;
  productName: string;
  verificationStatus: string;
  active: boolean;
  discontinued: boolean;
}

export interface CatalogCoverageRow {
  vendorProductId: string;
  vendorSku: string;
  manufacturerSku: string | null;
  packageSize: string | null;
  unitOfMeasure: string | null;
  mappingActive: boolean;
  mappingCreatedAt: string;
  productId: string;
  productName: string;
  manufacturer: string | null;
  productActive: boolean;
  status: CatalogCoverageStatus;
  listing: CatalogCoverageListing | null;
}

export interface CatalogCoverageSummary {
  mapped: number;
  represented: number;
  notRepresented: number;
  inactiveMappings: number;
}

export interface CatalogCoverage {
  vendorId: string;
  vendorName: string;
  linked: boolean;
  catalogVendor: { id: string; name: string; active: boolean } | null;
  summary: CatalogCoverageSummary | null;
  rows: CatalogCoverageRow[];
  truncated: boolean;
}

export type CoverageFilter = "not_cataloged" | "all";

export type VendorLinkState = "linked" | "linked_inactive" | "unlinked";

export function vendorLinkState(vendor: OrganizationVendorLink): VendorLinkState {
  if (!vendor.catalogVendorId) return "unlinked";
  return vendor.catalogVendorActive === false ? "linked_inactive" : "linked";
}

export function vendorLinkPresentation(vendor: OrganizationVendorLink): {
  state: VendorLinkState;
  label: string;
  detail: string;
} {
  const state = vendorLinkState(vendor);
  if (state === "unlinked") {
    return {
      state,
      label: "Needs link",
      detail: "Invoices can only use this organization's own products and SKUs.",
    };
  }
  if (state === "linked_inactive") {
    return {
      state,
      label: "Catalog vendor inactive",
      detail: "The linked catalog vendor is inactive, so its catalog is not used for invoices.",
    };
  }
  return {
    state,
    label: "Linked",
    detail: "Invoices can match this vendor's verified catalog SKUs.",
  };
}

export const COVERAGE_STATUS_LABELS: Record<CatalogCoverageStatus, string> = {
  linked: "In catalog · adopted",
  exact: "In catalog",
  separator_equivalent: "In catalog · separator variant",
  ambiguous: "Several catalog SKUs match",
  not_cataloged: "Not in catalog",
};

export function isRepresentedInCatalog(status: CatalogCoverageStatus): boolean {
  return status !== "not_cataloged";
}

export function coverageStatusDetail(row: CatalogCoverageRow): string {
  if (row.status === "not_cataloged") {
    return "The linked catalog has no listing with this SKU. That does not mean the local product is wrong.";
  }
  if (row.status === "ambiguous") {
    return "More than one catalog SKU differs from this SKU only by separators. Nothing is chosen automatically.";
  }
  if (row.status === "separator_equivalent" && row.listing) {
    return `Listed in the catalog as ${row.listing.vendorSku}.`;
  }
  if (row.status === "linked") return "This mapping came from adopting a catalog listing.";
  return "The catalog lists this exact SKU.";
}

export function catalogListingStateLabel(listing: CatalogCoverageListing): string {
  if (listing.discontinued) return "Discontinued";
  if (!listing.active) return "Inactive";
  if (listing.verificationStatus !== "verified") {
    return listing.verificationStatus === "rejected" ? "Rejected" : "Unverified";
  }
  return "Verified";
}

export function filterCoverageRows(
  rows: CatalogCoverageRow[],
  filter: CoverageFilter,
): CatalogCoverageRow[] {
  return filter === "all" ? rows : rows.filter((row) => row.status === "not_cataloged");
}

/**
 * Narrows the catalog vendor list by what the admin typed. Matching is a plain substring
 * filter for a person to choose from; it never selects a vendor and is never prefilled.
 */
export function filterLinkableCatalogVendors(
  vendors: LinkableCatalogVendor[],
  query: string,
): LinkableCatalogVendor[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return vendors;
  return vendors.filter((vendor) => vendor.name.toLowerCase().includes(needle));
}

/**
 * Why a catalog vendor cannot be chosen, if it cannot. Only unlinked organization vendors
 * are offered a link, so any existing organization link belongs to a different vendor.
 */
export function catalogVendorLinkBlockReason(vendor: LinkableCatalogVendor): string | null {
  if (!vendor.active) return "Inactive catalog vendor";
  if (vendor.linkedOrganizationVendorName) {
    return `Already linked to ${vendor.linkedOrganizationVendorName}`;
  }
  return null;
}

/** Only an unlinked vendor gets a link action; existing links are never changed here. */
export function canLinkOrganizationVendor(vendor: OrganizationVendorLink): boolean {
  return vendor.catalogVendorId === null;
}

/** Maps the link RPC's controlled domain errors to what the admin should do next. */
export function describeCatalogVendorLinkError(
  code: string | undefined,
  message: string | undefined,
): string {
  const text = message ?? "";
  if (code === "42501") return "Only organization owners and admins can link catalog vendors.";
  if (code === "40001") {
    return "This vendor changed since the page loaded. Reload and review the link again.";
  }
  if (code === "P0002" && text.includes("Catalog vendor")) {
    return "That catalog vendor no longer exists.";
  }
  if (code === "P0002") return "This vendor no longer exists in this organization.";
  if (code === "55000" && text.includes("already linked")) {
    return "This vendor is already linked to a different catalog vendor. Existing links cannot be changed here.";
  }
  if (code === "55000" && text.includes("inactive")) {
    return "That catalog vendor is inactive and cannot be linked.";
  }
  if (code === "23505") {
    return "Another vendor in this organization is already linked to that catalog vendor.";
  }
  return "Unable to link this vendor to the catalog.";
}

/**
 * Global catalog promotion is deliberately unavailable: global catalog tables are writable
 * only by the platform service role, and SportSpend has no platform catalog-admin
 * permission yet. Organization owners and admins must not write global catalog truth.
 */
export const GLOBAL_CATALOG_PROMOTION_AVAILABLE = false;

export const GLOBAL_CATALOG_PROMOTION_UNAVAILABLE_REASON =
  "Adding items to the shared vendor catalog needs a platform catalog administrator, which SportSpend does not have yet. This mapping stays saved for your organization and keeps matching your invoices.";

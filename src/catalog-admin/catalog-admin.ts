export const CATALOG_ADMIN_PAGE_SIZE = 25;

export type CatalogLifecycleFilter = "active" | "discontinued" | "all";
export type CatalogPackageFilter = "verified" | "source_only" | "unknown" | "all";
export type CatalogAdoptionFilter = "adopted" | "not_adopted" | "all";
export type CatalogPackageStatus = Exclude<CatalogPackageFilter, "all">;
export type CatalogAdoptionState = "adopted" | "not_adopted" | "attention";
export type CatalogInventoryState = "not_applicable" | "not_stocked" | "stocked" | "attention";

export interface CatalogAdminSearchInput {
  organizationId: string;
  q: string;
  vendorId: string | null;
  lifecycle: CatalogLifecycleFilter;
  packageStatus: CatalogPackageFilter;
  adoption: CatalogAdoptionFilter;
  page: number;
}

export interface CatalogAdminVendor {
  id: string;
  name: string;
}

export interface CatalogAdminResult {
  catalogVendorProductId: string;
  catalogProductId: string;
  catalogVendorId: string;
  productName: string;
  description: string | null;
  manufacturer: string | null;
  productActive: boolean;
  vendorName: string;
  vendorSku: string;
  normalizedVendorSku: string;
  manufacturerSku: string | null;
  packageDescription: string | null;
  packageQuantity: number | null;
  packageUnit: string | null;
  packageStatus: CatalogPackageStatus;
  active: boolean;
  discontinued: boolean;
  verificationStatus: string;
  adoptionState: CatalogAdoptionState;
  adoptionIssue: string | null;
  organizationVendorProductId: string | null;
  organizationProductId: string | null;
  inventoryState: CatalogInventoryState;
  inventoryItemId: string | null;
  inventoryActive: boolean | null;
}

export interface CatalogAdminSearchResult {
  rows: CatalogAdminResult[];
  page: number;
  pageSize: number;
  totalCount: number;
  totalPages: number;
}

export interface CatalogAdminProvenance {
  sourceName: string;
  sourceVersion: string;
  sourcePage: string | null;
  rawVendorSku: string | null;
  rawProductName: string | null;
  rawVariant: string | null;
  rawPackage: string | null;
}

export interface CatalogAdminVerificationDecision {
  overrideType: string;
  evidenceStatus: string;
  productionRule: string;
  sourceVendorSku: string | null;
  verifiedVendorSku: string | null;
  effectiveFrom: string;
  sourceName: string | null;
  sourceVersion: string | null;
}

export interface CatalogAdminDetail {
  catalogVendorProductId: string;
  product: {
    id: string;
    name: string;
    manufacturer: string | null;
    description: string | null;
    active: boolean;
    verificationStatus: string;
  };
  vendor: {
    id: string;
    name: string;
    website: string | null;
    active: boolean;
    vendorSku: string;
    normalizedVendorSku: string;
    manufacturerSku: string | null;
  };
  package: {
    rawDescription: string | null;
    verifiedQuantity: number | null;
    verifiedUnit: string | null;
    status: CatalogPackageStatus;
  };
  lifecycle: {
    active: boolean;
    discontinued: boolean;
    verificationStatus: string;
  };
  provenance: CatalogAdminProvenance[];
  verificationOverrides: CatalogAdminVerificationDecision[];
}

export interface CatalogAdoptionResult {
  organizationId: string;
  catalogVendorProductId: string;
  vendorId: string;
  productId: string;
  vendorProductId: string;
  vendorCreated: boolean;
  productCreated: boolean;
  vendorProductCreated: boolean;
  alreadyAdopted: boolean;
}

export interface CatalogStockResult {
  organizationId: string;
  catalogVendorProductId: string;
  vendorProductId: string;
  productId: string;
  inventoryItemId: string;
  inventoryCreated: boolean;
  alreadyStocked: boolean;
  quantity: number;
  parLevel: number | null;
  unit: string;
  active: boolean;
}

export function isCatalogAdminRole(role: string | null | undefined): boolean {
  return role === "owner" || role === "admin";
}

export function normalizeCatalogText(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

export function normalizeCatalogSku(value: string): string {
  return value.trim().toUpperCase();
}

export function escapePostgresLike(value: string): string {
  return value.replace(/[\\%_]/g, "\\$&");
}

export function catalogSearchRank(row: CatalogAdminResult, query: string): number {
  const rawQuery = query.trim();
  const normalizedSku = normalizeCatalogSku(rawQuery);
  const normalizedText = normalizeCatalogText(rawQuery);
  if (normalizedSku && row.normalizedVendorSku === normalizedSku) return 0;
  if (rawQuery && row.vendorSku === rawQuery) return 1;
  if (normalizedSku && row.normalizedVendorSku.startsWith(normalizedSku)) return 2;
  if (normalizedText && normalizeCatalogText(row.productName).includes(normalizedText)) return 3;
  if (
    normalizedText &&
    row.manufacturer &&
    normalizeCatalogText(row.manufacturer).includes(normalizedText)
  ) {
    return 4;
  }
  if (
    normalizedText &&
    row.description &&
    normalizeCatalogText(row.description).includes(normalizedText)
  ) {
    return 5;
  }
  return 6;
}

export function catalogResultOrder(left: CatalogAdminResult, right: CatalogAdminResult): number {
  return (
    left.productName.localeCompare(right.productName) ||
    left.vendorName.localeCompare(right.vendorName) ||
    left.normalizedVendorSku.localeCompare(right.normalizedVendorSku) ||
    left.catalogVendorProductId.localeCompare(right.catalogVendorProductId)
  );
}

export function catalogPackagePresentation(
  row: Pick<
    CatalogAdminResult,
    "packageStatus" | "packageDescription" | "packageQuantity" | "packageUnit"
  >,
): { label: string; detail: string; verified: boolean } {
  if (row.packageStatus === "verified") {
    const normalized = [row.packageQuantity, row.packageUnit].filter(
      (value) => value !== null && value !== "",
    );
    return {
      label: "Verified package",
      detail: normalized.length ? normalized.join(" ") : "Verified package",
      verified: true,
    };
  }
  if (row.packageStatus === "source_only") {
    return {
      label: "Source only",
      detail: row.packageDescription || "Source package text unavailable",
      verified: false,
    };
  }
  return { label: "Unknown package", detail: "Package not specified", verified: false };
}

export function catalogInventoryUnitPrefill(
  row: Pick<CatalogAdminResult, "packageStatus" | "packageUnit">,
): string {
  return row.packageStatus === "verified" ? (row.packageUnit?.trim() ?? "") : "";
}

export function catalogStockingBlockReason(
  row: Pick<
    CatalogAdminResult,
    "adoptionState" | "inventoryState" | "active" | "discontinued" | "productActive"
  >,
): string | null {
  if (row.adoptionState === "attention" || row.inventoryState === "attention") {
    return "Review the organization links before adding inventory.";
  }
  if (row.adoptionState !== "adopted") {
    return "Add this item to the organization catalog first.";
  }
  if (row.inventoryState === "stocked") return "This item is already in inventory.";
  if (row.inventoryState !== "not_stocked") {
    return "Review the organization links before adding inventory.";
  }
  if (!row.active || row.discontinued || !row.productActive) {
    return "Inactive or discontinued catalog items cannot create new inventory.";
  }
  return null;
}

export function canStockCatalogResult(
  row: Pick<
    CatalogAdminResult,
    "adoptionState" | "inventoryState" | "active" | "discontinued" | "productActive"
  >,
): boolean {
  return catalogStockingBlockReason(row) === null;
}

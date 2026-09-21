export type PriceIntelligenceSummary = {
  latestPrice: number | null;
  latestPriceDate: string | null;
  previousPrice: number | null;
  absoluteChange: number | null;
  percentChange: number | null;
  historicalLow: number | null;
  historicalHigh: number | null;
  observationCount: number;
};

export type PriceObservation = {
  observationId: string;
  purchaseDate: string;
  vendorId: string;
  vendorName: string;
  vendorProductId: string | null;
  vendorSku: string | null;
  purchasePrice: number;
  currencyCode: "USD";
  quantity: number;
  packageDescription: string | null;
  unitOfMeasure: string | null;
  packageEvidenceStatus: "unverified";
  invoiceId: string;
  invoiceItemId: string;
  invoiceNumber: string | null;
  postedAt: string;
  provenanceType: "posted_invoice_purchase_history";
};

export type VendorPriceHistory = {
  vendorId: string;
  vendorName: string;
  latestPrice: number;
  latestPriceDate: string;
  previousPrice: number | null;
  historicalLow: number;
  historicalHigh: number;
  observationCount: number;
};

export type ProductPriceIntelligence = {
  organizationId: string;
  productId: string;
  productName: string;
  currencyCode: "USD";
  summary: PriceIntelligenceSummary;
  recentPurchases: PriceObservation[];
  vendorHistory: VendorPriceHistory[];
  packageComparability: {
    status: "not_verified";
    normalizedUnitEconomicsAvailable: false;
    reason: string;
  };
  coverage: {
    postedObservationCount: number;
    includedUsdObservationCount: number;
    excludedUnknownCurrencyCount: number;
    excludedNonUsdCount: number;
    excludedMissingPriceCount: number;
  };
  historyLimit: number;
  vendorLimit: number;
};

export function formatPrice(amount: number | null): string {
  if (amount === null) return "Unavailable";
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
  }).format(amount);
}

export function formatPriceChange(summary: PriceIntelligenceSummary): string {
  if (summary.absoluteChange === null) return "No comparable prior purchase";
  const absolute = `${summary.absoluteChange >= 0 ? "+" : "−"}${formatPrice(
    Math.abs(summary.absoluteChange),
  )}`;
  if (summary.percentChange === null) return absolute;
  const percent = `${summary.percentChange >= 0 ? "+" : "−"}${Math.abs(
    summary.percentChange,
  ).toFixed(1)}%`;
  return `${absolute} (${percent})`;
}

export function formatPurchaseDate(value: string | null): string {
  if (!value) return "Unavailable";
  const parsed = new Date(`${value}T00:00:00`);
  return Number.isNaN(parsed.getTime())
    ? value
    : parsed.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

// Phase 6B.1 Multi-Vendor Intelligence: response schemas, labels and wording for the
// historical purchase-price reads. Every price here is something the organization actually
// paid on a posted invoice or order confirmation. None of it is a current, market or quoted
// price, and nothing here recommends a vendor or computes savings.
import { z } from "zod";

const uuid = z.string().uuid();
const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const money = z.number();
const count = z.number().int().nonnegative();

export const PRICE_STATES = [
  "insufficient_identity",
  "one_purchase",
  "single_vendor",
  "comparable",
  "missing_package_details",
  "incompatible_units",
] as const;
export type PriceState = (typeof PRICE_STATES)[number];

export const PRICE_SIGNALS = [
  "lower_comparable_price_other_vendor",
  "same_sku_price_increased",
  "price_data_stale",
  "package_details_missing",
  "multiple_vendors_not_comparable",
] as const;
export type PriceSignal = (typeof PRICE_SIGNALS)[number];

export const PRICE_FILTERS = ["all", ...PRICE_STATES, ...PRICE_SIGNALS] as const;
export type PriceFilter = (typeof PRICE_FILTERS)[number];
export type PriceSort = "recent" | "product";

export const stateLabels: Record<PriceState, string> = {
  insufficient_identity: "Insufficient identity",
  one_purchase: "One purchase recorded",
  single_vendor: "Single vendor observed",
  comparable: "Comparable",
  missing_package_details: "Missing package details",
  incompatible_units: "Incompatible units",
};

export const stateDescriptions: Record<PriceState, string> = {
  insufficient_identity:
    "SportSpend can't prove which purchases are the same item, so prices are not compared.",
  one_purchase: "Only one purchase is recorded.",
  single_vendor: "Every purchase came from one vendor.",
  comparable: "At least two vendors' purchases are the same item, unit and package.",
  missing_package_details:
    "Vendors share a unit, but the package can't be proven equal, so prices are not compared.",
  incompatible_units: "Vendors were invoiced in different units, so prices are not compared.",
};

export const signalLabels: Record<PriceSignal, string> = {
  lower_comparable_price_other_vendor: "Lower recent comparable purchase price from another vendor",
  same_sku_price_increased: "Same-SKU price increased",
  price_data_stale: "Price data stale",
  package_details_missing: "Package details missing for comparison",
  multiple_vendors_not_comparable: "Multiple vendors observed but not safely comparable",
};

export const identityIssueLabels: Record<string, string> = {
  multiple_skus: "Several SKUs from one vendor are recorded under this product.",
  missing_sku: "A purchase has no vendor SKU.",
  missing_unit: "A purchase has no unit of measure.",
  malformed_unit: "A purchase's unit of measure can't be read reliably.",
};

export const comparisonStatusLabels: Record<string, string> = {
  last_purchase: "Last purchase",
  comparable: "Comparable",
  comparable_stale: "Comparable · Stale",
  missing_package_details: "Missing package details",
  incompatible_units: "Incompatible units",
  insufficient_identity: "Insufficient identity",
};

export const filterLabels: Record<PriceFilter, string> = {
  all: "All products",
  ...stateLabels,
  lower_comparable_price_other_vendor: "Lower comparable price elsewhere",
  same_sku_price_increased: signalLabels.same_sku_price_increased,
  price_data_stale: signalLabels.price_data_stale,
  package_details_missing: "Package details missing",
  multiple_vendors_not_comparable: "Vendors not comparable",
};

// ---------------------------------------------------------------------------
// Schemas (strict: an unexpected field is a contract change, not something to ignore)
// ---------------------------------------------------------------------------

const documentType = z.string();
const dateBasis = z.enum(["invoice_date", "posting_date"]);
const recency = z.enum(["recent", "aging", "stale"]);

export const evidenceSchema = z
  .object({
    observationId: uuid,
    vendorId: uuid,
    vendorName: z.string(),
    vendorProductId: uuid.nullable(),
    sku: z.string().nullable(),
    documentType,
    documentNumber: z.string().nullable(),
    invoiceNumber: z.string().nullable(),
    dateBasis,
    purchaseDate: date,
    ageDays: count,
    recency,
    quantity: z.number(),
    unitOfMeasure: z.string().nullable(),
    unitValid: z.boolean(),
    packageSize: z.string().nullable(),
    price: money,
    lineAmount: money.nullable(),
    invoiceId: uuid,
    invoiceItemId: uuid,
    lineNumber: z.number().int().nullable(),
  })
  .strict();
export type PriceEvidence = z.infer<typeof evidenceSchema>;

const state = z.enum(PRICE_STATES);
const signals = z.array(z.enum(PRICE_SIGNALS));
const withheld = z.enum(["stale", "last_purchase_not_comparable"]).nullable();

export const listRowSchema = z
  .object({
    productId: uuid,
    productName: z.string(),
    state,
    stale: z.boolean(),
    identityIssue: z.string().nullable(),
    observationCount: count,
    vendorsObserved: count,
    lastPurchase: evidenceSchema,
    priorSameSku: evidenceSchema.nullable(),
    changeAmount: money.nullable(),
    changePercent: z.number().nullable(),
    lowestComparable: evidenceSchema.nullable(),
    comparableAlternative: evidenceSchema.nullable(),
    differencePerUnit: money.nullable(),
    comparableVendorCount: count,
    comparisonWithheld: withheld,
    signals,
  })
  .strict();
export type PriceListRow = z.infer<typeof listRowSchema>;

const recentCursor = z
  .object({ purchaseDate: date, createdAt: z.string(), observationId: uuid })
  .strict();
const productCursor = z.object({ normalizedName: z.string(), productId: uuid }).strict();

export const listSchema = z
  .object({
    organizationId: uuid,
    currencyCode: z.literal("USD"),
    asOf: date,
    sort: z.enum(["recent", "product"]),
    filter: z.enum(PRICE_FILTERS).or(z.literal("stale")),
    vendorId: uuid.nullable(),
    rows: z.array(listRowSchema),
    scanned: count,
    nextCursor: z.union([recentCursor, productCursor]).nullable(),
    exhausted: z.boolean(),
  })
  .strict();
export type PriceList = z.infer<typeof listSchema>;
export type PriceListCursor = PriceList["nextCursor"];

const countsOf = <T extends readonly string[]>(keys: T) =>
  z
    .object(Object.fromEntries(keys.map((k) => [k, count])) as Record<T[number], typeof count>)
    .strict();

export const summarySchema = z
  .object({
    organizationId: uuid,
    currencyCode: z.literal("USD"),
    asOf: date,
    productCount: count,
    observationCount: count,
    vendorCount: count,
    staleCount: count,
    states: countsOf(PRICE_STATES),
    signals: countsOf(PRICE_SIGNALS),
    vendors: z.array(
      z
        .object({ vendorId: uuid, vendorName: z.string(), lastPurchaseProductCount: count })
        .strict(),
    ),
    coverage: z
      .object({
        postedObservationCount: count,
        excludedNonUsdCount: count,
        excludedMissingPriceCount: count,
        orderConfirmationCount: count,
        datedByPostingCount: count,
        missingPackageCount: count,
        missingOrMalformedUnitCount: count,
      })
      .strict(),
  })
  .strict();
export type PriceSummary = z.infer<typeof summarySchema>;

const vendorObservation = z
  .object({
    observationId: uuid,
    sku: z.string().nullable(),
    price: money,
    unitOfMeasure: z.string().nullable(),
    unitValid: z.boolean(),
    packageSize: z.string().nullable(),
    purchaseDate: date,
    dateBasis,
    ageDays: count,
    recency,
    documentType,
    documentNumber: z.string().nullable(),
    invoiceId: uuid,
    lineNumber: z.number().int().nullable(),
  })
  .strict();

const priorReference = z
  .object({
    observationId: uuid,
    price: money,
    purchaseDate: date,
    dateBasis,
    documentType,
    documentNumber: z.string().nullable(),
    invoiceId: uuid,
    lineNumber: z.number().int().nullable(),
  })
  .strict();

const skuIdentity = z
  .object({ sku: z.string().nullable(), observed: z.boolean(), mapped: z.boolean() })
  .strict();

export const vendorRowSchema = z
  .object({
    vendorId: uuid,
    vendorName: z.string(),
    skus: z.array(skuIdentity),
    lastPurchase: vendorObservation,
    priorSameSku: priorReference.nullable(),
    purchaseCount: count,
    firstPurchaseDate: date,
    lastPurchaseDate: date,
    comparisonStatus: z.enum([
      "last_purchase",
      "comparable",
      "comparable_stale",
      "missing_package_details",
      "incompatible_units",
      "insufficient_identity",
    ]),
    checks: z
      .object({
        singleSku: z.boolean(),
        sameUnit: z.boolean(),
        packageAgreement: z.boolean(),
        packageBasis: z.enum(["package_text", "catalog"]).nullable(),
        bothRecent: z.boolean(),
        usdBasis: z.boolean(),
      })
      .strict()
      .nullable(),
  })
  .strict();
export type VendorRow = z.infer<typeof vendorRowSchema>;

export const sourceObservationSchema = z
  .object({
    observationId: uuid,
    vendorId: uuid,
    vendorName: z.string(),
    sku: z.string().nullable(),
    documentType,
    documentNumber: z.string().nullable(),
    dateBasis,
    purchaseDate: date,
    ageDays: count,
    recency,
    quantity: z.number(),
    unitOfMeasure: z.string().nullable(),
    unitValid: z.boolean(),
    packageSize: z.string().nullable(),
    price: money,
    lineAmount: money.nullable(),
    invoiceId: uuid,
    invoiceItemId: uuid,
    lineNumber: z.number().int().nullable(),
  })
  .strict();
export type SourceObservation = z.infer<typeof sourceObservationSchema>;

export const detailSchema = z
  .object({
    organizationId: uuid,
    productId: uuid,
    productName: z.string(),
    currencyCode: z.literal("USD"),
    asOf: date,
    viewerIsOwner: z.boolean(),
    canOpenSourceDocument: z.boolean(),
    state: state.nullable(),
    stale: z.boolean().nullable(),
    identityIssue: z.string().nullable(),
    observationCount: count,
    vendorsObserved: count,
    lastPurchase: evidenceSchema.nullable(),
    priorSameSku: evidenceSchema.nullable(),
    changeAmount: money.nullable(),
    changePercent: z.number().nullable(),
    lowestComparable: evidenceSchema.nullable(),
    comparableAlternative: evidenceSchema.nullable(),
    differencePerUnit: money.nullable(),
    comparableVendorCount: count,
    comparisonWithheld: withheld,
    signals,
    vendors: z.array(vendorRowSchema),
    vendorLimit: count,
    identity: z
      .object({
        issue: z.string().nullable(),
        skus: z.array(
          z
            .object({
              vendorId: uuid,
              vendorName: z.string().nullable(),
              sku: z.string().nullable(),
              observed: z.boolean(),
              mapped: z.boolean(),
            })
            .strict(),
        ),
      })
      .strict()
      .nullable(),
    observations: z.array(sourceObservationSchema),
    nextCursor: recentCursor.nullable(),
    coverage: z
      .object({
        postedObservationCount: count,
        excludedNonUsdCount: count,
        excludedMissingPriceCount: count,
      })
      .strict(),
  })
  .strict();
export type ProductVendorHistory = z.infer<typeof detailSchema>;

const contextPurchase = z
  .object({
    observationId: uuid,
    vendorId: uuid,
    vendorName: z.string(),
    sku: z.string().nullable(),
    price: money,
    unitOfMeasure: z.string().nullable(),
    packageSize: z.string().nullable(),
    purchaseDate: date,
    dateBasis,
    recency,
    documentType,
    documentNumber: z.string().nullable(),
  })
  .strict();

export const requestContextSchema = z
  .object({
    organizationId: uuid,
    requestId: uuid,
    currencyCode: z.literal("USD"),
    asOf: date,
    items: z.array(
      z
        .object({
          itemId: uuid,
          productId: uuid.nullable(),
          status: z.enum(["last_purchase", "several_skus", "no_history", "unresolved"]),
          lastPurchase: contextPurchase.nullable(),
          lowerComparable: contextPurchase.omit({ observationId: true, recency: true }).nullable(),
        })
        .strict(),
    ),
  })
  .strict();
export type RequestPriceContext = z.infer<typeof requestContextSchema>;
export type RequestPriceContextItem = RequestPriceContext["items"][number];

// ---------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------

const usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
export const formatUsd = (amount: number) => usd.format(amount);

export function unitText(unit: string | null | undefined) {
  const trimmed = unit?.trim();
  return trimmed ? trimmed : "unit";
}

/** "$6.23/BX" */
export function pricePerUnit(price: number, unit: string | null | undefined) {
  return `${formatUsd(price)}/${unitText(unit)}`;
}

export function formatDay(value: string) {
  const [y, m, d] = value.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

export function documentTypeLabel(type: string) {
  switch (type) {
    case "INVOICE":
      return "Invoice";
    case "ORDER_CONFIRMATION":
      return "Order confirmation";
    case "UNKNOWN":
      return "Document type not classified";
    default:
      return type
        .toLowerCase()
        .replace(/_/g, " ")
        .replace(/^./, (c) => c.toUpperCase());
  }
}

/** "Order confirmation · Posting date" / "Invoice · Invoice date" */
export function sourceLabel(type: string, basis: "invoice_date" | "posting_date") {
  return `${documentTypeLabel(type)} · ${basis === "posting_date" ? "Posting date" : "Invoice date"}`;
}

/** Age wording: nothing up to 90 days, "Purchased N months ago" for 91–180, "Stale" after. */
export function recencyText(ageDays: number, recency: "recent" | "aging" | "stale") {
  if (recency === "stale") return "Stale";
  if (recency === "aging") {
    const months = Math.floor(ageDays / 30);
    return `Purchased ${months} ${months === 1 ? "month" : "months"} ago`;
  }
  return null;
}

export type ChangeDirection = "increased" | "decreased" | "unchanged";
export function changeDirection(amount: number | null): ChangeDirection | null {
  if (amount === null) return null;
  if (amount > 0) return "increased";
  if (amount < 0) return "decreased";
  return "unchanged";
}

const directionLabels: Record<ChangeDirection, string> = {
  increased: "Price increased",
  decreased: "Price decreased",
  unchanged: "No change",
};

/** "Price increased +$1.00 (+9.1%)", "Price decreased −$5.00 (−20.0%)", "No change" */
export function sameSkuChangeText(amount: number | null, percent: number | null) {
  const direction = changeDirection(amount);
  if (direction === null || amount === null) return null;
  if (direction === "unchanged") return directionLabels.unchanged;
  const sign = amount > 0 ? "+" : "−";
  const money = `${sign}${formatUsd(Math.abs(amount))}`;
  const pct = percent === null ? "" : ` (${sign}${Math.abs(percent).toFixed(1)}%)`;
  return `${directionLabels[direction]} ${money}${pct}`;
}

/** Request review: "Last purchased from Henry Schein at $6.23/BX on Jan 15, 2026" */
export function lastPurchasedText(p: {
  vendorName: string;
  price: number;
  unitOfMeasure: string | null;
  purchaseDate: string;
}) {
  return `Last purchased from ${p.vendorName} at ${pricePerUnit(p.price, p.unitOfMeasure)} on ${formatDay(p.purchaseDate)}`;
}

/** Request review: "Lower comparable purchase price from Vendor B: $9.00/bx on Nov 3, 2026" */
export function lowerComparableText(p: {
  vendorName: string;
  price: number;
  unitOfMeasure: string | null;
  purchaseDate: string;
}) {
  return `Lower comparable purchase price from ${p.vendorName}: ${pricePerUnit(p.price, p.unitOfMeasure)} on ${formatDay(p.purchaseDate)}`;
}

export const SEVERAL_SKUS_TEXT = "Several SKUs recorded — view purchase history";

/** Signed difference per comparable invoiced unit, last purchase minus the cheapest other. */
export function differenceText(amount: number, unit: string | null) {
  if (amount === 0) return `Same price per ${unitText(unit)}`;
  const sign = amount > 0 ? "+" : "−";
  return `${sign}${formatUsd(Math.abs(amount))} per ${unitText(unit)}`;
}

/** Budget & Purchasing deep link to one product's purchase history. */
export function purchaseHistorySearch(productId: string) {
  return { priceProduct: productId };
}

/** Search parameters of the Budget & Purchasing deep link. */
export const priceSearchSchema = z.object({
  priceProduct: uuid.optional().catch(undefined),
  priceInventoryItem: uuid.optional().catch(undefined),
});
export type PriceSearch = z.infer<typeof priceSearchSchema>;

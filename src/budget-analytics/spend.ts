import { z } from "zod";

// Shapes returned by the Phase 7E Spend RPCs
// (supabase/migrations/20261117120000_phase7e_budget_analytics.sql) and the pure wording rules
// the Spend tab uses. Every date is a UTC calendar day (YYYY-MM-DD) chosen by the server; the
// browser never computes day or month boundaries of its own.

const uuid = z.string().uuid();
const money = z.number();
const count = z.number().int().nonnegative();
const day = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const amountCount = z.object({ count, amount: money }).strict();

export const signalCodes = [
  "pace_ahead",
  "budget_over",
  "budget_near_limit",
  "open_commitments_unpriced",
  "received_not_settled",
  "open_commitment_stale",
  "spend_outside_budgets",
  "dated_by_posting",
  "order_confirmations_counted",
  "possible_duplicates",
  "non_usd_excluded",
] as const;
export type SignalCode = (typeof signalCodes)[number];

const signalSchema = z
  .object({
    code: z.enum(signalCodes),
    severity: z.enum(["critical", "warning", "info"]),
    count: count.nullable(),
    amount: money.nullable(),
    gapPoints: z.number().optional(),
    usedPercent: z.number().optional(),
  })
  .strict();

const bucketSchema = z
  .object({
    count,
    pricedAmount: money,
    fullyPriced: count,
    partiallyPriced: count,
    unpriced: count,
  })
  .strict();

export const spendSummarySchema = z
  .object({
    organizationId: uuid,
    asOf: day,
    viewerIsOwner: z.boolean(),
    scope: z
      .object({
        kind: z.enum(["budget", "calendar_year_to_date"]),
        budgetId: uuid.nullable(),
        budgetName: z.string().nullable(),
        budgetActive: z.boolean().nullable(),
        from: day,
        to: day,
        budgetAmount: money.nullable(),
      })
      .strict(),
    budgets: z.array(
      z
        .object({
          budgetId: uuid,
          budgetName: z.string(),
          periodStart: day,
          periodEnd: day,
          budgetAmount: money,
        })
        .strict(),
    ),
    spent: money,
    countedDocumentCount: count,
    remaining: money.nullable(),
    commitments: z
      .object({
        open: bucketSchema.extend({ staleCount: count }).strict(),
        receivedNotSettled: bucketSchema,
        unexpectedCount: count,
      })
      .strict(),
    approxRemainingAfterOpenCommitments: money.nullable(),
    pace: z
      .object({
        state: z.enum(["in_progress", "not_started", "ended", "no_amount"]),
        elapsedPercent: z.number(),
        spentPercent: z.number().nullable(),
        gapPoints: z.number().nullable(),
        band: z.enum(["ahead", "behind", "even"]).nullable(),
      })
      .strict()
      .nullable(),
    burn: z
      .object({
        monthStart: day,
        spentThisMonth: money,
        trailingFrom: day,
        trailing90Days: money,
        completeMonths: count,
        monthsWithSpend: count,
        averagePerCompleteMonth: money.nullable(),
      })
      .strict(),
    coverage: z
      .object({
        countedDocuments: amountCount,
        datedByPosting: amountCount,
        orderConfirmations: amountCount,
        typeUnknown: amountCount,
        typeMissing: amountCount,
        excludedCreditMemos: amountCount,
        excludedStatements: amountCount,
        excludedNonUsd: z.object({ count }).strict(),
        legacyNoCurrency: amountCount,
        componentDifferences: amountCount,
        components: z
          .object({
            linesTotal: money,
            taxTotal: money,
            shippingTotal: money,
            difference: money,
          })
          .strict(),
        linesCategorized: z.object({ categorized: count, total: count }).strict(),
        possibleDuplicates: amountCount,
        removedAfterPosting: amountCount,
        spendOutsideBudgets: amountCount,
      })
      .strict(),
    signals: z.array(signalSchema),
  })
  .strict();

export const spendSeriesSchema = z
  .object({
    from: day,
    to: day,
    total: money,
    cumulative: z.array(
      z.object({ date: day, amount: money, documentCount: count, cumulative: money }).strict(),
    ),
    months: z.array(
      z
        .object({
          month: z.string().regex(/^\d{4}-\d{2}$/),
          monthStart: day,
          amount: money,
          documentCount: count,
        })
        .strict(),
    ),
  })
  .strict();

export const vendorSpendSchema = z
  .object({
    totalSpend: money,
    vendorCount: count,
    rows: z.array(
      z
        .object({
          vendorId: uuid.nullable(),
          vendorName: z.string().nullable(),
          spend: money,
          sharePercent: z.number().nullable(),
          documentCount: count,
          averageDocument: money,
          largestDocument: money,
          firstSpendDate: day,
          lastSpendDate: day,
          orderConfirmationCount: count,
        })
        .strict(),
    ),
  })
  .strict();

const unitGroupSchema = z
  .object({
    unitOfMeasure: z.string().nullable(),
    packageSize: z.string().nullable(),
    quantity: z.number(),
    lineCount: count,
    minUnitPrice: z.number().nullable(),
    maxUnitPrice: z.number().nullable(),
    latestUnitPrice: z.number().nullable(),
  })
  .strict();

export const productSortValues = ["spend", "documents", "recent", "name"] as const;
export type ProductSort = (typeof productSortValues)[number];

export const productSpendSchema = z
  .object({
    sort: z.enum(productSortValues),
    productCount: count,
    reconciliation: z
      .object({
        linesTotal: money,
        taxTotal: money,
        shippingTotal: money,
        difference: money,
        spent: money,
      })
      .strict(),
    rows: z.array(
      z
        .object({
          productId: uuid.nullable(),
          productName: z.string(),
          lineSpend: money,
          sharePercent: z.number().nullable(),
          lineCount: count,
          documentCount: count,
          vendorCount: count,
          lastSpendDate: day,
          unitGroups: z.array(unitGroupSchema),
        })
        .strict(),
    ),
  })
  .strict();

export const commitmentBuckets = ["all", "open", "received_not_settled"] as const;
export type CommitmentBucket = (typeof commitmentBuckets)[number];

export const commitmentListSchema = z
  .object({
    bucket: z.enum(commitmentBuckets),
    totalCount: count,
    pricedAmount: money,
    rows: z.array(
      z
        .object({
          commitmentId: uuid,
          requestId: uuid,
          requestStatus: z.string(),
          bucket: z.enum(["open", "received_not_settled", "unexpected"]),
          committedAt: z.string(),
          commitmentDate: day,
          amount: money.nullable(),
          pricingStatus: z.enum(["fully_priced", "partially_priced", "unpriced"]),
          itemCount: count,
          pricedItemCount: count,
          teamName: z.string().nullable(),
          itemLabel: z.string().nullable(),
        })
        .strict(),
    ),
  })
  .strict();

export const documentFilters = [
  "all",
  "month",
  "vendor",
  "dated_by_posting",
  "order_confirmations",
  "type_unclassified",
  "legacy_currency",
  "component_difference",
  "possible_duplicates",
  "outside_budgets",
  "excluded",
] as const;
export type DocumentFilter = (typeof documentFilters)[number];

export const spendDocumentSchema = z
  .object({
    invoiceId: uuid,
    sourceFileId: uuid.nullable(),
    vendorId: uuid.nullable(),
    vendorName: z.string().nullable(),
    documentType: z.string().nullable(),
    typeStatus: z.enum(["classified", "unknown", "missing"]),
    documentNumber: z.string().nullable(),
    invoiceDate: day.nullable(),
    postedAt: z.string(),
    spendDate: day,
    dateBasis: z.enum(["invoice_date", "posted_at_utc"]),
    amount: money,
    amountBasis: z.enum(["invoice_total", "total_amount", "total", "lines", "zero"]),
    subtotal: money.nullable(),
    taxAmount: money.nullable(),
    shippingAmount: money.nullable(),
    linesTotal: money.nullable(),
    lineCount: count,
    componentDifference: money,
    currencyCode: z.string().nullable(),
    currencyBasis: z.enum(["usd", "legacy_usd", "other"]),
    counted: z.boolean(),
    exclusionReason: z.enum(["credit_memo", "statement", "non_usd"]).nullable(),
  })
  .strict();

export const documentListSchema = z
  .object({
    filter: z.enum(documentFilters),
    value: z.string().nullable(),
    countsTowardSpent: z.boolean(),
    totalCount: count,
    totalAmount: money,
    rows: z.array(spendDocumentSchema),
    nextCursor: z.object({ spendDate: day, invoiceId: uuid }).strict().nullable(),
  })
  .strict();

export const documentDetailSchema = z
  .object({
    document: spendDocumentSchema,
    lines: z.array(
      z
        .object({
          invoiceItemId: uuid,
          lineNumber: z.number().int().nullable(),
          productId: uuid.nullable(),
          productName: z.string().nullable(),
          description: z.string().nullable(),
          sku: z.string().nullable(),
          quantity: z.number(),
          unitOfMeasure: z.string().nullable(),
          packageSize: z.string().nullable(),
          unitPrice: z.number().nullable(),
          totalPrice: z.number().nullable(),
        })
        .strict(),
    ),
    flags: z
      .object({
        orderConfirmation: z.boolean(),
        datedByPosting: z.boolean(),
        typeUnclassified: z.boolean(),
        legacyCurrency: z.boolean(),
        componentDifference: z.boolean(),
        possibleDuplicate: z.boolean(),
        outsideBudgets: z.boolean(),
      })
      .strict(),
  })
  .strict();

export const productLinesSchema = z
  .object({
    productId: uuid.nullable(),
    totalCount: count,
    totalLineSpend: money,
    rows: z.array(
      z
        .object({
          invoiceId: uuid,
          invoiceItemId: uuid,
          spendDate: day,
          vendorId: uuid.nullable(),
          vendorName: z.string().nullable(),
          documentNumber: z.string().nullable(),
          description: z.string().nullable(),
          quantity: z.number(),
          unitOfMeasure: z.string().nullable(),
          packageSize: z.string().nullable(),
          unitPrice: z.number().nullable(),
          totalPrice: z.number().nullable(),
        })
        .strict(),
    ),
    nextCursor: z.object({ spendDate: day, invoiceItemId: uuid }).strict().nullable(),
  })
  .strict();

export const removalListSchema = z
  .object({
    totalCount: count,
    rows: z.array(
      z
        .object({
          removalId: uuid,
          removedAt: z.string(),
          removedByName: z.string().nullable(),
          reason: z.string(),
          vendorName: z.string().nullable(),
          documentType: z.string().nullable(),
          documentNumber: z.string().nullable(),
          spendDate: day.nullable(),
          spendAmount: money,
          countedAsSpend: z.boolean(),
          lineCount: count,
          sourceFileRetained: z.boolean(),
          originalFilename: z.string().nullable(),
        })
        .strict(),
    ),
    nextCursor: z.object({ removedAt: z.string(), id: uuid }).strict().nullable(),
  })
  .strict();

export const removalResultSchema = z
  .object({
    removalId: uuid,
    sourceFileId: uuid,
    documentNumber: z.string().nullable(),
    spendAmount: money,
    countedAsSpend: z.boolean(),
    removedAdjustmentCount: z.number().int().nullable(),
    removedPriceHistoryCount: z.number().int().nullable(),
    sourceFileRetained: z.literal(true),
  })
  .strict();

export type SpendSummary = z.infer<typeof spendSummarySchema>;
export type SpendSignal = SpendSummary["signals"][number];
export type SpendSeries = z.infer<typeof spendSeriesSchema>;
export type VendorSpend = z.infer<typeof vendorSpendSchema>;
export type ProductSpend = z.infer<typeof productSpendSchema>;
export type CommitmentList = z.infer<typeof commitmentListSchema>;
export type DocumentList = z.infer<typeof documentListSchema>;
export type SpendDocument = z.infer<typeof spendDocumentSchema>;
export type DocumentDetail = z.infer<typeof documentDetailSchema>;
export type RemovalList = z.infer<typeof removalListSchema>;
export type ProductLines = z.infer<typeof productLinesSchema>;
export type RemovalResult = z.infer<typeof removalResultSchema>;

// ---------------------------------------------------------------------------
// UTC calendar
// ---------------------------------------------------------------------------

/** Today as a UTC calendar day. Financial dates in 7E are UTC days everywhere. */
export function utcToday(now: Date = new Date()): string {
  return now.toISOString().slice(0, 10);
}

export function formatUtcDay(value: string) {
  const parsed = new Date(`${value.slice(0, 10)}T00:00:00Z`);
  return Number.isNaN(parsed.getTime())
    ? value
    : new Intl.DateTimeFormat("en-US", {
        month: "short",
        day: "numeric",
        year: "numeric",
        timeZone: "UTC",
      }).format(parsed);
}

export function formatMonthLabel(month: string) {
  const parsed = new Date(`${month.slice(0, 7)}-01T00:00:00Z`);
  return Number.isNaN(parsed.getTime())
    ? month
    : new Intl.DateTimeFormat("en-US", { month: "short", year: "2-digit", timeZone: "UTC" }).format(
        parsed,
      );
}

// ---------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------

export const SCOPE_STATEMENT = "Organization-wide · spend attributed by invoice date";

export const formatUsd = (amount: number) =>
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(amount || 0);

const plural = (n: number, one: string, many: string) =>
  `${n.toLocaleString("en-US")} ${n === 1 ? one : many}`;

export const PACE_BAND_POINTS = 5;
export const PACE_SIGNAL_POINTS = 10;

/** Neutral pace wording. Even pace is a reference, never a target. */
export function paceLabel(pace: SpendSummary["pace"]): string | null {
  if (!pace) return null;
  if (pace.state === "not_started") return "This budget period has not started";
  if (pace.state === "ended")
    return pace.spentPercent === null
      ? "This budget period has ended"
      : `Period ended · ${pace.spentPercent.toFixed(1)}% of budget spent`;
  if (pace.state === "no_amount" || pace.gapPoints === null)
    return "No budget amount to pace against";
  const points = Math.abs(pace.gapPoints);
  if (points <= PACE_BAND_POINTS) return "About even with an even pace";
  return `${pace.gapPoints > 0 ? "Ahead of" : "Behind"} an even pace by ${points.toFixed(1)} pts`;
}

export const PACE_REFERENCE_NOTE =
  "Even pace spreads the budget evenly across the period. It is a reference, not a target: preseason and capital purchases are front-loaded.";

/** The approximate secondary figure, always with its coverage. Null when it does not apply. */
export function approxRemainingLabel(summary: SpendSummary): string | null {
  const open = summary.commitments.open;
  if (summary.approxRemainingAfterOpenCommitments === null || open.count === 0) return null;
  const parts = [
    `≈ ${formatUsd(summary.approxRemainingAfterOpenCommitments)} after priced open commitments`,
    `${open.fullyPriced} of ${plural(open.count, "open commitment", "open commitments")} fully priced`,
  ];
  if (open.partiallyPriced > 0) parts.push(`${open.partiallyPriced} partly priced`);
  if (open.partiallyPriced + open.unpriced > 0) parts.push("unpriced items not included");
  return parts.join(" · ");
}

export function commitmentCoverageLabel(bucket: {
  count: number;
  fullyPriced: number;
  partiallyPriced: number;
  unpriced: number;
}): string {
  if (bucket.count === 0) return "None";
  const parts = [`${bucket.fullyPriced} of ${bucket.count} fully priced`];
  if (bucket.partiallyPriced > 0) parts.push(`${bucket.partiallyPriced} partly priced`);
  if (bucket.unpriced > 0) parts.push(`${bucket.unpriced} unpriced`);
  return parts.join(" · ");
}

const signalText: Record<SignalCode, (s: SpendSignal) => string> = {
  pace_ahead: (s) =>
    `Spending is ${Math.abs(s.gapPoints ?? 0).toFixed(1)} pts ahead of an even pace (more than ${PACE_SIGNAL_POINTS} pts)`,
  budget_over: (s) => `Posted spend is over this budget by ${formatUsd(s.amount ?? 0)}`,
  budget_near_limit: (s) =>
    `${(s.usedPercent ?? 90).toFixed(1)}% of this budget is spent · ${formatUsd(s.amount ?? 0)} remaining`,
  open_commitments_unpriced: (s) =>
    `${plural(s.count ?? 0, "open commitment has", "open commitments have")} unpriced items; their exposure is not fully known`,
  received_not_settled: (s) =>
    `${plural(s.count ?? 0, "received request still holds", "received requests still hold")} an active commitment (may already be in Spent)`,
  open_commitment_stale: (s) =>
    `${plural(s.count ?? 0, "open commitment is", "open commitments are")} more than 30 days old`,
  spend_outside_budgets: (s) =>
    `${plural(s.count ?? 0, "posted document falls", "posted documents fall")} outside every active budget period (${formatUsd(s.amount ?? 0)})`,
  dated_by_posting: (s) =>
    `${plural(s.count ?? 0, "document has", "documents have")} no invoice date and ${s.count === 1 ? "is" : "are"} dated by the UTC posting day`,
  order_confirmations_counted: (s) =>
    `${plural(s.count ?? 0, "order confirmation is", "order confirmations are")} counted as spend and may overlap a later invoice`,
  possible_duplicates: (s) =>
    `${plural(s.count ?? 0, "document looks", "documents look")} like possible duplicates (same vendor and number, or same amount within 30 days)`,
  non_usd_excluded: (s) =>
    `${plural(s.count ?? 0, "document in another currency is", "documents in other currencies are")} excluded (no conversion)`,
};

export const signalLabel = (signal: SpendSignal) => signalText[signal.code](signal);

/** Owner drill target for a signal; null when it has none. */
export function signalDrill(
  code: SignalCode,
): DocumentFilter | "commitments_open" | "commitments_received" | null {
  switch (code) {
    case "spend_outside_budgets":
      return "outside_budgets";
    case "dated_by_posting":
      return "dated_by_posting";
    case "order_confirmations_counted":
      return "order_confirmations";
    case "possible_duplicates":
      return "possible_duplicates";
    case "non_usd_excluded":
      return "excluded";
    case "open_commitments_unpriced":
    case "open_commitment_stale":
      return "commitments_open";
    case "received_not_settled":
      return "commitments_received";
    default:
      return null;
  }
}

export type CoverageLine = {
  key: string;
  label: string;
  count: number;
  amount: number | null;
  filter: DocumentFilter | null;
  tone: "neutral" | "note";
};

/** "What these numbers include": every disclosure, zeros included, in a fixed order. */
export function coverageLines(summary: SpendSummary): CoverageLine[] {
  const c = summary.coverage;
  return [
    {
      key: "counted",
      label: "Posted documents counted as spend",
      ...c.countedDocuments,
      filter: "all",
      tone: "neutral",
    },
    {
      key: "datedByPosting",
      label: "Dated by the UTC posting day (no invoice date)",
      ...c.datedByPosting,
      filter: "dated_by_posting",
      tone: "note",
    },
    {
      key: "orderConfirmations",
      label: "Order confirmations counted (may overlap a later invoice)",
      ...c.orderConfirmations,
      filter: "order_confirmations",
      tone: "note",
    },
    {
      key: "typeUnknown",
      label: "Document type not classified (UNKNOWN)",
      ...c.typeUnknown,
      filter: "type_unclassified",
      tone: "note",
    },
    {
      key: "typeMissing",
      label: "Document type not classified (missing)",
      ...c.typeMissing,
      filter: "type_unclassified",
      tone: "note",
    },
    {
      key: "legacyNoCurrency",
      label: "No currency recorded (treated as USD)",
      ...c.legacyNoCurrency,
      filter: "legacy_currency",
      tone: "note",
    },
    {
      key: "componentDifferences",
      label: "Header total differs from lines + tax + shipping",
      ...c.componentDifferences,
      filter: "component_difference",
      tone: "note",
    },
    {
      key: "possibleDuplicates",
      label: "Possible duplicates",
      ...c.possibleDuplicates,
      filter: "possible_duplicates",
      tone: "note",
    },
    {
      key: "excludedCreditMemos",
      label: "Credit memos excluded (credits aren't supported yet)",
      ...c.excludedCreditMemos,
      filter: "excluded",
      tone: "neutral",
    },
    {
      key: "excludedStatements",
      label: "Statements excluded (never spend)",
      ...c.excludedStatements,
      filter: "excluded",
      tone: "neutral",
    },
    {
      key: "excludedNonUsd",
      label: "Other currencies excluded (no conversion)",
      count: c.excludedNonUsd.count,
      amount: null,
      filter: "excluded",
      tone: "neutral",
    },
    {
      key: "removedAfterPosting",
      label: "Removed after posting (kept as evidence)",
      ...c.removedAfterPosting,
      filter: null,
      tone: "neutral",
    },
    {
      key: "spendOutsideBudgets",
      label: "Posted spend outside every active budget (any date)",
      ...c.spendOutsideBudgets,
      filter: "outside_budgets",
      tone: "note",
    },
  ];
}

export const COVERAGE_STATEMENTS = [
  "A budget is one organization-wide spending budget for a period. It is not a category, team, location or cost center.",
  "Spend counts posted documents by invoice date. A document without an invoice date is dated by the UTC day it was posted.",
  "Spend includes tax and shipping. Credit memos and statements never count. Documents with no currency recorded are treated as USD; other currencies are excluded, never converted.",
  "Days and months are UTC calendar days, so a document posted near midnight UTC can fall on a different day than your local calendar.",
  "Invoices are not yet linked to requests, so spend can't be shown by team or location, and received commitments aren't settled automatically.",
];

export const documentTypeLabel = (type: string | null) =>
  type === null || type === "" || type === "UNKNOWN"
    ? "Document type not classified"
    : ((
        {
          INVOICE: "Invoice",
          ORDER_CONFIRMATION: "Order confirmation",
          PURCHASE_ORDER: "Purchase order",
          CREDIT_MEMO: "Credit memo",
          STATEMENT: "Statement",
        } as Record<string, string>
      )[type] ?? type);

export function unitGroupLabel(group: {
  unitOfMeasure: string | null;
  packageSize: string | null;
}) {
  return (
    [group.unitOfMeasure?.trim(), group.packageSize?.trim()].filter(Boolean).join(" · ") ||
    "Unit not recorded"
  );
}

/** Cumulative series padded to the period: start at 0 on the first day, flat to `to`. */
export function cumulativeChartPoints(series: SpendSeries, budgetAmount: number | null) {
  const start = Date.parse(`${series.from}T00:00:00Z`);
  const end = Date.parse(`${series.to}T00:00:00Z`);
  const span = Math.max(end - start, 0);
  const evenAt = (date: string) =>
    budgetAmount === null || span === 0
      ? null
      : (budgetAmount * (Date.parse(`${date}T00:00:00Z`) - start + 86_400_000)) /
        (span + 86_400_000);
  const points: Array<{ date: string; cumulative: number; even: number | null }> = [];
  if (!series.cumulative.length || series.cumulative[0].date !== series.from) {
    points.push({ date: series.from, cumulative: 0, even: evenAt(series.from) });
  }
  for (const point of series.cumulative) {
    points.push({ date: point.date, cumulative: point.cumulative, even: evenAt(point.date) });
  }
  const last = points[points.length - 1];
  if (last.date !== series.to) {
    points.push({ date: series.to, cumulative: last.cumulative, even: evenAt(series.to) });
  }
  return points;
}

/** Removal confirmation the server expects: the document number, or REMOVE when it has none. */
export const removalConfirmation = (documentNumber: string | null) =>
  documentNumber?.trim() ? documentNumber.trim() : "REMOVE";

export const REMOVAL_REASON_MIN = 10;
export const REMOVAL_REASON_MAX = 1000;
export function removalInputError(
  input: { confirmation: string; reason: string },
  documentNumber: string | null,
): string | null {
  const reason = input.reason.trim();
  if (reason.length < REMOVAL_REASON_MIN || reason.length > REMOVAL_REASON_MAX)
    return `Give a reason of ${REMOVAL_REASON_MIN} to ${REMOVAL_REASON_MAX} characters.`;
  if (input.confirmation.trim().toLowerCase() !== removalConfirmation(documentNumber).toLowerCase())
    return `Type ${removalConfirmation(documentNumber)} to confirm.`;
  return null;
}

import { z } from 'zod';

// Shapes returned by the read-only command-center RPCs
// (supabase/migrations/20261015120000_budget_purchasing_command_center.sql).
const uuid = z.string().uuid();
const money = z.number();
const count = z.number().int().nonnegative();
const date = z.string();

export const budgetRowSchema = z.object({
  budgetId: uuid,
  budgetName: z.string(),
  periodStart: date,
  periodEnd: date,
  budgetAmount: money,
  actualSpend: money,
  committedSpend: money,
  availableAmount: money,
  postedInvoiceCount: count,
  activeCommitmentCount: count,
  incompleteCommitmentCount: count,
}).strict();

const invoiceReferenceSchema = z.object({
  invoiceId: uuid,
  sourceFileId: uuid.nullable(),
  vendorName: z.string().nullable(),
  invoiceNumber: z.string().nullable(),
  spendDate: date,
  amount: money,
}).strict();

export const overviewSchema = z.object({
  organizationId: uuid,
  viewerIsOwner: z.boolean(),
  budgets: z.array(budgetRowSchema),
  attention: z.object({
    awaitingApprovalCount: count,
    commitmentsToSettleCount: count,
    commitmentsToSettleAmount: money,
    unpricedCommitmentCount: count,
    invoiceReviewCount: count.nullable(),
  }).strict(),
  recentPurchases: z.array(invoiceReferenceSchema).nullable(),
}).strict();

export const lineageSchema = z.object({
  budgetId: uuid,
  commitmentCount: count,
  commitmentTotal: money,
  commitments: z.array(z.object({
    requestId: uuid,
    requestStatus: z.string(),
    committedAt: z.string(),
    amount: money,
    pricingStatus: z.enum(['fully_priced', 'partially_priced', 'unpriced']),
    itemCount: count,
    itemLabel: z.string().nullable(),
  }).strict()),
  postedInvoiceCount: count.nullable(),
  postedTotal: money.nullable(),
  postedInvoices: z.array(invoiceReferenceSchema).nullable(),
  listLimit: count,
}).strict();

const observationReference = {
  price: money,
  purchaseDate: date,
  invoiceId: uuid,
  invoiceNumber: z.string().nullable(),
};

export const priceRowSchema = z.object({
  productId: uuid,
  productName: z.string(),
  comparability: z.enum(['comparable', 'missing_unit_of_measure']),
  current: z.object({
    ...observationReference,
    observationId: uuid,
    vendorId: uuid,
    vendorName: z.string(),
    quantity: z.number(),
    unitOfMeasure: z.string().nullable(),
    packageSize: z.string().nullable(),
  }).strict(),
  previous: z.object(observationReference).strict().nullable(),
  absoluteChange: money.nullable(),
  percentChange: z.number().nullable(),
  recentAverage: z.object({
    average: money,
    observationCount: count,
    windowStart: date,
    windowEnd: date,
  }).strict().nullable(),
  bestAlternative: z.object({
    ...observationReference,
    vendorId: uuid,
    vendorName: z.string(),
    unitOfMeasure: z.string().nullable(),
    packageSize: z.string().nullable(),
    comparableVendorCount: count,
  }).strict().nullable(),
  unitSavings: money.nullable(),
}).strict();

export const priceOverviewSchema = z.object({
  organizationId: uuid,
  currencyCode: z.literal('USD'),
  averageWindowDays: z.literal(90),
  productLimit: count,
  productCount: count,
  rows: z.array(priceRowSchema),
}).strict();

export type BudgetRow = z.infer<typeof budgetRowSchema>;
export type CommandCenterOverview = z.infer<typeof overviewSchema>;
export type BudgetLineage = z.infer<typeof lineageSchema>;
export type InvoiceReference = z.infer<typeof invoiceReferenceSchema>;
export type PriceRow = z.infer<typeof priceRowSchema>;
export type PriceOverview = z.infer<typeof priceOverviewSchema>;

// ---------------------------------------------------------------------------
// Budget scope
// ---------------------------------------------------------------------------

export const COMBINED_SCOPE = 'all-active';
export type BudgetScopeOption = { id: string; label: string; periodStart: string; periodEnd: string };
export type ScopeSummary = {
  id: string;
  label: string;
  periodStart: string;
  periodEnd: string;
  budgetIds: string[];
  budgetAmount: number;
  actualSpend: number;
  committedSpend: number;
  availableAmount: number;
  postedInvoiceCount: number;
  activeCommitmentCount: number;
  incompleteCommitmentCount: number;
};

const overlaps = (a: BudgetRow, b: BudgetRow) => a.periodStart <= b.periodEnd && b.periodStart <= a.periodEnd;

// Spend and commitments are attributed to every budget whose period contains them, so
// overlapping budgets share dollars. Summing them would double-count; a combined scope is
// offered only when no two active budget periods overlap.
export function budgetsOverlap(budgets: BudgetRow[]) {
  return budgets.some((a, i) => budgets.slice(i + 1).some((b) => overlaps(a, b)));
}

const covers = (budget: BudgetRow, day: string) => budget.periodStart <= day && budget.periodEnd >= day;

// Same rule as the Budget page and request budget impact: a period containing today
// (latest start wins), otherwise the latest-starting period.
export function defaultScopeId(budgets: BudgetRow[], today: string): string | null {
  return [...budgets].sort((a, b) =>
    Number(covers(b, today)) - Number(covers(a, today))
    || b.periodStart.localeCompare(a.periodStart)
    || b.periodEnd.localeCompare(a.periodEnd)
    || a.budgetId.localeCompare(b.budgetId))[0]?.budgetId ?? null;
}

export function scopeOptions(budgets: BudgetRow[]): BudgetScopeOption[] {
  const sorted = [...budgets].sort((a, b) => b.periodStart.localeCompare(a.periodStart) || a.budgetId.localeCompare(b.budgetId));
  const options = sorted.map((b) => ({ id: b.budgetId, label: b.budgetName, periodStart: b.periodStart, periodEnd: b.periodEnd }));
  if (budgets.length > 1 && !budgetsOverlap(budgets)) {
    options.push({
      id: COMBINED_SCOPE,
      label: 'All active budgets',
      periodStart: sorted.reduce((min, b) => (b.periodStart < min ? b.periodStart : min), sorted[0].periodStart),
      periodEnd: sorted.reduce((max, b) => (b.periodEnd > max ? b.periodEnd : max), sorted[0].periodEnd),
    });
  }
  return options;
}

export function summarizeScope(budgets: BudgetRow[], scopeId: string | null): ScopeSummary | null {
  if (!scopeId || budgets.length === 0) return null;
  if (scopeId !== COMBINED_SCOPE) {
    const b = budgets.find((row) => row.budgetId === scopeId);
    if (!b) return null;
    return {
      id: b.budgetId, label: b.budgetName, periodStart: b.periodStart, periodEnd: b.periodEnd, budgetIds: [b.budgetId],
      budgetAmount: b.budgetAmount, actualSpend: b.actualSpend, committedSpend: b.committedSpend, availableAmount: b.availableAmount,
      postedInvoiceCount: b.postedInvoiceCount, activeCommitmentCount: b.activeCommitmentCount, incompleteCommitmentCount: b.incompleteCommitmentCount,
    };
  }
  if (budgets.length < 2 || budgetsOverlap(budgets)) return null;
  const option = scopeOptions(budgets).find((o) => o.id === COMBINED_SCOPE)!;
  const sum = (pick: (b: BudgetRow) => number) => budgets.reduce((total, b) => total + pick(b), 0);
  const budgetAmount = sum((b) => b.budgetAmount);
  const actualSpend = sum((b) => b.actualSpend);
  const committedSpend = sum((b) => b.committedSpend);
  return {
    id: COMBINED_SCOPE, label: option.label, periodStart: option.periodStart, periodEnd: option.periodEnd,
    budgetIds: budgets.map((b) => b.budgetId),
    budgetAmount, actualSpend, committedSpend,
    availableAmount: budgetAmount - actualSpend - committedSpend,
    postedInvoiceCount: sum((b) => b.postedInvoiceCount),
    activeCommitmentCount: sum((b) => b.activeCommitmentCount),
    incompleteCommitmentCount: sum((b) => b.incompleteCommitmentCount),
  };
}

// ---------------------------------------------------------------------------
// Utilization and warnings
// ---------------------------------------------------------------------------

export const BUDGET_WARNING_THRESHOLD = 0.9;

type Amounts = { budgetAmount: number; actualSpend: number; committedSpend: number; availableAmount: number };

/** Share of the budget consumed by spend plus commitments; null for a zero budget. */
export function utilizationRatio(row: Amounts): number | null {
  return row.budgetAmount > 0 ? (row.actualSpend + row.committedSpend) / row.budgetAmount : null;
}

/**
 * Bar segment widths (0–100). When spend plus commitments exceed the budget, the bar is
 * scaled to the larger total so the overage stays visible instead of overflowing.
 */
export function utilizationSegments(row: Amounts) {
  const used = row.actualSpend + row.committedSpend;
  const denominator = Math.max(row.budgetAmount, used);
  if (denominator <= 0) return { spent: 0, committed: 0, available: 0 };
  return {
    spent: (Math.max(row.actualSpend, 0) / denominator) * 100,
    committed: (Math.max(row.committedSpend, 0) / denominator) * 100,
    available: (Math.max(row.availableAmount, 0) / denominator) * 100,
  };
}

export type BudgetStatus = 'over' | 'warning' | 'ok';
export function budgetStatus(row: Amounts): BudgetStatus {
  if (row.availableAmount < 0) return 'over';
  const ratio = utilizationRatio(row);
  return ratio !== null && ratio >= BUDGET_WARNING_THRESHOLD ? 'warning' : 'ok';
}

// ---------------------------------------------------------------------------
// Needs attention
// ---------------------------------------------------------------------------

export type AttentionItem = {
  key: 'approvals' | 'invoiceReview' | 'budgetWarning' | 'commitmentsToSettle' | 'unpricedCommitments';
  label: string;
  count: number;
  amount: number | null;
  detail: string;
  href: string;
  search?: Record<string, string>;
};

/**
 * Only workflows that exist today. Amounts appear only when the database knows them
 * exactly (commitment snapshots); pending requests and unreviewed invoices show counts.
 */
export function attentionItems(overview: CommandCenterOverview, today: string): AttentionItem[] {
  const { attention } = overview;
  const flagged = overview.budgets.filter((b) => covers(b, today) && budgetStatus(b) !== 'ok');
  const items: AttentionItem[] = [
    { key: 'approvals', label: 'Awaiting approval', count: attention.awaitingApprovalCount, amount: null,
      detail: 'Submitted or in-review requests', href: '/supply-requests', search: { queue: 'needsReview' } },
  ];
  if (attention.invoiceReviewCount !== null) {
    items.push({ key: 'invoiceReview', label: 'Invoice review', count: attention.invoiceReviewCount, amount: null,
      detail: 'Extracted invoices waiting for review before posting', href: '/invoices' });
  }
  items.push(
    { key: 'budgetWarning', label: 'Budget warning', count: flagged.length, amount: null,
      detail: flagged.length
        ? flagged.map((b) => `${b.budgetName} ${budgetStatus(b) === 'over' ? 'over budget' : `≥ ${Math.round(BUDGET_WARNING_THRESHOLD * 100)}% used`}`).join(' · ')
        : `Current budgets under ${Math.round(BUDGET_WARNING_THRESHOLD * 100)}% used`,
      href: '#budgets' },
    { key: 'commitmentsToSettle', label: 'Commitments to settle', count: attention.commitmentsToSettleCount,
      amount: attention.commitmentsToSettleCount ? attention.commitmentsToSettleAmount : null,
      detail: 'Received or completed requests still holding committed budget; release once invoiced', href: '/supply-requests' },
    { key: 'unpricedCommitments', label: 'Unpriced commitments', count: attention.unpricedCommitmentCount, amount: null,
      detail: 'Active commitments missing some item prices; available budget may be overstated', href: '/supply-requests' },
  );
  return items;
}

// ---------------------------------------------------------------------------
// Price intelligence
// ---------------------------------------------------------------------------

export type PriceFilter = 'all' | 'increases' | 'savings';
export type PriceSort = 'recent' | 'increase' | 'savings' | 'product';

export const isPriceIncrease = (row: PriceRow) => row.absoluteChange !== null && row.absoluteChange > 0;
export const isSavingsOpportunity = (row: PriceRow) => row.unitSavings !== null && row.unitSavings > 0;

export function filterPriceRows(rows: PriceRow[], filter: PriceFilter, vendorId: string | null = null) {
  return rows.filter((row) =>
    (filter === 'all' || (filter === 'increases' ? isPriceIncrease(row) : isSavingsOpportunity(row)))
    && (!vendorId || row.current.vendorId === vendorId));
}

const descNullsLast = (a: number | null, b: number | null) => (a === null ? (b === null ? 0 : 1) : b === null ? -1 : b - a);

export function sortPriceRows(rows: PriceRow[], sort: PriceSort) {
  const byName = (a: PriceRow, b: PriceRow) => a.productName.localeCompare(b.productName) || a.productId.localeCompare(b.productId);
  return [...rows].sort((a, b) => {
    if (sort === 'increase') return descNullsLast(a.percentChange, b.percentChange) || byName(a, b);
    if (sort === 'savings') return descNullsLast(a.unitSavings, b.unitSavings) || byName(a, b);
    if (sort === 'recent') return b.current.purchaseDate.localeCompare(a.current.purchaseDate) || byName(a, b);
    return byName(a, b);
  });
}

export function priceVendors(rows: PriceRow[]) {
  const vendors = new Map<string, string>();
  for (const row of rows) vendors.set(row.current.vendorId, row.current.vendorName);
  return [...vendors].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name));
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

// `|| 0` folds -0 into 0 so an exactly-spent budget never shows -$0.00.
export const formatMoney = (amount: number) => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(amount || 0);
export const formatPercent = (value: number, signed = false) =>
  `${signed && value > 0 ? '+' : value < 0 ? '−' : ''}${Math.abs(value).toFixed(1)}%`;
export const formatSignedMoney = (amount: number) => `${amount > 0 ? '+' : amount < 0 ? '−' : ''}${formatMoney(Math.abs(amount))}`;
export function formatDay(value: string) {
  const parsed = new Date(`${value.slice(0, 10)}T00:00:00Z`);
  return Number.isNaN(parsed.getTime()) ? value
    : new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' }).format(parsed);
}
/** Compact period label: "Jan 1 – Jun 30, 2027", or with both years when they differ. */
export function formatPeriodShort(start: string, end: string) {
  const sameYear = start.slice(0, 4) === end.slice(0, 4);
  const monthDay = (value: string) => new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' }).format(new Date(`${value}T00:00:00Z`));
  return sameYear ? `${monthDay(start)} – ${formatDay(end)}` : `${formatDay(start)} – ${formatDay(end)}`;
}
export function daysAgo(value: string, today: string) {
  const days = Math.round((Date.parse(`${today}T00:00:00Z`) - Date.parse(`${value.slice(0, 10)}T00:00:00Z`)) / 86_400_000);
  if (!Number.isFinite(days)) return value;
  if (days <= 0) return 'today';
  return days === 1 ? '1 day ago' : `${days} days ago`;
}
export const unitLabel = (row: { unitOfMeasure: string | null; packageSize: string | null }) =>
  [row.unitOfMeasure?.trim(), row.packageSize?.trim()].filter(Boolean).join(' · ') || 'Unit not recorded';

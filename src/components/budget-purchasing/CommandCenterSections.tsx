// Presentational sections of the Budget & Purchasing command center. Data loading lives in
// BudgetPurchasingPage; everything here renders from props so it can be server-rendered in
// tests. Keep imports relative and limited to .ts modules.
import { useState, type ReactNode } from "react";
import { AlertTriangle, ArrowDownRight, ArrowUpRight, ChevronRight } from "lucide-react";
import {
  BUDGET_WARNING_THRESHOLD,
  budgetStatus,
  daysAgo,
  filterPriceRows,
  formatDay,
  formatMoney,
  formatPercent,
  formatPeriodShort,
  formatSignedMoney,
  isPriceIncrease,
  isSavingsOpportunity,
  priceVendors,
  requestCountLabel,
  requestReviewLink,
  sortPriceRows,
  unitLabel,
  utilizationRatio,
  utilizationSegments,
  type AttentionItem,
  type BudgetLineage,
  type BudgetRow,
  type CommitmentReference,
  type InvoiceReference,
  type PriceFilter,
  type PriceOverview,
  type PriceRow,
  type PriceSort,
  type ScopeSummary,
} from "../../budget-purchasing/command-center.ts";

export type RenderLink = (props: {
  to: string;
  search?: Record<string, string>;
  className?: string;
  children: ReactNode;
}) => ReactNode;
const defaultLink: RenderLink = ({ to, search, className, children }) => (
  <a href={search ? `${to}?${new URLSearchParams(search)}` : to} className={className}>
    {children}
  </a>
);

const panel =
  "min-w-0 rounded-xl border border-[#dfe5eb] bg-white shadow-[0_5px_20px_rgba(16,42,73,0.04)]";
const th =
  "whitespace-nowrap px-3 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-[#697687]";
const td = "whitespace-nowrap px-3 py-2.5 tabular-nums";
const statusStyle = {
  over: "bg-[#fff0f1] text-[#a83340]",
  warning: "bg-[#fff4e5] text-[#9a5a12]",
  ok: "bg-[#edf6f0] text-[#2f6b45]",
} as const;
const statusLabel = (row: Parameters<typeof budgetStatus>[0]) => {
  const status = budgetStatus(row);
  return status === "over"
    ? "Over budget"
    : status === "warning"
      ? `≥ ${Math.round(BUDGET_WARNING_THRESHOLD * 100)}% used`
      : "On track";
};

export function SectionHeading({
  id,
  title,
  description,
  action,
}: {
  id: string;
  title: string;
  description?: string;
  action?: ReactNode;
}) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-3">
      <div>
        <h2 id={id} className="text-base font-semibold text-[#102a49]">
          {title}
        </h2>
        {description && <p className="mt-0.5 text-xs text-[#697687]">{description}</p>}
      </div>
      {action}
    </div>
  );
}

export function SectionLoading({ label }: { label: string }) {
  return (
    <div role="status" aria-live="polite" className="space-y-2 py-2">
      <span className="sr-only">{label}</span>
      {[0, 1, 2].map((i) => (
        <div
          key={i}
          className="h-4 animate-pulse rounded bg-[#eef1f4]"
          style={{ width: `${90 - i * 20}%` }}
        />
      ))}
      <p className="pt-1 text-xs text-[#697687]">{label}</p>
    </div>
  );
}

export function SectionError({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div
      role="alert"
      className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-[#f3c6cb] bg-[#fff0f1] px-4 py-3 text-sm text-[#a83340]"
    >
      <span className="flex items-center gap-2">
        <AlertTriangle className="size-4" />
        {message}
      </span>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="rounded-md border border-[#e5a9b0] bg-white px-3 py-1.5 text-xs font-semibold"
        >
          Retry
        </button>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Financial summary
// ---------------------------------------------------------------------------

export function NoBudgetState({ action }: { action: ReactNode }) {
  return (
    <section className={`${panel} p-8 text-center`} aria-labelledby="no-budget-title">
      <h2 id="no-budget-title" className="text-lg font-semibold text-[#102a49]">
        No active budget
      </h2>
      <p className="mx-auto mb-5 mt-2 max-w-md text-sm text-[#697687]">
        Create a budget period to track spent, committed and available dollars. Spend and commitment
        figures are not shown until a budget exists.
      </p>
      {action}
    </section>
  );
}

export function FinancialSummary({
  summary,
  today,
  onReviewSettlement,
}: {
  summary: ScopeSummary;
  today: string;
  onReviewSettlement?: () => void;
}) {
  const segments = utilizationSegments(summary);
  const ratio = utilizationRatio(summary);
  const over = summary.availableAmount < 0;
  const coversToday = summary.periodStart <= today && summary.periodEnd >= today;
  const figures: Array<[string, number, string]> = [
    ["Budget", summary.budgetAmount, "Allocated for this period"],
    [
      "Spent",
      summary.actualSpend,
      `${summary.postedInvoiceCount.toLocaleString("en-US")} posted ${summary.postedInvoiceCount === 1 ? "invoice" : "invoices"}`,
    ],
    [
      "Committed",
      summary.committedSpend,
      `Active / unreleased · ${requestCountLabel(summary.activeCommitmentCount)}`,
    ],
    ["Available", summary.availableAmount, "Budget − spent − committed"],
  ];
  return (
    <section className={`${panel} p-5 sm:p-6`} aria-labelledby="financial-summary-title">
      <h2 id="financial-summary-title" className="sr-only">
        Financial summary
      </h2>
      <dl className="grid grid-cols-2 gap-x-4 gap-y-5 sm:gap-x-6 lg:grid-cols-4">
        {figures.map(([label, value, note]) => (
          <div
            key={label}
            className="min-w-0 border-l-2 border-[#e6ebf0] pl-3 first:border-[#102a49] sm:pl-4"
          >
            <dt className="text-xs font-semibold uppercase tracking-wide text-[#697687]">
              {label}
            </dt>
            <dd
              className={`mt-1 whitespace-nowrap text-lg font-semibold tabular-nums tracking-tight min-[400px]:text-xl sm:text-2xl xl:text-[28px] ${label === "Available" && over ? "text-[#a83340]" : "text-[#102a49]"}`}
            >
              {formatMoney(value)}
            </dd>
            <dd className="mt-0.5 text-xs text-[#7a8592]">{note}</dd>
          </div>
        ))}
      </dl>
      <div className="mt-6">
        <div
          className="flex h-3 w-full overflow-hidden rounded-full bg-[#eef1f4]"
          role="img"
          aria-label={`Spent ${formatMoney(summary.actualSpend)}, committed ${formatMoney(summary.committedSpend)}, available ${formatMoney(summary.availableAmount)}`}
        >
          <div className="h-full bg-[#102a49]" style={{ width: `${segments.spent}%` }} />
          <div className="h-full bg-[#e08a2e]" style={{ width: `${segments.committed}%` }} />
          <div className="h-full bg-[#cfe3d6]" style={{ width: `${segments.available}%` }} />
        </div>
        <div className="mt-2 flex flex-wrap items-center gap-x-5 gap-y-1 text-xs text-[#5e6d7e]">
          <Legend color="bg-[#102a49]" label="Spent" value={summary.actualSpend} />
          <Legend color="bg-[#e08a2e]" label="Committed" value={summary.committedSpend} />
          <Legend
            color="bg-[#cfe3d6]"
            label="Available"
            value={Math.max(summary.availableAmount, 0)}
          />
          <span className="ml-auto font-medium text-[#102a49]">
            {ratio === null ? "Zero budget" : `${formatPercent(ratio * 100)} used`}
          </span>
        </div>
      </div>
      {summary.settlementCandidateCount > 0 && (
        <SettlementNotice summary={summary} onReview={onReviewSettlement} />
      )}
      {over && (
        <p role="status" className="mt-4 text-sm text-[#a83340]">
          Spent and committed dollars exceed this budget by {formatMoney(-summary.availableAmount)}.
        </p>
      )}
      {summary.incompleteCommitmentCount > 0 && (
        <p
          role="status"
          className="mt-3 rounded-lg border border-[#f1d9b5] bg-[#fff8ee] px-3 py-2 text-xs text-[#7c4a0e]"
        >
          {summary.incompleteCommitmentCount.toLocaleString("en-US")} active{" "}
          {summary.incompleteCommitmentCount === 1 ? "commitment has" : "commitments have"} unpriced
          items. Committed includes known prices only, so available may be overstated.
        </p>
      )}
      {!coversToday && (
        <p role="status" className="mt-3 text-xs text-[#697687]">
          This scope does not include today. Figures apply only to {formatDay(summary.periodStart)}{" "}
          – {formatDay(summary.periodEnd)}.
        </p>
      )}
    </section>
  );
}

// Operational, not an error: the canonical figures above are unchanged. Whether any of this
// purchase is already in Spent is unknown, because requests are not matched to invoices.
function SettlementNotice({ summary, onReview }: { summary: ScopeSummary; onReview?: () => void }) {
  return (
    <div
      role="status"
      data-notice="settlement"
      className="mt-4 flex flex-wrap items-start justify-between gap-3 rounded-lg border border-[#f1d9b5] bg-[#fff8ee] px-4 py-3 text-[#7c4a0e]"
    >
      <div className="min-w-0 max-w-3xl">
        <p className="text-sm font-semibold">
          {formatMoney(summary.settlementCandidateAmount)} of commitments may need settlement
        </p>
        <p className="mt-0.5 text-xs leading-5">
          {requestCountLabel(summary.settlementCandidateCount)} in Committed{" "}
          {summary.settlementCandidateCount === 1 ? "is" : "are"} already received or completed, but{" "}
          {summary.settlementCandidateCount === 1 ? "its commitment is" : "their commitments are"}{" "}
          still active. Available includes {summary.settlementCandidateCount === 1 ? "it" : "them"},
          so it may be conservative until each is reviewed. Requests are not matched to invoices
          automatically, so this is not confirmed duplicate spend.
        </p>
      </div>
      {onReview && (
        <button
          type="button"
          onClick={onReview}
          className="shrink-0 rounded-md border border-[#e6c48f] bg-white px-3 py-1.5 text-xs font-semibold text-[#7c4a0e] hover:bg-[#fffaf2]"
        >
          Review commitments to settle
        </button>
      )}
    </div>
  );
}

function Legend({ color, label, value }: { color: string; label: string; value: number }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span className={`size-2.5 rounded-sm ${color}`} />
      {label} <span className="tabular-nums text-[#102a49]">{formatMoney(value)}</span>
    </span>
  );
}

// ---------------------------------------------------------------------------
// Needs attention
// ---------------------------------------------------------------------------

export function NeedsAttention({
  items,
  renderLink = defaultLink,
  invoiceDetailHidden,
  actions = {},
}: {
  items: AttentionItem[];
  renderLink?: RenderLink;
  invoiceDetailHidden?: boolean;
  /** In-page handlers that replace an item's link (e.g. opening the settlement list). */
  actions?: Partial<Record<AttentionItem["key"], () => void>>;
}) {
  return (
    <section className={`${panel} p-5`} aria-labelledby="needs-attention-title">
      <SectionHeading
        id="needs-attention-title"
        title="Needs Attention"
        description="Open work in existing workflows"
      />
      <ul className="mt-4 divide-y divide-[#edf0f3]">
        {items.map((item) => {
          const className = `group flex w-full items-center gap-3 rounded-md px-2 py-3 text-left -mx-2 ${item.prominent ? "my-1 border border-[#f1d9b5] bg-[#fff8ee] hover:bg-[#fff3e2]" : "hover:bg-[#fafbfc]"}`;
          const body = (
            <>
              <span
                className={`flex size-8 shrink-0 items-center justify-center rounded-md text-sm font-semibold tabular-nums ${item.count ? "bg-[#fff0e5] text-[#a14e17]" : "bg-[#edf1f5] text-[#7a8592]"}`}
              >
                {item.count}
              </span>
              <span className="min-w-0 flex-1">
                <span
                  className={`block text-sm font-medium ${item.count ? "text-[#102a49]" : "text-[#7a8592]"}`}
                >
                  {item.label}
                </span>
                {item.amount !== null && (
                  <span className="block text-xs font-medium tabular-nums text-[#334155]">
                    {requestCountLabel(item.count)} · {formatMoney(item.amount)}
                  </span>
                )}
                <span
                  className={`block text-xs text-[#7a8592] ${item.prominent ? "" : "truncate"}`}
                >
                  {item.detail}
                </span>
              </span>
              <ChevronRight className="size-4 shrink-0 text-[#b0b9c3] group-hover:text-[#102a49]" />
            </>
          );
          const action = actions[item.key];
          return (
            <li
              key={item.key}
              data-attention={item.key}
              data-prominent={item.prominent ? "true" : undefined}
            >
              {action ? (
                <button type="button" onClick={action} className={className}>
                  {body}
                </button>
              ) : (
                renderLink({ to: item.href, search: item.search, className, children: body })
              )}
            </li>
          );
        })}
      </ul>
      {invoiceDetailHidden && (
        <p className="mt-2 text-xs text-[#7a8592]">
          Invoice review is available to organization owners.
        </p>
      )}
    </section>
  );
}

// ---------------------------------------------------------------------------
// Budgets
// ---------------------------------------------------------------------------

export function BudgetTable({
  budgets,
  scopeBudgetIds,
  onSelect,
}: {
  budgets: BudgetRow[];
  scopeBudgetIds: string[];
  onSelect?: (budgetId: string) => void;
}) {
  return (
    <section id="budgets" className={`${panel} p-5`} aria-labelledby="budgets-title">
      <SectionHeading
        id="budgets-title"
        title="Budgets"
        description="Every active budget period. Spend and commitments are attributed by date."
      />
      <div className="mt-3 -mx-5 overflow-x-auto">
        <table className="w-full min-w-[700px] text-sm">
          <thead className="border-y border-[#edf0f3] bg-[#fafbfc]">
            <tr>
              <th className={`${th} pl-5`}>Budget</th>
              <th className={`${th} text-right`}>Allocated</th>
              <th className={`${th} text-right`}>Spent</th>
              <th className={`${th} text-right`}>Committed</th>
              <th className={`${th} text-right`}>Available</th>
              <th className={th}>Utilized</th>
              <th className={`${th} pr-5`}>Status</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-[#edf0f3]">
            {budgets.map((budget) => {
              const ratio = utilizationRatio(budget);
              const status = budgetStatus(budget);
              const inScope = scopeBudgetIds.includes(budget.budgetId);
              return (
                <tr
                  key={budget.budgetId}
                  data-budget-id={budget.budgetId}
                  className={inScope ? "bg-[#f6f9fc]" : undefined}
                >
                  <td className="px-3 py-2.5 pl-5">
                    {onSelect ? (
                      <button
                        type="button"
                        onClick={() => onSelect(budget.budgetId)}
                        className="text-left font-medium text-[#102a49] underline-offset-2 hover:underline"
                      >
                        {budget.budgetName}
                      </button>
                    ) : (
                      <span className="font-medium text-[#102a49]">{budget.budgetName}</span>
                    )}
                    <span className="block whitespace-nowrap text-xs text-[#7a8592]">
                      {formatPeriodShort(budget.periodStart, budget.periodEnd)}
                      {inScope ? " · in view" : ""}
                    </span>
                  </td>
                  <td className={`${td} text-right`}>{formatMoney(budget.budgetAmount)}</td>
                  <td className={`${td} text-right`}>{formatMoney(budget.actualSpend)}</td>
                  <td className={`${td} text-right`}>
                    {formatMoney(budget.committedSpend)}
                    {budget.incompleteCommitmentCount > 0 && (
                      <span
                        className="ml-1 text-[#9a5a12]"
                        title="Some committed items are unpriced"
                      >
                        *
                      </span>
                    )}
                  </td>
                  <td
                    className={`${td} text-right font-medium ${budget.availableAmount < 0 ? "text-[#a83340]" : "text-[#102a49]"}`}
                  >
                    {formatMoney(budget.availableAmount)}
                  </td>
                  <td className={td}>
                    {ratio === null ? (
                      <span className="text-xs text-[#7a8592]">—</span>
                    ) : (
                      <span className="flex items-center gap-2">
                        <span className="h-1.5 w-16 overflow-hidden rounded-full bg-[#eef1f4]">
                          <span
                            className={`block h-full ${status === "over" ? "bg-[#a83340]" : status === "warning" ? "bg-[#e08a2e]" : "bg-[#102a49]"}`}
                            style={{ width: `${Math.min(ratio, 1) * 100}%` }}
                          />
                        </span>
                        {formatPercent(ratio * 100)}
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-2.5 pr-5">
                    <span
                      className={`whitespace-nowrap rounded px-1.5 py-0.5 text-xs font-medium ${statusStyle[status]}`}
                    >
                      {statusLabel(budget)}
                    </span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {budgets.some((b) => b.incompleteCommitmentCount > 0) && (
        <p className="mt-2 text-xs text-[#7a8592]">
          * Includes commitments with unpriced items; only known prices are counted.
        </p>
      )}
    </section>
  );
}

export function BudgetLineagePanel({
  budget,
  lineage,
  renderLink = defaultLink,
}: {
  budget: BudgetRow;
  lineage: BudgetLineage;
  renderLink?: RenderLink;
}) {
  return (
    <div className="space-y-6 text-sm">
      <dl className="grid grid-cols-2 gap-3">
        {(
          [
            ["Allocated", budget.budgetAmount],
            ["Spent", budget.actualSpend],
            ["Committed", budget.committedSpend],
            ["Available", budget.availableAmount],
          ] as const
        ).map(([label, value]) => (
          <div key={label} className="rounded-lg border border-[#e2e7ec] p-3">
            <dt className="text-xs text-[#697687]">{label}</dt>
            <dd className="mt-1 font-semibold tabular-nums text-[#102a49]">{formatMoney(value)}</dd>
          </div>
        ))}
      </dl>
      <section aria-labelledby="lineage-commitments">
        <h3
          id="lineage-commitments"
          className="text-xs font-semibold uppercase tracking-wide text-[#697687]"
        >
          Committed · {lineage.commitmentCount} active{" "}
          {lineage.commitmentCount === 1 ? "commitment" : "commitments"} ·{" "}
          {formatMoney(lineage.commitmentTotal)}
        </h3>
        {lineage.settlementCandidateCount > 0 && (
          <p className="mt-1 text-xs text-[#7c4a0e]">
            Includes {requestCountLabel(lineage.settlementCandidateCount)} (
            {formatMoney(lineage.settlementCandidateTotal)}) already received or completed:
            potential settlement candidates.
          </p>
        )}
        {lineage.commitments.length === 0 ? (
          <p className="mt-2 text-xs text-[#7a8592]">
            No active commitments were approved in this period.
          </p>
        ) : (
          <ul className="mt-2 divide-y divide-[#edf0f3] rounded-lg border border-[#e2e7ec]">
            {lineage.commitments.map((c) => (
              <CommitmentItem
                key={c.requestId}
                commitment={c}
                candidate={c.settlementCandidate}
                renderLink={renderLink}
              />
            ))}
          </ul>
        )}
        {lineage.commitmentCount > lineage.commitments.length && (
          <p className="mt-1 text-xs text-[#7a8592]">
            Showing the {lineage.commitments.length} most recent of {lineage.commitmentCount}.
          </p>
        )}
        <div className="mt-2">
          {renderLink({
            to: "/supply-requests",
            className: "text-xs font-medium text-[#102a49] underline underline-offset-2",
            children: "Open Supply Requests",
          })}
        </div>
      </section>
      <section aria-labelledby="lineage-spend">
        {lineage.postedInvoices === null ? (
          <>
            <h3
              id="lineage-spend"
              className="text-xs font-semibold uppercase tracking-wide text-[#697687]"
            >
              Spent · {budget.postedInvoiceCount} posted{" "}
              {budget.postedInvoiceCount === 1 ? "invoice" : "invoices"}
            </h3>
            <p className="mt-2 text-xs text-[#7a8592]">
              Invoice-level detail is available to organization owners.
            </p>
          </>
        ) : (
          <>
            <h3
              id="lineage-spend"
              className="text-xs font-semibold uppercase tracking-wide text-[#697687]"
            >
              Spent · {lineage.postedInvoiceCount} posted{" "}
              {lineage.postedInvoiceCount === 1 ? "invoice" : "invoices"} ·{" "}
              {formatMoney(lineage.postedTotal ?? 0)}
            </h3>
            <InvoiceList
              invoices={lineage.postedInvoices}
              renderLink={renderLink}
              empty="No posted invoices are dated in this period."
            />
            {(lineage.postedInvoiceCount ?? 0) > lineage.postedInvoices.length && (
              <p className="mt-1 text-xs text-[#7a8592]">
                Showing the {lineage.postedInvoices.length} most recent of{" "}
                {lineage.postedInvoiceCount}.
              </p>
            )}
          </>
        )}
      </section>
      <p className="text-xs text-[#7a8592]">
        Spent counts posted invoices dated in the period. Committed counts every approved request
        whose commitment has not been released, whatever its status. An active commitment stays in
        Committed until an admin releases it from the request. A potential settlement candidate is
        one whose request is already received or completed; its purchase may or may not be in Spent
        yet, because requests are not matched to invoices automatically.
      </p>
    </div>
  );
}

function CommitmentItem({
  commitment: c,
  candidate,
  renderLink,
}: {
  commitment: CommitmentReference;
  candidate: boolean;
  renderLink: RenderLink;
}) {
  const link = requestReviewLink(c);
  return (
    <li
      data-settlement-candidate={candidate ? "true" : "false"}
      className="flex items-center justify-between gap-3 px-3 py-2"
    >
      <span className="min-w-0">
        <span className="block truncate font-medium text-[#102a49]">
          {c.itemLabel ?? "Supply request"}
          {c.itemCount > 1 ? ` + ${c.itemCount - 1} more` : ""}
        </span>
        <span className="block text-xs text-[#7a8592]">
          Approved {formatDay(c.committedAt)} · request {c.requestStatus.replace("_", " ")}
          {c.pricingStatus !== "fully_priced" ? " · has unpriced items" : ""}
        </span>
        <span className="mt-1 flex flex-wrap items-center gap-2">
          <span
            className={`rounded px-1.5 py-0.5 text-[11px] font-medium ${candidate ? "bg-[#fff4e5] text-[#9a5a12]" : "bg-[#edf1f5] text-[#536174]"}`}
          >
            {candidate ? "Potential settlement candidate" : "Active commitment"}
          </span>
          {renderLink({
            to: link.to,
            search: link.search,
            className: "text-[11px] font-medium text-[#102a49] underline underline-offset-2",
            children: candidate ? "Review & release in Request Inbox" : "Open request",
          })}
        </span>
      </span>
      <span className="shrink-0 font-medium tabular-nums">{formatMoney(c.amount)}</span>
    </li>
  );
}

export function SettlementCandidatesPanel({
  candidates,
  count,
  amount,
  limit,
  renderLink = defaultLink,
}: {
  candidates: CommitmentReference[];
  count: number;
  amount: number;
  limit: number;
  renderLink?: RenderLink;
}) {
  return (
    <div className="space-y-4 text-sm" data-section="settlement-candidates">
      <p className="text-[#334155]">
        <span className="font-semibold tabular-nums">
          {requestCountLabel(count)} · {formatMoney(amount)}
        </span>{" "}
        across all budget periods.
      </p>
      <p className="text-xs leading-5 text-[#697687]">
        These requests are received or completed, but their commitments are still active, so their
        amounts remain in Committed and reduce Available. SportSpend does not match requests to
        invoices, so check each one: if you confirm its purchase is now in posted spend, release the
        commitment as settled from the request; otherwise leave it active. Nothing is released from
        this page.
      </p>
      {candidates.length === 0 ? (
        <p className="text-xs text-[#7a8592]">No commitments need settlement.</p>
      ) : (
        <ul className="divide-y divide-[#edf0f3] rounded-lg border border-[#e2e7ec]">
          {candidates.map((c) => (
            <CommitmentItem key={c.requestId} commitment={c} candidate renderLink={renderLink} />
          ))}
        </ul>
      )}
      {count > candidates.length && (
        <p className="text-xs text-[#7a8592]">
          Showing the {candidates.length} oldest of {count} (limit {limit}). Release these to see
          the rest.
        </p>
      )}
    </div>
  );
}

function InvoiceList({
  invoices,
  renderLink,
  empty,
}: {
  invoices: InvoiceReference[];
  renderLink: RenderLink;
  empty: string;
}) {
  if (invoices.length === 0) return <p className="mt-2 text-xs text-[#7a8592]">{empty}</p>;
  return (
    <ul className="mt-2 divide-y divide-[#edf0f3] rounded-lg border border-[#e2e7ec]">
      {invoices.map((invoice) => {
        const label = (
          <>
            <span className="block truncate font-medium text-[#102a49]">
              {invoice.vendorName ?? "Unknown vendor"}
            </span>
            <span className="block text-xs text-[#7a8592]">
              {invoice.invoiceNumber ? `#${invoice.invoiceNumber}` : "No invoice number"} ·{" "}
              {formatDay(invoice.spendDate)}
            </span>
          </>
        );
        return (
          <li key={invoice.invoiceId} className="flex items-center justify-between gap-3 px-3 py-2">
            <span className="min-w-0">
              {invoice.sourceFileId
                ? renderLink({
                    to: `/invoices/${invoice.sourceFileId}`,
                    className: "block hover:underline",
                    children: label,
                  })
                : label}
            </span>
            <span className="shrink-0 font-medium tabular-nums">{formatMoney(invoice.amount)}</span>
          </li>
        );
      })}
    </ul>
  );
}

// ---------------------------------------------------------------------------
// Price intelligence
// ---------------------------------------------------------------------------

const filterLabels: Record<PriceFilter, string> = {
  all: "All items",
  increases: "Price increases",
  savings: "Savings opportunities",
};
const sortLabels: Record<PriceSort, string> = {
  recent: "Most recent purchase",
  increase: "Largest price increase",
  savings: "Largest unit savings",
  product: "Product name",
};

export function PriceIntelligenceTable({
  overview,
  today,
  selectedProductId,
  onSelect,
  initialFilter = "all",
  initialSort = "recent",
}: {
  overview: PriceOverview;
  today: string;
  selectedProductId?: string | null;
  onSelect?: (row: PriceRow) => void;
  initialFilter?: PriceFilter;
  initialSort?: PriceSort;
}) {
  const [filter, setFilter] = useState<PriceFilter>(initialFilter);
  const [sort, setSort] = useState<PriceSort>(initialSort);
  const [vendorId, setVendorId] = useState<string>("");
  const vendors = priceVendors(overview.rows);
  const rows = sortPriceRows(filterPriceRows(overview.rows, filter, vendorId || null), sort);
  const counts: Record<PriceFilter, number> = {
    all: overview.rows.length,
    increases: overview.rows.filter(isPriceIncrease).length,
    savings: overview.rows.filter(isSavingsOpportunity).length,
  };
  return (
    <section
      className={`${panel} p-5`}
      aria-labelledby="price-intelligence-title"
      data-section="price-intelligence-table"
    >
      <SectionHeading
        id="price-intelligence-title"
        title="Price Intelligence"
        description="Current pricing compared with your own posted purchase history and other vendors you have bought the same item from."
      />
      <div className="mt-4 flex flex-wrap items-center gap-2">
        <div
          role="group"
          aria-label="Price filter"
          className="inline-flex rounded-lg border border-[#dfe5eb] p-0.5"
        >
          {(Object.keys(filterLabels) as PriceFilter[]).map((key) => (
            <button
              key={key}
              type="button"
              aria-pressed={filter === key}
              onClick={() => setFilter(key)}
              className={`rounded-md px-3 py-1.5 text-xs font-medium ${filter === key ? "bg-[#102a49] text-white" : "text-[#536174] hover:bg-[#f1f4f7]"}`}
            >
              {filterLabels[key]} <span className="tabular-nums opacity-75">{counts[key]}</span>
            </button>
          ))}
        </div>
        {vendors.length > 1 && (
          <label className="flex items-center gap-1.5 text-xs text-[#536174]">
            Vendor
            <select
              value={vendorId}
              onChange={(e) => setVendorId(e.target.value)}
              className="rounded-md border border-[#dfe5eb] bg-white px-2 py-1.5 text-xs"
            >
              <option value="">All vendors</option>
              {vendors.map((v) => (
                <option key={v.id} value={v.id}>
                  {v.name}
                </option>
              ))}
            </select>
          </label>
        )}
        <label className="ml-auto flex items-center gap-1.5 text-xs text-[#536174]">
          Sort
          <select
            value={sort}
            onChange={(e) => setSort(e.target.value as PriceSort)}
            className="rounded-md border border-[#dfe5eb] bg-white px-2 py-1.5 text-xs"
          >
            {(Object.keys(sortLabels) as PriceSort[]).map((key) => (
              <option key={key} value={key}>
                {sortLabels[key]}
              </option>
            ))}
          </select>
        </label>
      </div>
      {overview.rows.length === 0 ? (
        <div className="mt-4 rounded-lg border border-dashed border-[#d5dce3] p-6 text-center">
          <p className="text-sm font-medium text-[#102a49]">No posted purchase prices yet</p>
          <p className="mt-1 text-xs text-[#7a8592]">
            Prices appear after invoices with matched products are posted.
          </p>
        </div>
      ) : rows.length === 0 ? (
        <p className="mt-4 rounded-lg border border-dashed border-[#d5dce3] p-6 text-center text-sm text-[#697687]">
          No items match {filterLabels[filter].toLowerCase()}
          {vendorId ? " for this vendor" : ""}.
        </p>
      ) : (
        <div className="mt-3 -mx-5 overflow-x-auto">
          <table className="w-full min-w-[1080px] text-sm">
            <thead className="border-y border-[#edf0f3] bg-[#fafbfc]">
              <tr>
                <th className={`${th} pl-5`}>Product</th>
                <th className={th}>Vendor</th>
                <th className={`${th} text-right`}>Current</th>
                <th className={`${th} text-right`}>Previous</th>
                <th className={`${th} text-right`}>Change</th>
                <th className={`${th} text-right`}>{overview.averageWindowDays}-day avg</th>
                <th className={th}>Best known option</th>
                <th className={`${th} text-right`}>Unit savings</th>
                <th className={`${th} pr-5`}>Last purchased</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#edf0f3]">
              {rows.map((row) => (
                <PriceTableRow
                  key={row.productId}
                  row={row}
                  today={today}
                  selected={row.productId === selectedProductId}
                  onSelect={onSelect}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="mt-3 text-xs text-[#7a8592]">
        Prices are unit prices from posted USD invoices only (never catalog list prices). Prices are
        compared only for the same product and unit of measure; another vendor is shown only when
        the same package size was recorded.
        {overview.productCount > overview.rows.length &&
          ` Showing the ${overview.rows.length} most recently purchased of ${overview.productCount} products.`}
      </p>
    </section>
  );
}

function PriceTableRow({
  row,
  today,
  selected,
  onSelect,
}: {
  row: PriceRow;
  today: string;
  selected: boolean;
  onSelect?: (row: PriceRow) => void;
}) {
  const unit = row.current.unitOfMeasure?.trim() || "unit";
  return (
    <tr
      data-product-id={row.productId}
      aria-selected={selected}
      className={selected ? "bg-[#f1f6fb]" : "hover:bg-[#fafbfc]"}
    >
      <td className="max-w-[240px] px-3 py-2.5 pl-5">
        {onSelect ? (
          <button
            type="button"
            onClick={() => onSelect(row)}
            className="block max-w-full truncate text-left font-medium text-[#102a49] underline-offset-2 hover:underline"
          >
            {row.productName}
          </button>
        ) : (
          <span className="block truncate font-medium text-[#102a49]">{row.productName}</span>
        )}
        <span className="block truncate text-xs text-[#7a8592]">{unitLabel(row.current)}</span>
      </td>
      <td className="max-w-[160px] truncate px-3 py-2.5 text-[#334155]">
        {row.current.vendorName}
      </td>
      <td className={`${td} text-right font-medium text-[#102a49]`}>
        {formatMoney(row.current.price)}
      </td>
      <td className={`${td} text-right text-[#536174]`}>
        {row.previous ? (
          formatMoney(row.previous.price)
        ) : (
          <span className="text-xs text-[#9aa4ae]">
            {row.comparability === "missing_unit_of_measure" ? "Unit unknown" : "—"}
          </span>
        )}
      </td>
      <td className={`${td} text-right`}>
        {row.percentChange !== null ? (
          <ChangeBadge percent={row.percentChange} />
        ) : row.absoluteChange !== null ? (
          formatSignedMoney(row.absoluteChange)
        ) : (
          <span className="text-[#9aa4ae]">—</span>
        )}
      </td>
      <td className={`${td} text-right text-[#536174]`}>
        {row.recentAverage ? (
          <span
            title={`${row.recentAverage.observationCount} purchases, ${formatDay(row.recentAverage.windowStart)} – ${formatDay(row.recentAverage.windowEnd)}`}
          >
            {formatMoney(row.recentAverage.average)}
          </span>
        ) : (
          <span className="text-[#9aa4ae]">—</span>
        )}
      </td>
      <td className="max-w-[200px] px-3 py-2.5">
        {row.bestAlternative ? (
          <>
            <span className="block tabular-nums text-[#334155]">
              {formatMoney(row.bestAlternative.price)}
            </span>
            <span className="block truncate text-xs text-[#7a8592]">
              {row.bestAlternative.vendorName}
            </span>
          </>
        ) : (
          <span className="text-xs text-[#9aa4ae]">None known</span>
        )}
      </td>
      <td className={`${td} text-right font-medium`}>
        {row.unitSavings !== null ? (
          <span className="text-[#2f6b45]">
            {formatMoney(row.unitSavings)}{" "}
            <span className="text-xs font-normal text-[#7a8592]">/ {unit}</span>
          </span>
        ) : (
          <span className="text-[#9aa4ae]">—</span>
        )}
      </td>
      <td className={`${td} pr-5 text-[#536174]`}>{daysAgo(row.current.purchaseDate, today)}</td>
    </tr>
  );
}

function ChangeBadge({ percent }: { percent: number }) {
  if (percent === 0) return <span className="text-[#536174]">0.0%</span>;
  const up = percent > 0;
  return (
    <span
      className={`inline-flex items-center gap-0.5 font-medium ${up ? "text-[#a83340]" : "text-[#2f6b45]"}`}
    >
      {up ? <ArrowUpRight className="size-3.5" /> : <ArrowDownRight className="size-3.5" />}
      {formatPercent(percent, true)}
    </span>
  );
}

export function PriceEvidence({ row, today }: { row: PriceRow; today: string }) {
  const unit = row.current.unitOfMeasure?.trim() || "unit";
  const evidence: Array<[string, ReactNode]> = [
    ["Current vendor", row.current.vendorName],
    [
      "Current price",
      <>
        {formatMoney(row.current.price)} / {unit}{" "}
        <Ref invoiceNumber={row.current.invoiceNumber} date={row.current.purchaseDate} />
      </>,
    ],
    ["Unit / package", unitLabel(row.current)],
    ["Quantity on that invoice", row.current.quantity.toLocaleString("en-US")],
    [
      "Previous price (same vendor and unit)",
      row.previous ? (
        <>
          {formatMoney(row.previous.price)}{" "}
          <Ref invoiceNumber={row.previous.invoiceNumber} date={row.previous.purchaseDate} />
        </>
      ) : (
        "No earlier comparable purchase"
      ),
    ],
    [
      "Difference",
      row.absoluteChange !== null ? (
        <>
          {formatSignedMoney(row.absoluteChange)}
          {row.percentChange !== null && ` (${formatPercent(row.percentChange, true)})`}
        </>
      ) : (
        "—"
      ),
    ],
    [
      "90-day average (same vendor and unit)",
      row.recentAverage ? (
        <>
          {formatMoney(row.recentAverage.average)}{" "}
          <span className="text-[#7a8592]">
            from {row.recentAverage.observationCount}{" "}
            {row.recentAverage.observationCount === 1 ? "purchase" : "purchases"},{" "}
            {formatDay(row.recentAverage.windowStart)} – {formatDay(row.recentAverage.windowEnd)}
          </span>
        </>
      ) : (
        "—"
      ),
    ],
    [
      "Lowest known other vendor",
      row.bestAlternative ? (
        <>
          {row.bestAlternative.vendorName} · {formatMoney(row.bestAlternative.price)} / {unit}{" "}
          <Ref
            invoiceNumber={row.bestAlternative.invoiceNumber}
            date={row.bestAlternative.purchaseDate}
          />
          <span className="block text-[#7a8592]">
            {unitLabel(row.bestAlternative)} · {row.bestAlternative.comparableVendorCount}{" "}
            comparable {row.bestAlternative.comparableVendorCount === 1 ? "vendor" : "vendors"}
          </span>
        </>
      ) : (
        "None with the same unit and recorded package"
      ),
    ],
    [
      "Potential unit savings",
      row.unitSavings !== null ? `${formatMoney(row.unitSavings)} / ${unit}` : "None",
    ],
  ];
  return (
    <div className="space-y-4 text-sm" data-section="price-evidence">
      {row.comparability === "missing_unit_of_measure" && (
        <p
          role="status"
          className="rounded-lg border border-[#f1d9b5] bg-[#fff8ee] px-3 py-2 text-xs text-[#7c4a0e]"
        >
          The latest invoice line did not record a unit of measure, so this price is not compared
          with any other purchase.
        </p>
      )}
      <dl className="divide-y divide-[#edf0f3] rounded-lg border border-[#e2e7ec]">
        {evidence.map(([label, value]) => (
          <div key={label} className="grid grid-cols-[minmax(0,11rem)_1fr] gap-3 px-3 py-2">
            <dt className="text-xs text-[#697687]">{label}</dt>
            <dd className="tabular-nums text-[#102a49]">{value}</dd>
          </div>
        ))}
      </dl>
      <p className="text-xs text-[#7a8592]">
        Last purchased {daysAgo(row.current.purchaseDate, today)}. All figures are unit prices from
        posted USD invoices in this organization. A previous price must be from the same vendor with
        the same unit of measure and package; another vendor counts only with the same unit of
        measure and the same recorded package size. Package contents are taken from invoice text and
        are not independently verified.
      </p>
    </div>
  );
}

function Ref({ invoiceNumber, date }: { invoiceNumber: string | null; date: string }) {
  return (
    <span className="text-xs text-[#7a8592]">
      ({invoiceNumber ? `invoice #${invoiceNumber}, ` : ""}
      {formatDay(date)})
    </span>
  );
}

// ---------------------------------------------------------------------------
// Recent purchasing
// ---------------------------------------------------------------------------

export function RecentPurchasing({
  purchases,
  renderLink = defaultLink,
}: {
  purchases: InvoiceReference[];
  renderLink?: RenderLink;
}) {
  return (
    <section className={`${panel} p-5`} aria-labelledby="recent-purchasing-title">
      <SectionHeading
        id="recent-purchasing-title"
        title="Recent Purchasing"
        description="Latest posted invoices"
        action={renderLink({
          to: "/purchases",
          className: "text-xs font-medium text-[#102a49] underline underline-offset-2",
          children: "All purchases",
        })}
      />
      <InvoiceList
        invoices={purchases}
        renderLink={renderLink}
        empty="No invoices have been posted yet."
      />
    </section>
  );
}

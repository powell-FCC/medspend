// Presentational sections of the Budget & Purchasing command center. Data loading lives in
// BudgetPurchasingPage; everything here renders from props so it can be server-rendered in
// tests. Keep imports relative and limited to .ts modules.
import { useState, type ReactNode } from "react";
import { AlertTriangle, ChevronRight } from "lucide-react";
import {
  BUDGET_WARNING_THRESHOLD,
  budgetStatus,
  formatDay,
  formatMoney,
  formatPercent,
  formatPeriodShort,
  requestCountLabel,
  requestReviewLink,
  utilizationRatio,
  utilizationSegments,
  type AttentionItem,
  type BudgetLineage,
  type BudgetRow,
  type CommitmentReference,
  type InvoiceReference,
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
        Create an organization-wide budget for a period to track posted spend against it. Spend and
        commitment figures are not shown until a budget exists.
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
  const over = summary.remainingAmount < 0;
  const coversToday = summary.periodStart <= today && summary.periodEnd >= today;
  const figures: Array<[string, number, string]> = [
    ["Budget", summary.budgetAmount, "Organization-wide for this period"],
    [
      "Spent",
      summary.actualSpend,
      `${summary.postedInvoiceCount.toLocaleString("en-US")} posted ${summary.postedInvoiceCount === 1 ? "document" : "documents"}`,
    ],
    ["Remaining", summary.remainingAmount, "After posted spend (Budget − Spent)"],
    [
      "Open commitments",
      summary.openCommitmentAmount,
      `Approved or ordered · ${requestCountLabel(summary.openCommitmentCount)} · priced items only`,
    ],
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
              className={`mt-1 whitespace-nowrap text-lg font-semibold tabular-nums tracking-tight min-[400px]:text-xl sm:text-2xl xl:text-[28px] ${label === "Remaining" && over ? "text-[#a83340]" : "text-[#102a49]"}`}
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
          aria-label={`Spent ${formatMoney(summary.actualSpend)}, remaining ${formatMoney(summary.remainingAmount)}`}
        >
          <div className="h-full bg-[#102a49]" style={{ width: `${segments.spent}%` }} />
          <div className="h-full bg-[#cfe3d6]" style={{ width: `${segments.remaining}%` }} />
        </div>
        <div className="mt-2 flex flex-wrap items-center gap-x-5 gap-y-1 text-xs text-[#5e6d7e]">
          <Legend color="bg-[#102a49]" label="Spent" value={summary.actualSpend} />
          <Legend
            color="bg-[#cfe3d6]"
            label="Remaining"
            value={Math.max(summary.remainingAmount, 0)}
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
          Posted spend exceeds this budget by {formatMoney(-summary.remainingAmount)}.
        </p>
      )}
      {summary.incompleteCommitmentCount > 0 && (
        <p
          role="status"
          className="mt-3 rounded-lg border border-[#f1d9b5] bg-[#fff8ee] px-3 py-2 text-xs text-[#7c4a0e]"
        >
          {summary.incompleteCommitmentCount.toLocaleString("en-US")} active{" "}
          {summary.incompleteCommitmentCount === 1 ? "commitment has" : "commitments have"} unpriced
          items. Commitment totals include known prices only; unpriced items are not $0 exposure.
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
          {requestCountLabel(summary.settlementCandidateCount)}{" "}
          {summary.settlementCandidateCount === 1 ? "is" : "are"} already received or completed, but{" "}
          {summary.settlementCandidateCount === 1 ? "its commitment is" : "their commitments are"}{" "}
          still active. {summary.settlementCandidateCount === 1 ? "It is" : "They are"} not
          subtracted from Remaining because the purchase may already be in Spent. Requests are not
          matched to invoices automatically, so this is not confirmed duplicate spend.
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
        description="Every active budget period. Organization-wide · spend attributed by invoice date (UTC)."
      />
      <div className="mt-3 -mx-5 overflow-x-auto">
        <table className="w-full min-w-[700px] text-sm">
          <thead className="border-y border-[#edf0f3] bg-[#fafbfc]">
            <tr>
              <th className={`${th} pl-5`}>Budget</th>
              <th className={`${th} text-right`}>Allocated</th>
              <th className={`${th} text-right`}>Spent</th>
              <th className={`${th} text-right`}>Committed</th>
              <th className={`${th} text-right`}>Remaining</th>
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
                    className={`${td} text-right font-medium ${budget.actualSpend > budget.budgetAmount ? "text-[#a83340]" : "text-[#102a49]"}`}
                  >
                    {formatMoney(budget.budgetAmount - budget.actualSpend)}
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
            ["Remaining", budget.budgetAmount - budget.actualSpend],
            ["Active commitments", budget.committedSpend],
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
        These requests are received or completed, but their commitments are still active. They are
        never subtracted from Remaining, because the purchase may already be in posted spend.
        SportSpend does not match requests to invoices, so check each one: if you confirm its
        purchase is now in posted spend, release the commitment as settled from the request;
        otherwise leave it active. Nothing is released from this page.
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

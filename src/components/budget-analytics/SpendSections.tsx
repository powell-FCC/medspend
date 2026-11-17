// Presentational sections of the Phase 7E Spend tab. Data loading lives in SpendWorkspace;
// everything here renders from props so it can be server-rendered in tests. Keep imports
// relative and limited to .ts modules (plus recharts for the two charts).
import type { ReactNode } from "react";
import {
  Area,
  Bar,
  BarChart,
  CartesianGrid,
  ComposedChart,
  Line,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import {
  COVERAGE_STATEMENTS,
  PACE_REFERENCE_NOTE,
  SCOPE_STATEMENT,
  approxRemainingLabel,
  commitmentCoverageLabel,
  coverageLines,
  cumulativeChartPoints,
  documentTypeLabel,
  formatMonthLabel,
  formatUsd,
  formatUtcDay,
  paceLabel,
  signalDrill,
  signalLabel,
  unitGroupLabel,
  type CommitmentList,
  type DocumentDetail,
  type DocumentFilter,
  type DocumentList,
  type ProductSpend,
  type RemovalList,
  type SpendSeries,
  type SpendSignal,
  type SpendSummary,
  type VendorSpend,
} from "../../budget-analytics/spend.ts";

const panel =
  "min-w-0 rounded-xl border border-[#dfe5eb] bg-white shadow-[0_5px_20px_rgba(16,42,73,0.04)]";
const th =
  "whitespace-nowrap px-3 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-[#697687]";
const td = "whitespace-nowrap px-3 py-2.5 tabular-nums";
const linkButton =
  "text-left font-medium text-[#102a49] underline-offset-2 hover:underline disabled:cursor-default disabled:no-underline";

function Heading({
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

// ---------------------------------------------------------------------------
// Scope and headline
// ---------------------------------------------------------------------------

export function SpendScopeLine({ summary }: { summary: SpendSummary }) {
  const scope = summary.scope;
  return (
    <p className="text-sm text-[#697687]" data-section="spend-scope">
      {scope.kind === "budget" ? (
        <>
          <span className="font-medium text-[#102a49]">{scope.budgetName}</span> ·{" "}
          {formatUtcDay(scope.from)} – {formatUtcDay(scope.to)} · {SCOPE_STATEMENT} (UTC)
          {scope.budgetActive === false ? " · inactive budget" : ""}
        </>
      ) : (
        <>
          No active budget · calendar year to date {formatUtcDay(scope.from)} –{" "}
          {formatUtcDay(scope.to)} · spend attributed by invoice date (UTC)
        </>
      )}
    </p>
  );
}

export function SpendHeadline({ summary }: { summary: SpendSummary }) {
  const open = summary.commitments.open;
  const received = summary.commitments.receivedNotSettled;
  const hasBudget = summary.scope.kind === "budget";
  const over = summary.remaining !== null && summary.remaining < 0;
  const figures: Array<{ label: string; value: string; note: string; tone?: "alert" }> = [];
  if (hasBudget)
    figures.push({
      label: "Budget",
      value: formatUsd(summary.scope.budgetAmount ?? 0),
      note: "Organization-wide for this period",
    });
  figures.push({
    label: "Spent",
    value: formatUsd(summary.spent),
    note: `${summary.countedDocumentCount.toLocaleString("en-US")} posted ${summary.countedDocumentCount === 1 ? "document" : "documents"}`,
  });
  if (hasBudget && summary.remaining !== null)
    figures.push({
      label: "Remaining",
      value: over ? `−${formatUsd(-summary.remaining)}` : formatUsd(summary.remaining),
      note: over ? "Over budget · after posted spend" : "After posted spend (Budget − Spent)",
      tone: over ? "alert" : undefined,
    });
  figures.push({
    label: "Open commitments",
    value: formatUsd(open.pricedAmount),
    note: `Approved or ordered · ${commitmentCoverageLabel(open)}`,
  });
  figures.push({
    label: "Received, not settled",
    value: formatUsd(received.pricedAmount),
    note: `${commitmentCoverageLabel(received)} · not subtracted`,
  });
  const approx = approxRemainingLabel(summary);
  const pace = paceLabel(summary.pace);
  return (
    <section className={`${panel} p-5 sm:p-6`} aria-labelledby="spend-headline-title">
      <h2 id="spend-headline-title" className="sr-only">
        Spend summary
      </h2>
      <dl className="grid grid-cols-2 gap-x-4 gap-y-5 sm:gap-x-6 lg:grid-cols-5">
        {figures.map((f) => (
          <div
            key={f.label}
            className="min-w-0 border-l-2 border-[#e6ebf0] pl-3 first:border-[#102a49] sm:pl-4"
          >
            <dt className="text-xs font-semibold uppercase tracking-wide text-[#697687]">
              {f.label}
            </dt>
            <dd
              className={`mt-1 whitespace-nowrap text-lg font-semibold tabular-nums tracking-tight sm:text-2xl ${f.tone === "alert" ? "text-[#a83340]" : "text-[#102a49]"}`}
            >
              {f.value}
            </dd>
            <dd className="mt-0.5 text-xs text-[#7a8592]">{f.note}</dd>
          </div>
        ))}
      </dl>
      {approx && (
        <p className="mt-4 text-sm text-[#536174]" data-figure="approx-remaining">
          {approx}
        </p>
      )}
      {(open.unpriced > 0 || open.partiallyPriced > 0) && (
        <p className="mt-1 text-xs text-[#7c4a0e]">
          Unpriced commitment items are not $0: their exposure is unknown until they are priced.
        </p>
      )}
      {pace && (
        <div className="mt-4 border-t border-[#edf0f3] pt-3" data-figure="pace">
          <p className="text-sm font-medium text-[#102a49]">
            {pace}
            {summary.pace?.state === "in_progress" && summary.pace.spentPercent !== null && (
              <span className="font-normal text-[#697687]">
                {" "}
                · {summary.pace.spentPercent.toFixed(1)}% spent,{" "}
                {summary.pace.elapsedPercent.toFixed(1)}% of the period elapsed
              </span>
            )}
          </p>
          <p className="mt-0.5 text-xs text-[#7a8592]">{PACE_REFERENCE_NOTE}</p>
        </div>
      )}
      <dl
        className="mt-4 grid grid-cols-1 gap-2 border-t border-[#edf0f3] pt-3 text-xs text-[#536174] sm:grid-cols-3"
        data-figure="burn"
      >
        <div>
          <dt>Spent this month (UTC, from {formatUtcDay(summary.burn.monthStart)})</dt>
          <dd className="font-semibold tabular-nums text-[#102a49]">
            {formatUsd(summary.burn.spentThisMonth)}
          </dd>
        </div>
        <div>
          <dt>Trailing 90 days</dt>
          <dd className="font-semibold tabular-nums text-[#102a49]">
            {formatUsd(summary.burn.trailing90Days)}
          </dd>
        </div>
        <div>
          <dt>Average per complete month</dt>
          <dd className="font-semibold tabular-nums text-[#102a49]">
            {summary.burn.averagePerCompleteMonth === null
              ? "Needs 6 months with spend"
              : formatUsd(summary.burn.averagePerCompleteMonth)}
          </dd>
        </div>
      </dl>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Attention signals
// ---------------------------------------------------------------------------

export function SpendSignals({
  signals,
  canDrill,
  onDrill,
}: {
  signals: SpendSignal[];
  canDrill: boolean;
  onDrill: (signal: SpendSignal) => void;
}) {
  return (
    <section
      className={`${panel} p-5`}
      aria-labelledby="spend-signals-title"
      data-section="spend-signals"
    >
      <Heading
        id="spend-signals-title"
        title="Needs attention"
        description="Fixed checks over the figures above"
      />
      {signals.length === 0 ? (
        <p className="mt-3 text-sm text-[#697687]">Nothing needs attention.</p>
      ) : (
        <ul className="mt-3 divide-y divide-[#edf0f3]">
          {signals.map((signal) => {
            const drill = signalDrill(signal.code);
            const drillable =
              drill !== null &&
              (canDrill || drill === "commitments_open" || drill === "commitments_received");
            return (
              <li
                key={signal.code}
                className="flex items-start justify-between gap-3 py-2.5 text-sm"
              >
                <span className="flex items-start gap-2">
                  <span
                    aria-hidden
                    className={`mt-1.5 size-2 shrink-0 rounded-full ${signal.severity === "critical" ? "bg-[#a83340]" : signal.severity === "warning" ? "bg-[#e08a2e]" : "bg-[#8ea0b4]"}`}
                  />
                  <span className="text-[#334155]">{signalLabel(signal)}</span>
                </span>
                {drillable && (
                  <button
                    type="button"
                    onClick={() => onDrill(signal)}
                    className="shrink-0 text-xs font-semibold text-[#2a5d8f] hover:underline"
                  >
                    View
                  </button>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

// ---------------------------------------------------------------------------
// Charts
// ---------------------------------------------------------------------------

export function CumulativeSpendChart({
  series,
  budgetAmount,
}: {
  series: SpendSeries;
  budgetAmount: number | null;
}) {
  const points = cumulativeChartPoints(series, budgetAmount);
  return (
    <section
      className={`${panel} p-5`}
      aria-labelledby="cumulative-title"
      data-section="cumulative-chart"
    >
      <Heading
        id="cumulative-title"
        title="Cumulative spend"
        description={
          budgetAmount === null
            ? "Posted spend over the period"
            : "Posted spend against an even pace (dashed) and the budget amount"
        }
      />
      <div
        className="mt-3 h-64"
        role="img"
        aria-label={`Cumulative posted spend reaches ${formatUsd(series.total)} by ${formatUtcDay(series.to)}`}
      >
        <ResponsiveContainer width="100%" height="100%">
          <ComposedChart data={points} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
            <CartesianGrid stroke="#eef1f4" vertical={false} />
            <XAxis
              dataKey="date"
              tickFormatter={(d: string) => formatUtcDay(d).replace(/, \d{4}$/, "")}
              tick={{ fontSize: 11 }}
              minTickGap={24}
            />
            <YAxis
              tickFormatter={(v: number) => formatUsd(v).replace(/\.00$/, "")}
              tick={{ fontSize: 11 }}
              width={80}
            />
            <Tooltip
              formatter={(value: number, name: string) => [
                formatUsd(value),
                name === "even" ? "Even pace" : "Spent to date",
              ]}
              labelFormatter={(label: string) => formatUtcDay(label)}
            />
            <Area
              type="stepAfter"
              dataKey="cumulative"
              stroke="#102a49"
              fill="#dbe6f1"
              strokeWidth={2}
              isAnimationActive={false}
            />
            {budgetAmount !== null && (
              <Line
                type="linear"
                dataKey="even"
                stroke="#8ea0b4"
                strokeDasharray="5 4"
                dot={false}
                isAnimationActive={false}
              />
            )}
            {budgetAmount !== null && (
              <ReferenceLine y={budgetAmount} stroke="#a83340" strokeDasharray="2 3" />
            )}
          </ComposedChart>
        </ResponsiveContainer>
      </div>
    </section>
  );
}

export function MonthlySpendChart({
  series,
  onSelectMonth,
}: {
  series: SpendSeries;
  onSelectMonth?: (month: string) => void;
}) {
  return (
    <section
      className={`${panel} p-5`}
      aria-labelledby="monthly-title"
      data-section="monthly-chart"
    >
      <Heading
        id="monthly-title"
        title="Monthly spend"
        description={
          onSelectMonth
            ? "UTC calendar months · select a month to see its documents"
            : "UTC calendar months"
        }
      />
      <div className="mt-3 h-56" role="img" aria-label="Posted spend by month">
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={series.months} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
            <CartesianGrid stroke="#eef1f4" vertical={false} />
            <XAxis dataKey="month" tickFormatter={formatMonthLabel} tick={{ fontSize: 11 }} />
            <YAxis
              tickFormatter={(v: number) => formatUsd(v).replace(/\.00$/, "")}
              tick={{ fontSize: 11 }}
              width={80}
            />
            <Tooltip
              formatter={(value: number) => [formatUsd(value), "Spent"]}
              labelFormatter={(label: string) => formatMonthLabel(label)}
            />
            <Bar
              dataKey="amount"
              fill="#102a49"
              radius={[3, 3, 0, 0]}
              isAnimationActive={false}
              cursor={onSelectMonth ? "pointer" : undefined}
              onClick={
                onSelectMonth
                  ? (entry: { month?: string }) => entry.month && onSelectMonth(entry.month)
                  : undefined
              }
            />
          </BarChart>
        </ResponsiveContainer>
      </div>
      <table className="sr-only">
        <caption>Posted spend by month</caption>
        <tbody>
          {series.months.map((m) => (
            <tr key={m.month}>
              <th scope="row">{formatMonthLabel(m.month)}</th>
              <td>{formatUsd(m.amount)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Vendor and product tables
// ---------------------------------------------------------------------------

function ShareBar({ percent }: { percent: number | null }) {
  if (percent === null) return <span className="text-xs text-[#7a8592]">—</span>;
  return (
    <span className="flex items-center gap-2">
      <span className="h-1.5 w-16 overflow-hidden rounded-full bg-[#eef1f4]">
        <span
          className="block h-full bg-[#102a49]"
          style={{ width: `${Math.min(percent, 100)}%` }}
        />
      </span>
      {percent.toFixed(1)}%
    </span>
  );
}

export function VendorSpendTable({
  vendors,
  onSelectVendor,
}: {
  vendors: VendorSpend;
  onSelectVendor?: (vendorId: string) => void;
}) {
  return (
    <section
      className={`${panel} p-5`}
      aria-labelledby="vendor-spend-title"
      data-section="vendor-spend"
    >
      <Heading
        id="vendor-spend-title"
        title="Vendors"
        description="Posted spend by vendor, tax and shipping included"
      />
      {vendors.rows.length === 0 ? (
        <p className="mt-3 text-sm text-[#697687]">No posted spend in this period.</p>
      ) : (
        <div className="-mx-5 mt-3 overflow-x-auto">
          <table className="w-full min-w-[640px] text-sm">
            <thead className="border-y border-[#edf0f3] bg-[#fafbfc]">
              <tr>
                <th className={`${th} pl-5`}>Vendor</th>
                <th className={`${th} text-right`}>Spend</th>
                <th className={th}>Share</th>
                <th className={`${th} text-right`}>Documents</th>
                <th className={`${th} text-right`}>Largest</th>
                <th className={`${th} pr-5`}>Latest</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#edf0f3]">
              {vendors.rows.map((v) => (
                <tr key={v.vendorId ?? "none"}>
                  <td className="px-3 py-2.5 pl-5">
                    <button
                      type="button"
                      className={linkButton}
                      disabled={!onSelectVendor || !v.vendorId}
                      onClick={() => v.vendorId && onSelectVendor?.(v.vendorId)}
                    >
                      {v.vendorName ?? "Vendor not recorded"}
                    </button>
                    {v.orderConfirmationCount > 0 && (
                      <span className="block text-xs text-[#7a8592]">
                        includes {v.orderConfirmationCount} order confirmation
                        {v.orderConfirmationCount === 1 ? "" : "s"}
                      </span>
                    )}
                  </td>
                  <td className={`${td} text-right font-medium text-[#102a49]`}>
                    {formatUsd(v.spend)}
                  </td>
                  <td className={td}>
                    <ShareBar percent={v.sharePercent} />
                  </td>
                  <td className={`${td} text-right`}>{v.documentCount}</td>
                  <td className={`${td} text-right`}>{formatUsd(v.largestDocument)}</td>
                  <td className={`${td} pr-5`}>{formatUtcDay(v.lastSpendDate)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

export function ProductSpendTable({
  products,
  onSelectProduct,
}: {
  products: ProductSpend;
  onSelectProduct?: (productId: string | null, name: string) => void;
}) {
  const r = products.reconciliation;
  return (
    <section
      className={`${panel} p-5`}
      aria-labelledby="product-spend-title"
      data-section="product-spend"
    >
      <Heading
        id="product-spend-title"
        title="Top products"
        description="Line spend before tax and shipping. Unit prices are compared only within the same unit and package."
      />
      {products.rows.length === 0 ? (
        <p className="mt-3 text-sm text-[#697687]">No posted lines in this period.</p>
      ) : (
        <div className="-mx-5 mt-3 overflow-x-auto">
          <table className="w-full min-w-[680px] text-sm">
            <thead className="border-y border-[#edf0f3] bg-[#fafbfc]">
              <tr>
                <th className={`${th} pl-5`}>Product</th>
                <th className={`${th} text-right`}>Line spend</th>
                <th className={th}>Share</th>
                <th className={th}>Quantity by unit</th>
                <th className={`${th} pr-5`}>Latest</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#edf0f3]">
              {products.rows.map((p) => (
                <tr key={p.productId ?? "none"}>
                  <td className="px-3 py-2.5 pl-5">
                    <button
                      type="button"
                      className={linkButton}
                      disabled={!onSelectProduct}
                      onClick={() => onSelectProduct?.(p.productId, p.productName)}
                    >
                      {p.productName}
                    </button>
                    <span className="block text-xs text-[#7a8592]">
                      {p.documentCount} document{p.documentCount === 1 ? "" : "s"} · {p.vendorCount}{" "}
                      vendor
                      {p.vendorCount === 1 ? "" : "s"}
                    </span>
                  </td>
                  <td className={`${td} text-right font-medium text-[#102a49]`}>
                    {formatUsd(p.lineSpend)}
                  </td>
                  <td className={td}>
                    <ShareBar percent={p.sharePercent} />
                  </td>
                  <td className="px-3 py-2.5 text-xs text-[#536174]">
                    {p.unitGroups.map((g) => (
                      <span
                        key={`${g.unitOfMeasure}-${g.packageSize}`}
                        className="block whitespace-nowrap"
                      >
                        {g.quantity.toLocaleString("en-US")} × {unitGroupLabel(g)}
                        {g.minUnitPrice !== null && g.maxUnitPrice !== null && (
                          <span className="text-[#7a8592]">
                            {" "}
                            ·{" "}
                            {g.minUnitPrice === g.maxUnitPrice
                              ? formatUsd(g.minUnitPrice)
                              : `${formatUsd(g.minUnitPrice)}–${formatUsd(g.maxUnitPrice)}`}
                          </span>
                        )}
                      </span>
                    ))}
                  </td>
                  <td className={`${td} pr-5`}>{formatUtcDay(p.lastSpendDate)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="mt-3 text-xs text-[#697687]" data-figure="reconciliation">
        Lines {formatUsd(r.linesTotal)} + tax {formatUsd(r.taxTotal)} + shipping{" "}
        {formatUsd(r.shippingTotal)}
        {r.difference !== 0 ? ` + header differences ${formatUsd(r.difference)}` : ""} = Spent{" "}
        {formatUsd(r.spent)}
      </p>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Commitments
// ---------------------------------------------------------------------------

export function CommitmentsPanel({
  summary,
  list,
  renderRequestLink,
}: {
  summary: SpendSummary;
  list?: CommitmentList;
  renderRequestLink?: (requestId: string, children: ReactNode) => ReactNode;
}) {
  const { open, receivedNotSettled } = summary.commitments;
  return (
    <section
      className={`${panel} p-5`}
      aria-labelledby="spend-commitments-title"
      data-section="spend-commitments"
    >
      <Heading
        id="spend-commitments-title"
        title="Commitments"
        description="Estimated at approval. Never subtracted from Remaining."
      />
      <dl className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="rounded-lg border border-[#e2e7ec] p-3">
          <dt className="text-xs font-semibold uppercase tracking-wide text-[#697687]">
            Open · approved or ordered
          </dt>
          <dd className="mt-1 text-lg font-semibold tabular-nums text-[#102a49]">
            {formatUsd(open.pricedAmount)}
          </dd>
          <dd className="text-xs text-[#7a8592]">
            {open.count} request{open.count === 1 ? "" : "s"} · {commitmentCoverageLabel(open)}
            {open.staleCount > 0 ? ` · ${open.staleCount} older than 30 days` : ""}
          </dd>
        </div>
        <div className="rounded-lg border border-[#e2e7ec] p-3">
          <dt className="text-xs font-semibold uppercase tracking-wide text-[#697687]">
            Received, not settled
          </dt>
          <dd className="mt-1 text-lg font-semibold tabular-nums text-[#102a49]">
            {formatUsd(receivedNotSettled.pricedAmount)}
          </dd>
          <dd className="text-xs text-[#7a8592]">
            {receivedNotSettled.count} request{receivedNotSettled.count === 1 ? "" : "s"} · may
            already be in Spent
          </dd>
        </div>
      </dl>
      {list && list.rows.length > 0 && (
        <ul className="mt-3 divide-y divide-[#edf0f3] rounded-lg border border-[#e2e7ec] text-sm">
          {list.rows.map((c) => {
            const label = (
              <span className="font-medium text-[#102a49]">{c.itemLabel ?? "Request"}</span>
            );
            return (
              <li
                key={c.commitmentId}
                className="flex flex-wrap items-center justify-between gap-2 px-3 py-2"
              >
                <span>
                  {renderRequestLink ? renderRequestLink(c.requestId, label) : label}
                  <span className="block text-xs text-[#7a8592]">
                    {c.bucket === "open" ? "Open" : "Received, not settled"} · {c.requestStatus}
                    {c.teamName ? ` · ${c.teamName}` : ""} · committed{" "}
                    {formatUtcDay(c.commitmentDate)}
                  </span>
                </span>
                <span className="tabular-nums text-[#334155]">
                  {c.amount === null ? "Unpriced" : formatUsd(c.amount)}
                  {c.pricingStatus === "partially_priced" && (
                    <span className="block text-right text-xs text-[#7c4a0e]">
                      {c.pricedItemCount} of {c.itemCount} items priced
                    </span>
                  )}
                </span>
              </li>
            );
          })}
        </ul>
      )}
      {list && list.totalCount > list.rows.length && (
        <p className="mt-2 text-xs text-[#7a8592]">
          Showing {list.rows.length} of {list.totalCount}.
        </p>
      )}
    </section>
  );
}

// ---------------------------------------------------------------------------
// Coverage
// ---------------------------------------------------------------------------

export function CoveragePanel({
  summary,
  canDrill,
  onDrill,
}: {
  summary: SpendSummary;
  canDrill: boolean;
  onDrill: (filter: DocumentFilter) => void;
}) {
  return (
    <section
      className={`${panel} p-5`}
      aria-labelledby="coverage-title"
      data-section="spend-coverage"
    >
      <Heading id="coverage-title" title="What these numbers include" />
      <ul className="mt-3 space-y-1.5 text-xs leading-5 text-[#536174]">
        {COVERAGE_STATEMENTS.map((statement) => (
          <li key={statement}>{statement}</li>
        ))}
      </ul>
      <table className="mt-4 w-full text-sm">
        <tbody className="divide-y divide-[#edf0f3]">
          {coverageLines(summary).map((line) => (
            <tr key={line.key} data-coverage={line.key}>
              <td className="py-2 pr-3 text-[#334155]">
                {canDrill && line.filter && line.count > 0 ? (
                  <button
                    type="button"
                    className={linkButton}
                    onClick={() => onDrill(line.filter!)}
                  >
                    {line.label}
                  </button>
                ) : (
                  line.label
                )}
              </td>
              <td className="py-2 pr-3 text-right tabular-nums">
                {line.count.toLocaleString("en-US")}
              </td>
              <td className="py-2 text-right tabular-nums text-[#536174]">
                {line.amount === null ? "" : formatUsd(line.amount)}
              </td>
            </tr>
          ))}
          <tr data-coverage="linesCategorized">
            <td className="py-2 pr-3 text-[#334155]">Posted lines whose product has a category</td>
            <td className="py-2 pr-3 text-right tabular-nums" colSpan={2}>
              {summary.coverage.linesCategorized.categorized} of{" "}
              {summary.coverage.linesCategorized.total}
            </td>
          </tr>
        </tbody>
      </table>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Drill-down (owner)
// ---------------------------------------------------------------------------

export function DocumentListView({
  list,
  onOpen,
  onMore,
  loadingMore,
}: {
  list: DocumentList;
  onOpen: (invoiceId: string) => void;
  onMore?: () => void;
  loadingMore?: boolean;
}) {
  return (
    <div className="space-y-3 text-sm" data-section="document-list">
      <p className="text-[#334155]">
        <span className="font-semibold tabular-nums">
          {list.totalCount.toLocaleString("en-US")} document{list.totalCount === 1 ? "" : "s"} ·{" "}
          {formatUsd(list.totalAmount)}
        </span>
        {list.countsTowardSpent ? " in Spent" : " · not counted in Spent"}
      </p>
      <ul className="divide-y divide-[#edf0f3] rounded-lg border border-[#e2e7ec]">
        {list.rows.map((d) => (
          <li key={d.invoiceId} className="flex items-start justify-between gap-3 px-3 py-2">
            <span className="min-w-0">
              <button type="button" className={linkButton} onClick={() => onOpen(d.invoiceId)}>
                {d.vendorName ?? "Vendor not recorded"} · {d.documentNumber ?? "No number"}
              </button>
              <span className="block text-xs text-[#7a8592]">
                {formatUtcDay(d.spendDate)}
                {d.dateBasis === "posted_at_utc" ? " (posting day)" : ""} ·{" "}
                {documentTypeLabel(d.documentType)}
                {d.currencyBasis === "legacy_usd" ? " · no currency recorded" : ""}
                {d.exclusionReason ? ` · excluded (${d.exclusionReason.replace("_", " ")})` : ""}
              </span>
            </span>
            <span className="shrink-0 tabular-nums text-[#102a49]">{formatUsd(d.amount)}</span>
          </li>
        ))}
      </ul>
      {list.nextCursor && onMore && (
        <button
          type="button"
          onClick={onMore}
          disabled={loadingMore}
          className="rounded-md border border-[#dfe5eb] bg-white px-3 py-1.5 text-xs font-semibold text-[#102a49]"
        >
          {loadingMore ? "Loading…" : "Show more"}
        </button>
      )}
    </div>
  );
}

export function DocumentDetailView({ detail }: { detail: DocumentDetail }) {
  const d = detail.document;
  const flags = Object.entries(detail.flags)
    .filter(([, on]) => on)
    .map(([key]) => key);
  const flagText: Record<string, string> = {
    orderConfirmation: "Order confirmation counted as spend (may overlap a later invoice)",
    datedByPosting: "No invoice date: dated by the UTC posting day",
    typeUnclassified: "Document type not classified",
    legacyCurrency: "No currency recorded (treated as USD)",
    componentDifference: "Header total differs from lines + tax + shipping",
    possibleDuplicate: "Possible duplicate",
    outsideBudgets: "Outside every active budget period",
  };
  return (
    <div className="space-y-5 text-sm" data-section="document-detail">
      <dl className="grid grid-cols-2 gap-3">
        {(
          [
            [
              "Spend date",
              `${formatUtcDay(d.spendDate)}${d.dateBasis === "posted_at_utc" ? " (posting day)" : ""}`,
            ],
            ["Amount", formatUsd(d.amount)],
            ["Type", documentTypeLabel(d.documentType)],
            [
              "Counted in Spent",
              d.counted ? "Yes" : `No (${d.exclusionReason?.replace("_", " ")})`,
            ],
          ] as const
        ).map(([label, value]) => (
          <div key={label} className="rounded-lg border border-[#e2e7ec] p-3">
            <dt className="text-xs text-[#697687]">{label}</dt>
            <dd className="mt-1 font-semibold text-[#102a49]">{value}</dd>
          </div>
        ))}
      </dl>
      {flags.length > 0 && (
        <ul className="space-y-1 text-xs text-[#7c4a0e]">
          {flags.map((f) => (
            <li key={f}>{flagText[f] ?? f}</li>
          ))}
        </ul>
      )}
      <table className="w-full text-sm">
        <thead>
          <tr>
            <th className={`${th} pl-0`}>Line</th>
            <th className={`${th} text-right`}>Qty</th>
            <th className={`${th} pr-0 text-right`}>Total</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-[#edf0f3]">
          {detail.lines.map((line) => (
            <tr key={line.invoiceItemId}>
              <td className="py-2">
                {line.productName ?? line.description ?? "Line"}
                <span className="block text-xs text-[#7a8592]">{unitGroupLabel(line)}</span>
              </td>
              <td className="py-2 text-right tabular-nums">{line.quantity}</td>
              <td className="py-2 text-right tabular-nums">
                {line.totalPrice === null ? "—" : formatUsd(line.totalPrice)}
              </td>
            </tr>
          ))}
        </tbody>
        <tfoot className="text-xs text-[#536174]">
          <tr>
            <td className="pt-2" colSpan={2}>
              Lines
            </td>
            <td className="pt-2 text-right tabular-nums">{formatUsd(d.linesTotal ?? 0)}</td>
          </tr>
          <tr>
            <td colSpan={2}>Tax</td>
            <td className="text-right tabular-nums">{formatUsd(d.taxAmount ?? 0)}</td>
          </tr>
          <tr>
            <td colSpan={2}>Shipping</td>
            <td className="text-right tabular-nums">{formatUsd(d.shippingAmount ?? 0)}</td>
          </tr>
          {d.componentDifference !== 0 && (
            <tr>
              <td colSpan={2}>Header difference</td>
              <td className="text-right tabular-nums">{formatUsd(d.componentDifference)}</td>
            </tr>
          )}
          <tr className="font-semibold text-[#102a49]">
            <td colSpan={2}>Document total</td>
            <td className="text-right tabular-nums">{formatUsd(d.amount)}</td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

export function RemovalsPanel({ removals }: { removals: RemovalList }) {
  if (removals.totalCount === 0) return null;
  return (
    <section className={`${panel} p-5`} aria-labelledby="removals-title" data-section="removals">
      <Heading
        id="removals-title"
        title="Removed after posting"
        description="Permanent records of posted documents that were removed. Source files are kept."
      />
      <ul className="mt-3 divide-y divide-[#edf0f3] text-sm">
        {removals.rows.map((r) => (
          <li key={r.removalId} className="py-2">
            <span className="font-medium text-[#102a49]">
              {r.vendorName ?? "Vendor not recorded"} · {r.documentNumber ?? "No number"} ·{" "}
              {formatUsd(r.spendAmount)}
            </span>
            <span className="block text-xs text-[#7a8592]">
              Removed {formatUtcDay(r.removedAt)} by {r.removedByName ?? "an owner"} · “{r.reason}”
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

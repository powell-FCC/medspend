// Phase 6B.1 presentational sections: the Price Intelligence list, the product vendor history
// and the read-only request-review line. Everything renders from props so it can be
// server-rendered in tests. Keep imports relative and limited to .ts modules.
//
// Every price shown is a historical purchase price from a posted invoice or order
// confirmation, with its vendor, unit, date and source. Nothing here is a current or market
// price, recommends a vendor, or computes savings.
import type { ReactNode } from "react";
import {
  PRICE_SIGNALS,
  PRICE_STATES,
  comparisonStatusLabels,
  differenceText,
  filterLabels,
  formatDay,
  formatUsd,
  identityIssueLabels,
  lastPurchasedText,
  lowerComparableText,
  pricePerUnit,
  purchaseHistorySearch,
  recencyText,
  sameSkuChangeText,
  SEVERAL_SKUS_TEXT,
  signalLabels,
  sourceLabel,
  stateDescriptions,
  stateLabels,
  unitText,
  type PriceEvidence,
  type PriceFilter,
  type PriceListRow,
  type PriceSignal,
  type PriceSort,
  type PriceState,
  type PriceSummary,
  type ProductVendorHistory,
  type RequestPriceContextItem,
  type SourceObservation,
} from "../../price-intelligence/vendor-intelligence.ts";

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
  "whitespace-nowrap px-3 py-2 text-left text-xs font-semibold uppercase tracking-wide text-[#718092]";
const td = "px-3 py-2.5 align-top";
const muted = "text-xs text-[#7a8592]";

const stateTone: Record<PriceState, string> = {
  insufficient_identity: "border-[#f1d9b5] bg-[#fff8ee] text-[#7c4a0e]",
  one_purchase: "border-[#e2e7ec] bg-[#f5f7f9] text-[#536174]",
  single_vendor: "border-[#e2e7ec] bg-[#f5f7f9] text-[#536174]",
  comparable: "border-[#cfe3d6] bg-[#f1f8f3] text-[#2f6b45]",
  missing_package_details: "border-[#f1d9b5] bg-[#fff8ee] text-[#7c4a0e]",
  incompatible_units: "border-[#f1d9b5] bg-[#fff8ee] text-[#7c4a0e]",
};

export function StateBadge({ state, stale }: { state: PriceState; stale: boolean }) {
  return (
    <span className="inline-flex flex-wrap items-center gap-1" data-state={state}>
      <span
        className={`inline-flex rounded-full border px-2 py-0.5 text-xs font-medium ${stateTone[state]}`}
        title={stateDescriptions[state]}
      >
        {stateLabels[state]}
      </span>
      {stale && (
        <span
          className="inline-flex rounded-full border border-[#e2e7ec] bg-[#f5f7f9] px-2 py-0.5 text-xs font-medium text-[#697687]"
          data-marker="stale"
        >
          Stale
        </span>
      )}
    </span>
  );
}

export function SignalList({ signals }: { signals: PriceSignal[] }) {
  if (signals.length === 0) return <span className="text-[#9aa4ae]">—</span>;
  return (
    <ul className="space-y-0.5">
      {signals.map((signal) => (
        <li key={signal} className="text-xs leading-5 text-[#334155]" data-signal={signal}>
          {signalLabels[signal]}
        </li>
      ))}
    </ul>
  );
}

function AgeNote({ ageDays, recency }: { ageDays: number; recency: "recent" | "aging" | "stale" }) {
  const text = recencyText(ageDays, recency);
  return text ? (
    <span className={`block ${recency === "stale" ? "text-[#a83340]" : "text-[#7a8592]"} text-xs`}>
      {text}
    </span>
  ) : null;
}

function EvidenceLine({ evidence }: { evidence: PriceEvidence }) {
  return (
    <span className={`block ${muted}`}>
      {[
        evidence.sku ? `SKU ${evidence.sku}` : "No SKU",
        sourceLabel(evidence.documentType, evidence.dateBasis),
      ].join(" · ")}
    </span>
  );
}

// ---------------------------------------------------------------------------
// Price Intelligence list
// ---------------------------------------------------------------------------

const filterGroups: Array<{ label: string; filters: PriceFilter[] }> = [
  { label: "Status", filters: ["all", ...PRICE_STATES] },
  { label: "Signals", filters: [...PRICE_SIGNALS] },
];

function filterCount(summary: PriceSummary | undefined, filter: PriceFilter) {
  if (!summary) return null;
  if (filter === "all") return summary.productCount;
  if (filter in summary.states) return summary.states[filter as PriceState];
  return summary.signals[filter as PriceSignal];
}

export function PriceIntelligenceList({
  summary,
  rows,
  filter,
  sort,
  vendorId,
  selectedProductId,
  canLoadMore,
  loadingMore,
  onFilter,
  onSort,
  onVendor,
  onSelect,
  onLoadMore,
}: {
  summary?: PriceSummary;
  rows: PriceListRow[];
  filter: PriceFilter;
  sort: PriceSort;
  vendorId: string | null;
  selectedProductId?: string | null;
  canLoadMore: boolean;
  loadingMore?: boolean;
  onFilter?: (filter: PriceFilter) => void;
  onSort?: (sort: PriceSort) => void;
  onVendor?: (vendorId: string | null) => void;
  onSelect?: (productId: string) => void;
  onLoadMore?: () => void;
}) {
  return (
    <section
      className={`${panel} p-5`}
      aria-labelledby="price-intelligence-title"
      data-section="price-intelligence-list"
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 id="price-intelligence-title" className="text-base font-semibold text-[#102a49]">
            Price Intelligence
          </h2>
          <p className="mt-1 max-w-3xl text-sm text-[#697687]">
            Prices you have paid, from posted invoices and order confirmations. Vendors are compared
            only when the item, unit and package are proven the same; SportSpend does not recommend
            a vendor.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {summary && summary.vendors.length > 1 && (
            <label className="flex items-center gap-2 text-sm text-[#536174]">
              Last purchase vendor
              <select
                className="rounded-md border border-[#dfe5eb] bg-white px-2 py-1.5 text-sm"
                value={vendorId ?? ""}
                onChange={(e) => onVendor?.(e.target.value || null)}
              >
                <option value="">All vendors</option>
                {summary.vendors.map((v) => (
                  <option key={v.vendorId} value={v.vendorId}>
                    {v.vendorName}
                  </option>
                ))}
              </select>
            </label>
          )}
          <label className="flex items-center gap-2 text-sm text-[#536174]">
            Sort
            <select
              className="rounded-md border border-[#dfe5eb] bg-white px-2 py-1.5 text-sm"
              value={sort}
              onChange={(e) => onSort?.(e.target.value as PriceSort)}
            >
              <option value="recent">Most recent purchase</option>
              <option value="product">Product name</option>
            </select>
          </label>
        </div>
      </div>

      <div className="mt-4 space-y-2">
        {filterGroups.map((group) => (
          <div
            key={group.label}
            role="group"
            aria-label={`${group.label} filter`}
            className="flex flex-wrap items-center gap-1.5"
          >
            <span className="mr-1 text-xs font-semibold uppercase tracking-wide text-[#718092]">
              {group.label}
            </span>
            {group.filters.map((key) => {
              const n = filterCount(summary, key);
              const active = filter === key;
              return (
                <button
                  key={key}
                  type="button"
                  aria-pressed={active}
                  onClick={() => onFilter?.(key)}
                  className={`rounded-full border px-2.5 py-1 text-xs ${active ? "border-[#102a49] bg-[#102a49] text-white" : "border-[#dfe5eb] bg-white text-[#334155] hover:bg-[#f5f7f9]"}`}
                >
                  {filterLabels[key]}
                  {n !== null && <span className="ml-1 tabular-nums opacity-75">{n}</span>}
                </button>
              );
            })}
          </div>
        ))}
      </div>

      {rows.length === 0 ? (
        <p className="mt-5 rounded-lg border border-dashed border-[#dfe5eb] px-4 py-6 text-center text-sm text-[#697687]">
          {filter === "all"
            ? "No purchase history yet. Prices appear here once invoices are posted."
            : `No products match “${filterLabels[filter]}”.`}
        </p>
      ) : (
        <div className="mt-4 overflow-x-auto">
          <table className="w-full min-w-[920px] text-sm">
            <thead className="border-b border-[#e2e7ec]">
              <tr>
                <th className={`${th} pl-0`}>Product</th>
                <th className={th}>Last purchase vendor</th>
                <th className={`${th} text-right`}>Last purchase price</th>
                <th className={`${th} text-right`}>Vendors observed</th>
                <th className={th}>Same-SKU change</th>
                <th className={th}>Signal</th>
                <th className={`${th} pr-0`}>Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#edf0f3]">
              {rows.map((row) => (
                <PriceListRowView
                  key={row.productId}
                  row={row}
                  selected={row.productId === selectedProductId}
                  onSelect={onSelect}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}
      {canLoadMore && (
        <div className="mt-4 flex justify-center">
          <button
            type="button"
            onClick={onLoadMore}
            disabled={loadingMore}
            className="rounded-md border border-[#dfe5eb] bg-white px-4 py-2 text-sm font-medium text-[#102a49] hover:bg-[#f5f7f9] disabled:opacity-60"
          >
            {loadingMore ? "Loading…" : "Load more"}
          </button>
        </div>
      )}
      <p className={`mt-3 ${muted}`}>
        Historical purchase prices in USD per invoiced unit (no currency recorded is treated as USD;
        other currencies are excluded). Catalog list prices are never used. Purchases more than 180
        days old are shown but never ranked or compared.
      </p>
    </section>
  );
}

function PriceListRowView({
  row,
  selected,
  onSelect,
}: {
  row: PriceListRow;
  selected: boolean;
  onSelect?: (productId: string) => void;
}) {
  const last = row.lastPurchase;
  const change = sameSkuChangeText(row.changeAmount, row.changePercent);
  return (
    <tr
      data-product-id={row.productId}
      aria-selected={selected}
      className={selected ? "bg-[#f1f6fb]" : "hover:bg-[#fafbfc]"}
    >
      <td className={`${td} max-w-[260px] pl-0`}>
        {onSelect ? (
          <button
            type="button"
            onClick={() => onSelect(row.productId)}
            className="block max-w-full text-left font-medium text-[#102a49] underline-offset-2 [overflow-wrap:anywhere] hover:underline"
          >
            {row.productName}
          </button>
        ) : (
          <span className="block font-medium text-[#102a49]">{row.productName}</span>
        )}
      </td>
      <td className={`${td} max-w-[180px] text-[#334155] [overflow-wrap:anywhere]`}>
        {last.vendorName}
      </td>
      <td className={`${td} text-right tabular-nums`}>
        <span className="block font-medium text-[#102a49]">
          {pricePerUnit(last.price, last.unitOfMeasure)}
        </span>
        <span className={`block ${muted}`}>{formatDay(last.purchaseDate)}</span>
        <EvidenceLine evidence={last} />
        <AgeNote ageDays={last.ageDays} recency={last.recency} />
      </td>
      <td className={`${td} text-right tabular-nums text-[#334155]`}>{row.vendorsObserved}</td>
      <td className={`${td} text-[#334155]`}>
        {change ?? <span className="text-[#9aa4ae]">—</span>}
      </td>
      <td className={`${td} max-w-[240px]`}>
        <SignalList signals={row.signals} />
      </td>
      <td className={`${td} pr-0`}>
        <StateBadge state={row.state} stale={row.stale} />
      </td>
    </tr>
  );
}

// ---------------------------------------------------------------------------
// Product vendor history (product detail)
// ---------------------------------------------------------------------------

export function ProductVendorHistoryView({
  history,
  observations,
  canLoadMore,
  loadingMore,
  onLoadMore,
  onOpenDocument,
}: {
  history: ProductVendorHistory;
  observations: SourceObservation[];
  canLoadMore: boolean;
  loadingMore?: boolean;
  onLoadMore?: () => void;
  onOpenDocument?: (invoiceId: string) => void;
}) {
  if (!history.state || !history.lastPurchase) {
    return (
      <div data-section="product-vendor-history" className="space-y-2 text-sm">
        <p className="font-medium text-[#102a49]">No purchase history</p>
        <p className="text-[#697687]">
          Prices appear once an invoice or order confirmation for this product is posted.
          {history.coverage.excludedNonUsdCount > 0 &&
            ` ${history.coverage.excludedNonUsdCount} non-USD ${history.coverage.excludedNonUsdCount === 1 ? "purchase is" : "purchases are"} excluded.`}
        </p>
      </div>
    );
  }
  const last = history.lastPurchase;
  const change = sameSkuChangeText(history.changeAmount, history.changePercent);
  const openDocument = history.canOpenSourceDocument ? onOpenDocument : undefined;
  return (
    <div data-section="product-vendor-history" className="space-y-5 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <StateBadge state={history.state} stale={history.stale ?? false} />
        <span className={muted}>{stateDescriptions[history.state]}</span>
      </div>

      {history.identity && (
        <div
          role="status"
          className="rounded-lg border border-[#f1d9b5] bg-[#fff8ee] px-3 py-2 text-xs text-[#7c4a0e]"
          data-section="identity"
        >
          <p className="font-medium">
            {identityIssueLabels[history.identity.issue ?? ""] ??
              "This product's identity can't be proven."}{" "}
            Prices are not compared.
          </p>
          <ul className="mt-1 list-disc pl-4">
            {history.identity.skus.map((s, i) => (
              <li key={`${s.vendorId}-${s.sku ?? i}`}>
                {s.vendorName ?? "Vendor"} · {s.sku ? `SKU ${s.sku}` : "No SKU"}
                {s.observed ? " · purchased" : " · mapped, not purchased"}
              </li>
            ))}
          </ul>
        </div>
      )}

      <dl className="divide-y divide-[#edf0f3] rounded-lg border border-[#e2e7ec]">
        <EvidenceRow label="Last purchase price">
          <span className="font-medium">{pricePerUnit(last.price, last.unitOfMeasure)}</span> from{" "}
          {last.vendorName} on {formatDay(last.purchaseDate)}
          <EvidenceLine evidence={last} />
          <AgeNote ageDays={last.ageDays} recency={last.recency} />
        </EvidenceRow>
        <EvidenceRow label="Prior purchase, same SKU">
          {history.priorSameSku ? (
            <>
              {pricePerUnit(history.priorSameSku.price, history.priorSameSku.unitOfMeasure)} on{" "}
              {formatDay(history.priorSameSku.purchaseDate)}
              <EvidenceLine evidence={history.priorSameSku} />
            </>
          ) : (
            <span className="text-[#7a8592]">
              {history.state === "insufficient_identity"
                ? "Not compared"
                : "No earlier purchase of this SKU"}
            </span>
          )}
        </EvidenceRow>
        <EvidenceRow label="Difference from last purchase">
          {change ?? <span className="text-[#7a8592]">—</span>}
        </EvidenceRow>
        {history.state === "comparable" && (
          <>
            <EvidenceRow label="Lowest comparable purchase price">
              {history.lowestComparable ? (
                <>
                  <span className="font-medium">
                    {pricePerUnit(
                      history.lowestComparable.price,
                      history.lowestComparable.unitOfMeasure,
                    )}
                  </span>{" "}
                  from {history.lowestComparable.vendorName} on{" "}
                  {formatDay(history.lowestComparable.purchaseDate)}
                  <EvidenceLine evidence={history.lowestComparable} />
                </>
              ) : (
                <span className="text-[#7a8592]">
                  {history.comparisonWithheld === "stale"
                    ? "Withheld: a comparable purchase is more than 180 days old."
                    : "Withheld: no other vendor is comparable with the last purchase."}
                </span>
              )}
            </EvidenceRow>
            {history.differencePerUnit !== null && history.comparableAlternative && (
              <EvidenceRow label="Price difference per comparable invoiced unit">
                {differenceText(history.differencePerUnit, last.unitOfMeasure)} against{" "}
                {history.comparableAlternative.vendorName}
              </EvidenceRow>
            )}
          </>
        )}
        <EvidenceRow label="Signals">
          <SignalList signals={history.signals} />
        </EvidenceRow>
      </dl>

      <section aria-labelledby="observed-vendors-heading">
        <h3 id="observed-vendors-heading" className="text-sm font-semibold text-[#102a49]">
          Observed vendors · {history.vendorsObserved}
        </h3>
        <div className="mt-2 overflow-x-auto">
          <table className="w-full min-w-[720px] text-sm" data-section="observed-vendors">
            <thead className="border-b border-[#e2e7ec]">
              <tr>
                <th className={`${th} pl-0`}>Vendor</th>
                <th className={th}>Vendor SKU</th>
                <th className={`${th} text-right`}>Last purchase price</th>
                <th className={th}>Package</th>
                <th className={th}>Last purchase</th>
                <th className={`${th} text-right`}>Purchases</th>
                <th className={`${th} pr-0`}>Comparison</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#edf0f3]">
              {history.vendors.map((v) => (
                <tr
                  key={v.vendorId}
                  data-vendor-id={v.vendorId}
                  data-comparison={v.comparisonStatus}
                >
                  <td className={`${td} pl-0 font-medium text-[#102a49]`}>{v.vendorName}</td>
                  <td className={`${td} text-[#334155]`}>
                    {v.skus.map((s, i) => (
                      <span key={s.sku ?? i} className="block">
                        {s.sku ?? "No SKU"}
                        {!s.observed && <span className={muted}> (mapped)</span>}
                      </span>
                    ))}
                  </td>
                  <td className={`${td} text-right tabular-nums`}>
                    {pricePerUnit(v.lastPurchase.price, v.lastPurchase.unitOfMeasure)}
                  </td>
                  <td className={`${td} text-[#334155]`}>
                    {v.lastPurchase.packageSize ?? "Not recorded"}
                  </td>
                  <td className={`${td} text-[#334155]`}>
                    {formatDay(v.lastPurchaseDate)}
                    <AgeNote ageDays={v.lastPurchase.ageDays} recency={v.lastPurchase.recency} />
                  </td>
                  <td className={`${td} text-right tabular-nums`}>{v.purchaseCount}</td>
                  <td className={`${td} pr-0 text-[#334155]`}>
                    {comparisonStatusLabels[v.comparisonStatus]}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {history.vendorsObserved > history.vendors.length && (
          <p className={`mt-2 ${muted}`}>
            Showing the {history.vendors.length} most recent of {history.vendorsObserved} vendors.
          </p>
        )}
      </section>

      <section aria-labelledby="source-observations-heading">
        <h3 id="source-observations-heading" className="text-sm font-semibold text-[#102a49]">
          Source purchases · {history.observationCount}
        </h3>
        <div className="mt-2 overflow-x-auto">
          <table className="w-full min-w-[820px] text-sm" data-section="source-observations">
            <thead className="border-b border-[#e2e7ec]">
              <tr>
                <th className={`${th} pl-0`}>Date</th>
                <th className={th}>Source</th>
                <th className={th}>Vendor · SKU</th>
                <th className={`${th} text-right`}>Qty</th>
                <th className={th}>Unit</th>
                <th className={th}>Package</th>
                <th className={`${th} text-right`}>Price</th>
                <th className={`${th} pr-0 text-right`}>Line amount</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#edf0f3]">
              {observations.map((o) => (
                <tr
                  key={o.observationId}
                  data-observation-id={o.observationId}
                  data-document-type={o.documentType}
                >
                  <td className={`${td} pl-0 whitespace-nowrap`}>
                    {formatDay(o.purchaseDate)}
                    <AgeNote ageDays={o.ageDays} recency={o.recency} />
                  </td>
                  <td className={td}>
                    <span className="block">{sourceLabel(o.documentType, o.dateBasis)}</span>
                    <span className={`block ${muted}`}>
                      {openDocument ? (
                        <button
                          type="button"
                          className="underline underline-offset-2"
                          onClick={() => openDocument(o.invoiceId)}
                        >
                          {o.documentNumber ?? "Open document"}
                        </button>
                      ) : (
                        (o.documentNumber ?? "No number")
                      )}
                      {o.lineNumber !== null && ` · line ${o.lineNumber}`}
                    </span>
                  </td>
                  <td className={`${td} [overflow-wrap:anywhere]`}>
                    {o.vendorName}
                    <span className={`block ${muted}`}>{o.sku ? `SKU ${o.sku}` : "No SKU"}</span>
                  </td>
                  <td className={`${td} text-right tabular-nums`}>
                    {o.quantity.toLocaleString("en-US")}
                  </td>
                  <td className={td}>
                    {o.unitOfMeasure ?? "Not recorded"}
                    {!o.unitValid && o.unitOfMeasure && (
                      <span className={`block ${muted}`}>Unreadable unit</span>
                    )}
                  </td>
                  <td className={td}>{o.packageSize ?? "Not recorded"}</td>
                  <td className={`${td} text-right tabular-nums`}>
                    {pricePerUnit(o.price, o.unitOfMeasure)}
                  </td>
                  <td className={`${td} pr-0 text-right tabular-nums`}>
                    {o.lineAmount === null ? "—" : formatUsd(o.lineAmount)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {canLoadMore && (
          <button
            type="button"
            onClick={onLoadMore}
            disabled={loadingMore}
            className="mt-3 rounded-md border border-[#dfe5eb] bg-white px-3 py-1.5 text-sm font-medium text-[#102a49] hover:bg-[#f5f7f9] disabled:opacity-60"
          >
            {loadingMore ? "Loading…" : "Load more"}
          </button>
        )}
        <p className={`mt-2 ${muted}`}>
          {history.canOpenSourceDocument
            ? "Open a document number to see the posted source document."
            : "Source documents can be opened by the organization owner."}
          {history.coverage.excludedNonUsdCount > 0 &&
            ` ${history.coverage.excludedNonUsdCount} non-USD ${history.coverage.excludedNonUsdCount === 1 ? "purchase is" : "purchases are"} excluded.`}
        </p>
      </section>
    </div>
  );
}

function EvidenceRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="grid grid-cols-[minmax(0,12rem)_1fr] gap-3 px-3 py-2">
      <dt className="text-xs text-[#697687]">{label}</dt>
      <dd className="tabular-nums text-[#102a49]">{children}</dd>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Request review: one read-only line per item
// ---------------------------------------------------------------------------

export function RequestItemPriceContext({
  item,
  renderLink = defaultLink,
}: {
  item: RequestPriceContextItem | undefined;
  renderLink?: RenderLink;
}) {
  if (!item || item.status === "unresolved" || item.status === "no_history" || !item.productId)
    return null;
  const link = renderLink({
    to: "/budget-purchasing",
    search: purchaseHistorySearch(item.productId),
    className: "underline underline-offset-2",
    children: item.status === "several_skus" ? SEVERAL_SKUS_TEXT : "View purchase history",
  });
  return (
    <div
      className="mt-1 space-y-0.5 text-xs leading-5 text-[#526174]"
      data-section="request-price-context"
    >
      {item.status === "several_skus" ? (
        <p>{link}</p>
      ) : (
        item.lastPurchase && (
          <>
            <p>{lastPurchasedText(item.lastPurchase)}</p>
            {item.lowerComparable && <p>{lowerComparableText(item.lowerComparable)}</p>}
            <p>{link}</p>
          </>
        )
      )}
    </div>
  );
}

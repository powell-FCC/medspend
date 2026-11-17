import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import {
  getDocumentDetailFn,
  getSpendSeriesFn,
  getSpendSummaryFn,
  listCommitmentsFn,
  listProductLinesFn,
  listProductSpendFn,
  listRemovalsFn,
  listSpendDocumentsFn,
  listVendorSpendFn,
} from "@/lib/budget-analytics.functions";
import {
  formatUsd,
  formatUtcDay,
  signalDrill,
  type DocumentFilter,
  type SpendSignal,
} from "@/budget-analytics/spend";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { SectionError, SectionLoading } from "@/components/budget-purchasing/CommandCenterSections";
import {
  CommitmentsPanel,
  CoveragePanel,
  CumulativeSpendChart,
  DocumentDetailView,
  DocumentListView,
  MonthlySpendChart,
  ProductSpendTable,
  RemovalsPanel,
  SpendHeadline,
  SpendScopeLine,
  SpendSignals,
  VendorSpendTable,
} from "./SpendSections";

type Drill =
  | { kind: "documents"; filter: DocumentFilter; value: string | null; title: string }
  | { kind: "product"; productId: string | null; title: string }
  | { kind: "document"; invoiceId: string };

const filterTitles: Record<DocumentFilter, string> = {
  all: "Posted documents in Spent",
  month: "Documents in this month",
  vendor: "Documents from this vendor",
  dated_by_posting: "Dated by the UTC posting day",
  order_confirmations: "Order confirmations counted as spend",
  type_unclassified: "Document type not classified",
  legacy_currency: "No currency recorded (treated as USD)",
  component_difference: "Header total differs from components",
  possible_duplicates: "Possible duplicates",
  outside_budgets: "Outside every active budget period (any date)",
  excluded: "Excluded from Spent",
};

/**
 * Phase 7E Spend tab: organization-wide spend for one budget period. Owners and admins see the
 * figures; only owners can open document-level detail (the RPCs enforce the same rule).
 */
export function SpendWorkspace({ organizationId }: { organizationId: string }) {
  const [budgetId, setBudgetId] = useState<string | null>(null);
  const [drill, setDrill] = useState<Drill | null>(null);
  const fetchSummary = useServerFn(getSpendSummaryFn);
  const fetchSeries = useServerFn(getSpendSeriesFn);
  const fetchVendors = useServerFn(listVendorSpendFn);
  const fetchProducts = useServerFn(listProductSpendFn);
  const fetchCommitments = useServerFn(listCommitmentsFn);
  const fetchRemovals = useServerFn(listRemovalsFn);

  const summary = useQuery({
    queryKey: ["budget-purchasing", organizationId, "spend", "summary", budgetId],
    queryFn: () => fetchSummary({ data: { organizationId, budgetId } }),
  });
  const scope = summary.data?.scope;
  const range = scope ? { organizationId, from: scope.from, to: scope.to } : null;
  const isOwner = summary.data?.viewerIsOwner ?? false;

  const series = useQuery({
    queryKey: ["budget-purchasing", organizationId, "spend", "series", range?.from, range?.to],
    queryFn: () => fetchSeries({ data: range! }),
    enabled: !!range,
  });
  const vendors = useQuery({
    queryKey: ["budget-purchasing", organizationId, "spend", "vendors", range?.from, range?.to],
    queryFn: () => fetchVendors({ data: range! }),
    enabled: !!range,
  });
  const products = useQuery({
    queryKey: ["budget-purchasing", organizationId, "spend", "products", range?.from, range?.to],
    queryFn: () => fetchProducts({ data: { ...range!, sort: "spend", limit: 15, offset: 0 } }),
    enabled: !!range,
  });
  const commitments = useQuery({
    queryKey: ["budget-purchasing", organizationId, "spend", "commitments", range?.from, range?.to],
    queryFn: () => fetchCommitments({ data: { ...range!, bucket: "all", limit: 25, offset: 0 } }),
    enabled: !!range,
  });
  const removals = useQuery({
    queryKey: ["budget-purchasing", organizationId, "spend", "removals"],
    queryFn: () => fetchRemovals({ data: { organizationId } }),
    enabled: isOwner,
  });

  if (summary.isPending) return <SectionLoading label="Loading spend…" />;
  if (summary.isError)
    return <SectionError message="Spend could not be loaded." onRetry={() => summary.refetch()} />;
  const data = summary.data;

  const openDocuments = (filter: DocumentFilter, value: string | null = null, title?: string) =>
    isOwner && setDrill({ kind: "documents", filter, value, title: title ?? filterTitles[filter] });
  const onSignal = (signal: SpendSignal) => {
    const target = signalDrill(signal.code);
    if (!target) return;
    if (target === "commitments_open" || target === "commitments_received") {
      document.getElementById("spend-commitments-title")?.scrollIntoView({ behavior: "smooth" });
      return;
    }
    openDocuments(target);
  };

  return (
    <div className="space-y-5" data-workspace="spend">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <SpendScopeLine summary={data} />
        {data.budgets.length > 1 && (
          <label className="flex items-center gap-2 text-sm text-[#536174]">
            Budget period
            <select
              className="rounded-md border border-[#dfe5eb] bg-white px-2 py-2 text-sm"
              value={data.scope.budgetId ?? ""}
              onChange={(e) => setBudgetId(e.target.value || null)}
            >
              {data.budgets.map((b) => (
                <option key={b.budgetId} value={b.budgetId}>
                  {b.budgetName} · {formatUtcDay(b.periodStart)} – {formatUtcDay(b.periodEnd)}
                </option>
              ))}
            </select>
          </label>
        )}
      </div>
      <SpendHeadline summary={data} />
      <SpendSignals signals={data.signals} canDrill={isOwner} onDrill={onSignal} />
      <div className="grid grid-cols-1 gap-5 xl:grid-cols-2">
        {series.isPending ? (
          <SectionLoading label="Loading spend over time…" />
        ) : series.isError ? (
          <SectionError
            message="Spend over time could not be loaded."
            onRetry={() => series.refetch()}
          />
        ) : (
          <>
            <CumulativeSpendChart series={series.data} budgetAmount={data.scope.budgetAmount} />
            <MonthlySpendChart
              series={series.data}
              onSelectMonth={
                isOwner
                  ? (month) => openDocuments("month", month, `Documents in ${month}`)
                  : undefined
              }
            />
          </>
        )}
      </div>
      <div className="grid grid-cols-1 gap-5 xl:grid-cols-2">
        {vendors.isPending ? (
          <SectionLoading label="Loading vendors…" />
        ) : vendors.isError ? (
          <SectionError
            message="Vendor spend could not be loaded."
            onRetry={() => vendors.refetch()}
          />
        ) : (
          <VendorSpendTable
            vendors={vendors.data}
            onSelectVendor={isOwner ? (vendorId) => openDocuments("vendor", vendorId) : undefined}
          />
        )}
        {products.isPending ? (
          <SectionLoading label="Loading products…" />
        ) : products.isError ? (
          <SectionError
            message="Product spend could not be loaded."
            onRetry={() => products.refetch()}
          />
        ) : (
          <ProductSpendTable
            products={products.data}
            onSelectProduct={
              isOwner
                ? (productId, name) => setDrill({ kind: "product", productId, title: name })
                : undefined
            }
          />
        )}
      </div>
      <CommitmentsPanel
        summary={data}
        list={commitments.data}
        renderRequestLink={(requestId, children) => (
          <Link to="/supply-requests" search={{ request: requestId } as never}>
            {children}
          </Link>
        )}
      />
      <CoveragePanel
        summary={data}
        canDrill={isOwner}
        onDrill={(filter) => openDocuments(filter)}
      />
      {!isOwner && (
        <p className="text-xs text-[#697687]">
          Invoice-level detail is available to organization owners.
        </p>
      )}
      {isOwner && removals.data && <RemovalsPanel removals={removals.data} />}

      <Sheet open={!!drill} onOpenChange={(open) => !open && setDrill(null)}>
        <SheetContent className="w-full overflow-y-auto sm:max-w-xl">
          {drill && range && (
            <DrillContent
              organizationId={organizationId}
              range={range}
              drill={drill}
              onOpenDocument={(invoiceId) => setDrill({ kind: "document", invoiceId })}
            />
          )}
        </SheetContent>
      </Sheet>
    </div>
  );
}

function DrillContent({
  organizationId,
  range,
  drill,
  onOpenDocument,
}: {
  organizationId: string;
  range: { organizationId: string; from: string; to: string };
  drill: Drill;
  onOpenDocument: (invoiceId: string) => void;
}) {
  if (drill.kind === "document")
    return <DocumentDetailDrill organizationId={organizationId} invoiceId={drill.invoiceId} />;
  if (drill.kind === "product")
    return (
      <>
        <SheetHeader className="mb-4">
          <SheetTitle>{drill.title}</SheetTitle>
          <SheetDescription>Posted lines in this period</SheetDescription>
        </SheetHeader>
        <ProductLinesDrill
          organizationId={organizationId}
          range={range}
          productId={drill.productId}
          onOpenDocument={onOpenDocument}
        />
        <p className="mt-3 text-xs text-[#697687]">Line totals exclude tax and shipping.</p>
      </>
    );
  return (
    <>
      <SheetHeader className="mb-4">
        <SheetTitle>{drill.title}</SheetTitle>
        <SheetDescription>
          {drill.filter === "outside_budgets"
            ? "Any date"
            : `${formatUtcDay(range.from)} – ${formatUtcDay(range.to)}`}
        </SheetDescription>
      </SheetHeader>
      <DocumentsDrill
        range={range}
        filter={drill.filter}
        value={drill.value}
        onOpenDocument={onOpenDocument}
      />
    </>
  );
}

function DocumentsDrill({
  range,
  filter,
  value,
  onOpenDocument,
}: {
  range: { organizationId: string; from: string; to: string };
  filter: DocumentFilter;
  value: string | null;
  onOpenDocument: (invoiceId: string) => void;
}) {
  const fetchDocuments = useServerFn(listSpendDocumentsFn);
  const documents = useInfiniteQuery({
    queryKey: [
      "budget-purchasing",
      range.organizationId,
      "spend",
      "documents",
      range.from,
      range.to,
      filter,
      value,
    ],
    initialPageParam: null as { spendDate: string; invoiceId: string } | null,
    queryFn: ({ pageParam }) =>
      fetchDocuments({ data: { ...range, filter, value, limit: 50, cursor: pageParam } }),
    getNextPageParam: (page) => page.nextCursor,
  });
  if (documents.isPending) return <SectionLoading label="Loading documents…" />;
  if (documents.isError)
    return <SectionError message={documents.error.message} onRetry={() => documents.refetch()} />;
  const first = documents.data.pages[0];
  const merged = {
    ...first,
    rows: documents.data.pages.flatMap((p) => p.rows),
    nextCursor: documents.data.pages.at(-1)!.nextCursor,
  };
  return (
    <DocumentListView
      list={merged}
      onOpen={onOpenDocument}
      onMore={() => documents.fetchNextPage()}
      loadingMore={documents.isFetchingNextPage}
    />
  );
}

function ProductLinesDrill({
  organizationId,
  range,
  productId,
  onOpenDocument,
}: {
  organizationId: string;
  range: { organizationId: string; from: string; to: string };
  productId: string | null;
  onOpenDocument: (invoiceId: string) => void;
}) {
  const fetchLines = useServerFn(listProductLinesFn);
  const lines = useQuery({
    queryKey: [
      "budget-purchasing",
      organizationId,
      "spend",
      "product-lines",
      productId,
      range.from,
      range.to,
    ],
    queryFn: () => fetchLines({ data: { ...range, productId } }),
  });
  if (lines.isPending) return <SectionLoading label="Loading lines…" />;
  if (lines.isError)
    return <SectionError message={lines.error.message} onRetry={() => lines.refetch()} />;
  return (
    <ul className="divide-y divide-[#edf0f3] rounded-lg border border-[#e2e7ec] text-sm">
      {lines.data.rows.map((line) => (
        <li key={line.invoiceItemId} className="flex justify-between gap-3 px-3 py-2">
          <span>
            <button
              type="button"
              className="text-left font-medium text-[#102a49] hover:underline"
              onClick={() => onOpenDocument(line.invoiceId)}
            >
              {line.vendorName ?? "Vendor"} · {line.documentNumber ?? "No number"}
            </button>
            <span className="block text-xs text-[#7a8592]">
              {formatUtcDay(line.spendDate)} · {line.quantity} {line.unitOfMeasure ?? ""}
            </span>
          </span>
          <span className="tabular-nums">
            {line.totalPrice === null ? "—" : formatUsd(line.totalPrice)}
          </span>
        </li>
      ))}
    </ul>
  );
}

function DocumentDetailDrill({
  organizationId,
  invoiceId,
}: {
  organizationId: string;
  invoiceId: string;
}) {
  const fetchDetail = useServerFn(getDocumentDetailFn);
  const detail = useQuery({
    queryKey: ["budget-purchasing", organizationId, "spend", "document", invoiceId],
    queryFn: () => fetchDetail({ data: { organizationId, invoiceId } }),
  });
  if (detail.isPending) return <SectionLoading label="Loading document…" />;
  if (detail.isError)
    return <SectionError message={detail.error.message} onRetry={() => detail.refetch()} />;
  const d = detail.data.document;
  return (
    <>
      <SheetHeader className="mb-4">
        <SheetTitle>
          {d.vendorName ?? "Vendor not recorded"} · {d.documentNumber ?? "No number"}
        </SheetTitle>
        <SheetDescription>
          {d.sourceFileId ? (
            <Link
              to="/invoices/$invoiceId"
              params={{ invoiceId: d.sourceFileId } as never}
              className="underline"
            >
              Open the invoice
            </Link>
          ) : (
            "Posted document"
          )}
        </SheetDescription>
      </SheetHeader>
      <DocumentDetailView detail={detail.data} />
    </>
  );
}

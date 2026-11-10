import { useEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Link } from "@tanstack/react-router";
import { AlertCircle, ArrowLeft, FileStack, Loader2, RotateCcw } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useActiveOrg } from "@/hooks/use-active-org";
import {
  getInvoiceBatchFn,
  processInvoiceBatchFn,
  releaseInvoiceBatchSegmentFn,
} from "@/lib/invoice-batches.functions";
import {
  BATCH_ROW_LABEL,
  batchCounts,
  batchRowStatus,
  pageRangeLabel,
  reasonText,
  type BatchRowStatus,
} from "@/invoice-batch/status";
import type { InvoiceBatch, InvoiceBatchSegment } from "@/types/invoice-batch";
import { cn } from "@/lib/utils";

const TONE: Record<BatchRowStatus, string> = {
  ready: "border-transparent bg-emerald-100 text-emerald-900",
  needs_review: "border-transparent bg-amber-100 text-amber-900",
  parsing_failed: "border-transparent bg-red-100 text-red-900",
  duplicate: "border-transparent bg-slate-200 text-slate-800",
  segmentation_issue: "border-transparent bg-orange-100 text-orange-900",
  preparing: "border-transparent bg-sky-100 text-sky-900",
  failed: "border-transparent bg-red-100 text-red-900",
  posted: "border-transparent bg-primary/15 text-primary",
  removed: "border-transparent bg-muted text-muted-foreground",
  not_invoice: "border-transparent bg-muted text-muted-foreground",
};
const SUMMARY_ORDER: BatchRowStatus[] = [
  "ready",
  "needs_review",
  "parsing_failed",
  "duplicate",
  "segmentation_issue",
  "failed",
  "posted",
];

const money = (value: number | null) =>
  value === null
    ? "—"
    : new Intl.NumberFormat(undefined, { style: "currency", currency: "USD" }).format(value);
const date = (value: string | null) =>
  value
    ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeZone: "UTC" }).format(
        new Date(`${value}T00:00:00Z`),
      )
    : "—";
const items = (segment: InvoiceBatchSegment) =>
  segment.invoice && segment.invoice.itemCount > 0
    ? segment.invoice.itemCount
    : segment.parsedItemCount;
const amount = (segment: InvoiceBatchSegment) => segment.invoice?.total ?? segment.parsedTotal;
const title = (segment: InvoiceBatchSegment) =>
  segment.kind === "invoice"
    ? `Invoice ${segment.invoiceNumber}`
    : segment.kind === "non_invoice"
      ? "Not an invoice"
      : "Unassigned pages";

function StatusBadge({ segment }: { segment: InvoiceBatchSegment }) {
  const status = batchRowStatus(segment);
  return <Badge className={cn("whitespace-nowrap", TONE[status])}>{BATCH_ROW_LABEL[status]}</Badge>;
}

function Detail({ segment }: { segment: InvoiceBatchSegment }) {
  const notes = [
    ...segment.reasons
      .filter((reason) => reason !== "DUPLICATE_IN_PACKET" || segment.status === "duplicate")
      .map(reasonText),
    ...(segment.status === "duplicate" && !segment.reasons.includes("DUPLICATE_IN_PACKET")
      ? ["This invoice is already in SportSpend."]
      : []),
    ...(segment.error ? [segment.error] : []),
  ];
  if (!notes.length) return null;
  return <p className="mt-1 text-xs text-muted-foreground">{notes.join(" ")}</p>;
}

function RowAction({
  segment,
  onRelease,
  busy,
}: {
  segment: InvoiceBatchSegment;
  onRelease: (segment: InvoiceBatchSegment) => void;
  busy: boolean;
}) {
  if (segment.status === "created" && segment.sourceFileId) {
    return (
      <Button size="sm" variant="outline" asChild>
        <Link to="/invoices/$invoiceId" params={{ invoiceId: segment.sourceFileId }}>
          Review
        </Link>
      </Button>
    );
  }
  if (segment.status === "duplicate" && segment.duplicateOfSourceFileId) {
    return (
      <Button size="sm" variant="ghost" asChild>
        <Link to="/invoices/$invoiceId" params={{ invoiceId: segment.duplicateOfSourceFileId }}>
          Open existing
        </Link>
      </Button>
    );
  }
  if (segment.status === "held") {
    return (
      <Button size="sm" variant="outline" disabled={busy} onClick={() => onRelease(segment)}>
        Create invoice
      </Button>
    );
  }
  return null;
}

export function InvoiceBatchPage({ batchId }: { batchId: string }) {
  const { active } = useActiveOrg();
  const organizationId = active?.organizationId;
  const owner = active?.role === "owner";
  const getBatch = useServerFn(getInvoiceBatchFn);
  const processBatch = useServerFn(processInvoiceBatchFn);
  const release = useServerFn(releaseInvoiceBatchSegmentFn);
  const queryClient = useQueryClient();
  const queryKey = ["invoice-batch", organizationId, batchId];
  const batch = useQuery({
    queryKey,
    queryFn: () => getBatch({ data: { organizationId: organizationId!, batchId } }),
    enabled: Boolean(organizationId && owner),
  });
  const running = useRef(false);
  const [processError, setProcessError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function run(retryFailed = false) {
    if (running.current || !organizationId) return;
    running.current = true;
    setProcessError(null);
    try {
      let current: InvoiceBatch | undefined = queryClient.getQueryData(queryKey);
      let retry = retryFailed;
      // A few invoices per request keeps every request small; each pass is safe to repeat.
      while (
        current &&
        (current.segments.some((segment) => segment.status === "pending") || retry)
      ) {
        current = await processBatch({
          data: { organizationId, batchId, limit: 4, retryFailed: retry },
        });
        retry = false;
        queryClient.setQueryData(queryKey, current);
      }
      await queryClient.invalidateQueries({ queryKey: ["vendor-invoices", organizationId] });
    } catch (error) {
      setProcessError(error instanceof Error ? error.message : "Preparing the invoices stopped.");
    } finally {
      running.current = false;
    }
  }

  const pending = batch.data?.segments.some((segment) => segment.status === "pending") ?? false;
  useEffect(() => {
    if (pending && !processError) void run();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pending, processError]);

  async function onRelease(segment: InvoiceBatchSegment) {
    if (!organizationId) return;
    setBusy(true);
    try {
      await release({ data: { organizationId, segmentId: segment.id } });
      await queryClient.invalidateQueries({ queryKey });
    } catch (error) {
      setProcessError(error instanceof Error ? error.message : "Could not create this invoice.");
    } finally {
      setBusy(false);
    }
  }

  if (!active) return null;
  if (!owner) {
    return (
      <div className="mx-auto max-w-3xl px-6 py-16">
        <Alert variant="destructive">
          <AlertCircle />
          <AlertTitle>Owner access required</AlertTitle>
          <AlertDescription>
            Only organization owners can upload or view vendor invoices.
          </AlertDescription>
        </Alert>
      </div>
    );
  }

  const data = batch.data;
  const counts = data ? batchCounts(data) : null;
  const prepared = data
    ? data.segments.filter((segment) => segment.kind === "invoice" && segment.status !== "pending")
        .length
    : 0;
  const failed = data?.segments.some((segment) => segment.status === "failed") ?? false;

  return (
    <div className="mx-auto max-w-6xl px-4 py-8 sm:px-8" data-page="invoice-batch">
      <Button variant="ghost" size="sm" className="-ml-2 mb-4" asChild>
        <Link to="/upload">
          <ArrowLeft className="mr-1 h-4 w-4" />
          Upload invoice
        </Link>
      </Button>
      <div className="mb-6">
        <p className="text-sm font-medium text-primary">Owner workspace</p>
        <h1 className="mt-1 text-2xl font-semibold tracking-tight sm:text-3xl">Invoice packet</h1>
        {data && (
          <p className="mt-2 flex min-w-0 items-center gap-2 text-sm text-muted-foreground">
            <FileStack className="h-4 w-4 shrink-0" />
            <span className="truncate">{data.originalFilename}</span>
          </p>
        )}
      </div>

      {batch.isLoading && (
        <div className="flex items-center gap-2 rounded-xl border bg-card p-5 text-sm">
          <Loader2 className="h-4 w-4 animate-spin" />
          Loading packet…
        </div>
      )}
      {batch.error && (
        <Alert variant="destructive">
          <AlertCircle />
          <AlertTitle>Could not load this packet</AlertTitle>
          <AlertDescription>{batch.error.message}</AlertDescription>
        </Alert>
      )}

      {data && counts && (
        <>
          <section className="mb-6 rounded-xl border bg-card p-5" aria-live="polite">
            <p className="text-lg font-semibold" data-testid="batch-detected">
              Detected {counts.invoices} invoice{counts.invoices === 1 ? "" : "s"} from{" "}
              {data.pageCount} pages
            </p>
            {data.vendorName && (
              <p className="mt-1 text-sm text-muted-foreground">{data.vendorName}</p>
            )}
            {counts.pending > 0 && (
              <div className="mt-4">
                <div className="mb-2 flex items-center gap-2 text-sm">
                  <Loader2 className="h-4 w-4 animate-spin" />
                  Preparing invoices… {prepared} of {counts.invoices}
                </div>
                <Progress value={counts.invoices ? (prepared / counts.invoices) * 100 : 0} />
              </div>
            )}
            <div className="mt-4 flex flex-wrap gap-2">
              {SUMMARY_ORDER.filter((status) => counts.byStatus[status] > 0).map((status) => (
                <Badge key={status} className={TONE[status]}>
                  {counts.byStatus[status]} {BATCH_ROW_LABEL[status].toLowerCase()}
                </Badge>
              ))}
            </div>
            <p className="mt-4 text-xs text-muted-foreground">
              Nothing is posted automatically. Open each invoice to review, match and approve it as
              usual.
            </p>
          </section>

          {processError && (
            <Alert variant="destructive" className="mb-5">
              <AlertCircle />
              <AlertTitle>Preparing stopped</AlertTitle>
              <AlertDescription className="flex flex-wrap items-center gap-3">
                {processError}
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => {
                    setProcessError(null);
                    void run();
                  }}
                >
                  Try again
                </Button>
              </AlertDescription>
            </Alert>
          )}
          {failed && !counts.pending && (
            <div className="mb-5 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-950">
              <span>Some invoices could not be prepared. The others are ready to use.</span>
              <Button size="sm" variant="outline" onClick={() => void run(true)}>
                <RotateCcw className="mr-1 h-4 w-4" />
                Retry failed
              </Button>
            </div>
          )}

          <div className="hidden overflow-hidden rounded-xl border bg-card md:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="pl-5">Invoice</TableHead>
                  <TableHead>Date</TableHead>
                  <TableHead>Pages</TableHead>
                  <TableHead className="text-right">Items</TableHead>
                  <TableHead className="text-right">Amount</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead className="pr-5 text-right">
                    <span className="sr-only">Action</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.segments.map((segment) => (
                  <TableRow key={segment.id} data-segment={segment.index}>
                    <TableCell className="max-w-xs pl-5 align-top">
                      <p className="font-medium">{title(segment)}</p>
                      <Detail segment={segment} />
                    </TableCell>
                    <TableCell className="align-top whitespace-nowrap">
                      {date(segment.invoiceDate)}
                    </TableCell>
                    <TableCell className="align-top whitespace-nowrap">
                      {pageRangeLabel(segment)}
                    </TableCell>
                    <TableCell className="align-top text-right">
                      {segment.kind === "invoice" ? (items(segment) ?? "—") : "—"}
                    </TableCell>
                    <TableCell className="align-top text-right whitespace-nowrap">
                      {segment.kind === "invoice" ? money(amount(segment)) : "—"}
                    </TableCell>
                    <TableCell className="align-top">
                      <StatusBadge segment={segment} />
                    </TableCell>
                    <TableCell className="pr-5 text-right align-top">
                      <RowAction segment={segment} onRelease={onRelease} busy={busy} />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>

          <ul className="space-y-3 md:hidden">
            {data.segments.map((segment) => (
              <li
                key={segment.id}
                className="rounded-xl border bg-card p-4"
                data-segment={segment.index}
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="font-medium">{title(segment)}</p>
                    <p className="mt-0.5 text-xs text-muted-foreground">
                      {pageRangeLabel(segment)}
                      {segment.invoiceDate ? ` · ${date(segment.invoiceDate)}` : ""}
                    </p>
                  </div>
                  <StatusBadge segment={segment} />
                </div>
                {segment.kind === "invoice" && (
                  <p className="mt-2 text-sm">
                    {items(segment) ?? "—"} item{items(segment) === 1 ? "" : "s"} ·{" "}
                    {money(amount(segment))}
                  </p>
                )}
                <Detail segment={segment} />
                <div className="mt-3 flex justify-end empty:hidden">
                  <RowAction segment={segment} onRelease={onRelease} busy={busy} />
                </div>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}

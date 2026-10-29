import { Link } from "@tanstack/react-router";
import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  correctionCountLabel,
  formatCorrectionSummary,
  formatCountDateTime,
} from "@/inventory/count-history";
import type { CountHistoryRow } from "@/types/inventory-workspace";

// Submitted physical counts, newest first. Read-only: count history is never edited.
// Phones get cards; from md up a dense table that scrolls inside its panel, never the page.
export function CountHistoryTable({
  rows,
  showLocation,
  emptyMessage,
}: {
  rows: CountHistoryRow[];
  showLocation: boolean;
  emptyMessage: string;
}) {
  if (!rows.length)
    return (
      <div
        className="rounded-xl border border-dashed bg-card px-6 py-12 text-center text-sm text-muted-foreground"
        data-testid="count-history-empty"
      >
        {emptyMessage}
      </div>
    );
  return (
    <div className="rounded-xl border bg-card" data-testid="count-history">
      <ul className="divide-y md:hidden" aria-label="Counts">
        {rows.map((row) => (
          <li key={row.sessionId} className="space-y-1 px-4 py-3">
            <div className="flex items-start justify-between gap-3">
              <SessionLink row={row} className="min-w-0 font-medium hover:underline">
                {formatCountDateTime(row.submittedAt)}
              </SessionLink>
              <CorrectionBadge changedCount={row.changedCount} />
            </div>
            <p className="break-words text-sm text-muted-foreground">
              {showLocation && (
                <>
                  {row.locationName}
                  {!row.locationActive && " (archived now)"} ·{" "}
                </>
              )}
              {row.countedByName} · {row.lineCount} line{row.lineCount === 1 ? "" : "s"}
            </p>
            {row.changedCount > 0 && (
              <p className="break-words text-sm tabular-nums">
                {formatCorrectionSummary(row.correctionSummary)}
              </p>
            )}
          </li>
        ))}
      </ul>
      <div
        className="hidden overflow-x-auto md:block"
        role="region"
        aria-label="Counts table"
        tabIndex={0}
      >
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Date / time</TableHead>
              {showLocation && <TableHead>Location</TableHead>}
              <TableHead>Counted by</TableHead>
              <TableHead className="text-right">Lines</TableHead>
              <TableHead>Corrections</TableHead>
              <TableHead>Correction summary</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.sessionId}>
                <TableCell className="whitespace-nowrap">
                  <SessionLink row={row} className="font-medium hover:underline">
                    {formatCountDateTime(row.submittedAt)}
                  </SessionLink>
                </TableCell>
                {showLocation && (
                  <TableCell>
                    <div className="flex flex-wrap items-center gap-2">
                      <span>{row.locationName}</span>
                      {!row.locationActive && <Badge variant="outline">Archived now</Badge>}
                    </div>
                  </TableCell>
                )}
                <TableCell>{row.countedByName}</TableCell>
                <TableCell className="text-right tabular-nums">{row.lineCount}</TableCell>
                <TableCell>
                  <CorrectionBadge changedCount={row.changedCount} />
                </TableCell>
                <TableCell className="text-sm tabular-nums">
                  {row.changedCount > 0 ? formatCorrectionSummary(row.correctionSummary) : "—"}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}

function SessionLink({
  row,
  className,
  children,
}: {
  row: CountHistoryRow;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <Link
      to="/inventory/counts/$sessionId"
      params={{ sessionId: row.sessionId }}
      className={className}
    >
      {children}
    </Link>
  );
}

export function CorrectionBadge({ changedCount }: { changedCount: number }) {
  return (
    <Badge variant={changedCount > 0 ? "secondary" : "outline"} className="whitespace-nowrap">
      {correctionCountLabel(changedCount)}
    </Badge>
  );
}

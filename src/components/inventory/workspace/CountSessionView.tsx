import { CheckCircle2 } from "lucide-react";
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
  COUNT_HISTORY_EXPLAINER,
  displayUnit,
  formatCorrectionSummary,
  formatCountDateTime,
  formatSignedQuantity,
  splitCountLines,
} from "@/inventory/count-history";
import { formatQuantity } from "@/inventory/locations";
import type { CountSessionDetail, CountSessionLine } from "@/types/inventory-workspace";
import { CorrectionBadge } from "./CountHistoryTable";

// One submitted count, read-only. Recorded is what SportSpend held before the count,
// Counted is what was on hand, Correction is the difference. Item name, SKU and unit are as
// they were at count time; "Archived now" is today's state only.
export function CountSessionView({ session }: { session: CountSessionDetail }) {
  const { changed, unchanged } = splitCountLines(session.lines);
  return (
    <div className="space-y-6" data-testid="count-session">
      <header className="space-y-4">
        <div className="flex flex-wrap items-center gap-2">
          <h1 className="break-words text-3xl font-semibold tracking-tight">
            {session.locationName}
          </h1>
          {!session.locationActive && <Badge variant="outline">Location archived now</Badge>}
          <CorrectionBadge changedCount={session.changedCount} />
        </div>
        <p className="max-w-3xl text-sm text-muted-foreground">{COUNT_HISTORY_EXPLAINER}</p>
        <dl className="grid gap-3 rounded-xl border bg-card p-4 text-sm sm:grid-cols-2 lg:grid-cols-5">
          <Fact label="Submitted">{formatCountDateTime(session.submittedAt)}</Fact>
          <Fact label="Counted by">{session.countedByName}</Fact>
          <Fact label="Lines counted">{session.lineCount}</Fact>
          <Fact label="Count corrections">{session.changedCount}</Fact>
          <Fact label="Correction by unit">
            {formatCorrectionSummary(session.correctionSummary)}
          </Fact>
        </dl>
      </header>

      <section aria-labelledby="count-corrections" className="space-y-2">
        <h2 id="count-corrections" className="text-lg font-semibold">
          Corrections
        </h2>
        {changed.length ? (
          <>
            <p className="text-sm text-muted-foreground">
              {changed.length} item{changed.length === 1 ? "" : "s"} changed
            </p>
            <CountLines lines={changed} label="Corrections" />
          </>
        ) : (
          <div
            className="flex items-center gap-2 rounded-xl border bg-card px-4 py-3 text-sm"
            data-testid="no-corrections"
          >
            <CheckCircle2 className="h-4 w-4 text-primary" />
            No corrections were needed. Every counted quantity matched the recorded quantity.
          </div>
        )}
      </section>

      {unchanged.length > 0 && (
        <section aria-labelledby="count-no-change">
          <details open={changed.length === 0} className="space-y-2">
            <summary className="cursor-pointer text-lg font-semibold" id="count-no-change">
              No change
              <span className="ml-2 text-sm font-normal text-muted-foreground">
                {unchanged.length} item{unchanged.length === 1 ? "" : "s"} matched the recorded
                quantity
              </span>
            </summary>
            <div className="mt-2">
              <CountLines lines={unchanged} label="No change" />
            </div>
          </details>
        </section>
      )}
    </div>
  );
}

function CountLines({ lines, label }: { lines: CountSessionLine[]; label: string }) {
  return (
    <div className="rounded-xl border bg-card">
      <ul className="divide-y md:hidden" aria-label={label}>
        {lines.map((line) => (
          <li key={line.inventoryItemId} className="space-y-1 px-4 py-3">
            <ItemName line={line} />
            <p className="text-xs text-muted-foreground">
              {line.sku ? `${line.sku} · ` : ""}
              {displayUnit(line.unit)}
            </p>
            <p className="text-sm tabular-nums">
              Recorded {formatQuantity(line.previousQuantity)} · Counted{" "}
              {formatQuantity(line.countedQuantity)} · Correction{" "}
              <span className="font-semibold">{formatSignedQuantity(line.delta)}</span>
            </p>
          </li>
        ))}
      </ul>
      <div
        className="hidden overflow-x-auto md:block"
        role="region"
        aria-label={`${label} table`}
        tabIndex={0}
      >
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Item</TableHead>
              <TableHead>SKU</TableHead>
              <TableHead>Unit</TableHead>
              <TableHead className="text-right">Recorded</TableHead>
              <TableHead className="text-right">Counted</TableHead>
              <TableHead className="text-right">Correction</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {lines.map((line) => (
              <TableRow key={line.inventoryItemId}>
                <TableCell>
                  <ItemName line={line} />
                </TableCell>
                <TableCell className="whitespace-nowrap font-mono text-xs">
                  {line.sku || "—"}
                </TableCell>
                <TableCell>{displayUnit(line.unit)}</TableCell>
                <TableCell className="text-right tabular-nums">
                  {formatQuantity(line.previousQuantity)}
                </TableCell>
                <TableCell className="text-right tabular-nums">
                  {formatQuantity(line.countedQuantity)}
                </TableCell>
                <TableCell className="text-right font-semibold tabular-nums">
                  {formatSignedQuantity(line.delta)}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}

function ItemName({ line }: { line: CountSessionLine }) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      <span className="break-words font-medium">{line.name}</span>
      {line.itemArchivedNow && <Badge variant="outline">Archived now</Badge>}
    </div>
  );
}

function Fact({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="break-words font-medium tabular-nums">{children}</dd>
    </div>
  );
}

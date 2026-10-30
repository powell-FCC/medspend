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
  adjustmentLocationLabel,
  adjustmentReasonLabel,
  formatActivityQuantity,
  formatAdjustmentAmount,
  transferDirection,
  transferRouteLabel,
} from "@/inventory/activity";
import { formatQuantity } from "@/inventory/locations";
import { displayUnit, formatCountDateTime } from "@/inventory/count-history";
import type { AdjustmentHistoryRow, TransferHistoryRow } from "@/types/inventory-workspace";

// Read-only history. Phones get cards; from md up a dense table that scrolls inside its
// panel, never the page.

function EmptyHistory({ message, testId }: { message: string; testId: string }) {
  return (
    <div
      className="rounded-xl border border-dashed bg-card px-6 py-12 text-center text-sm text-muted-foreground"
      data-testid={testId}
    >
      {message}
    </div>
  );
}

function ItemLabel({ name, sku }: { name: string; sku: string | null }) {
  return (
    <>
      <span className="font-medium">{name}</span>
      {sku && <span className="text-muted-foreground"> · {sku}</span>}
    </>
  );
}

function DirectionBadge({ direction }: { direction: "out" | "in" | null }) {
  if (!direction) return null;
  return (
    <Badge variant={direction === "out" ? "outline" : "secondary"} className="whitespace-nowrap">
      {direction === "out" ? "OUT" : "IN"}
    </Badge>
  );
}

export function TransferHistoryTable({
  rows,
  locationId,
  emptyMessage,
}: {
  rows: TransferHistoryRow[];
  // Set on a location's Activity: each move is shown as out of or into that location.
  locationId?: string;
  emptyMessage: string;
}) {
  if (!rows.length) return <EmptyHistory message={emptyMessage} testId="transfer-history-empty" />;
  return (
    <div className="rounded-xl border bg-card" data-testid="transfer-history">
      <ul className="divide-y md:hidden" aria-label="Transfers">
        {rows.map((row) => (
          <li key={row.transferId} className="space-y-1 px-4 py-3">
            <div className="flex items-start justify-between gap-3">
              <p className="min-w-0 break-words">
                <ItemLabel name={row.itemName} sku={row.itemSku} />
              </p>
              <span className="whitespace-nowrap text-sm font-medium tabular-nums">
                {formatActivityQuantity(row.quantity, row.itemUnit)}
              </span>
            </div>
            <p className="flex flex-wrap items-center gap-2 break-words text-sm">
              {locationId && <DirectionBadge direction={transferDirection(row, locationId)} />}
              <span className="min-w-0 break-words">{transferRouteLabel(row)}</span>
            </p>
            <p className="break-words text-sm text-muted-foreground">
              {formatCountDateTime(row.createdAt)} · {row.createdByName}
            </p>
          </li>
        ))}
      </ul>
      <div
        className="hidden overflow-x-auto md:block"
        role="region"
        aria-label="Transfers table"
        tabIndex={0}
      >
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Date / time</TableHead>
              {locationId && <TableHead>Direction</TableHead>}
              <TableHead>Item</TableHead>
              <TableHead>From</TableHead>
              <TableHead>To</TableHead>
              <TableHead className="text-right">Quantity</TableHead>
              <TableHead>Moved by</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.transferId}>
                <TableCell className="whitespace-nowrap">
                  {formatCountDateTime(row.createdAt)}
                </TableCell>
                {locationId && (
                  <TableCell>
                    <DirectionBadge direction={transferDirection(row, locationId)} />
                  </TableCell>
                )}
                <TableCell>
                  <ItemLabel name={row.itemName} sku={row.itemSku} />
                </TableCell>
                <TableCell>{row.fromLocationName}</TableCell>
                <TableCell>{row.toLocationName}</TableCell>
                <TableCell className="whitespace-nowrap text-right tabular-nums">
                  {formatActivityQuantity(row.quantity, row.itemUnit)}
                </TableCell>
                <TableCell>{row.createdByName}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}

export function AdjustmentHistoryTable({
  rows,
  showLocation,
  emptyMessage,
}: {
  rows: AdjustmentHistoryRow[];
  showLocation: boolean;
  emptyMessage: string;
}) {
  if (!rows.length)
    return <EmptyHistory message={emptyMessage} testId="adjustment-history-empty" />;
  return (
    <div className="rounded-xl border bg-card" data-testid="adjustment-history">
      <ul className="divide-y md:hidden" aria-label="Adjustments">
        {rows.map((row) => (
          <li key={row.adjustmentId} className="space-y-1 px-4 py-3">
            <div className="flex items-start justify-between gap-3">
              <p className="min-w-0 break-words">
                <ItemLabel name={row.itemName} sku={row.itemSku} />
              </p>
              <span className="whitespace-nowrap text-sm font-medium tabular-nums">
                {formatAdjustmentAmount(row.adjustmentAmount)} {displayUnit(row.itemUnit)}
              </span>
            </div>
            {showLocation && (
              <p className="break-words text-sm">{adjustmentLocationLabel(row.locationName)}</p>
            )}
            <p className="text-sm tabular-nums text-muted-foreground">
              Total {formatQuantity(row.previousQuantity)} → {formatQuantity(row.newQuantity)} ·{" "}
              {adjustmentReasonLabel(row.reason)}
            </p>
            <p className="break-words text-sm text-muted-foreground">
              {formatCountDateTime(row.createdAt)} · {row.createdByName}
            </p>
          </li>
        ))}
      </ul>
      <div
        className="hidden overflow-x-auto md:block"
        role="region"
        aria-label="Adjustments table"
        tabIndex={0}
      >
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Date / time</TableHead>
              <TableHead>Item</TableHead>
              {showLocation && <TableHead>Location</TableHead>}
              <TableHead className="text-right">Total before</TableHead>
              <TableHead className="text-right">Adjustment</TableHead>
              <TableHead className="text-right">Total after</TableHead>
              <TableHead>Reason</TableHead>
              <TableHead>Adjusted by</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.adjustmentId}>
                <TableCell className="whitespace-nowrap">
                  {formatCountDateTime(row.createdAt)}
                </TableCell>
                <TableCell>
                  <ItemLabel name={row.itemName} sku={row.itemSku} />
                </TableCell>
                {showLocation && (
                  <TableCell
                    className={row.locationName ? undefined : "text-sm text-muted-foreground"}
                  >
                    {adjustmentLocationLabel(row.locationName)}
                  </TableCell>
                )}
                <TableCell className="text-right tabular-nums">
                  {formatQuantity(row.previousQuantity)}
                </TableCell>
                <TableCell className="whitespace-nowrap text-right font-medium tabular-nums">
                  {formatAdjustmentAmount(row.adjustmentAmount)} {displayUnit(row.itemUnit)}
                </TableCell>
                <TableCell className="text-right tabular-nums">
                  {formatQuantity(row.newQuantity)}
                </TableCell>
                <TableCell>{adjustmentReasonLabel(row.reason)}</TableCell>
                <TableCell>{row.createdByName}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}

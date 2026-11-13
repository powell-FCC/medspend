import { AlertTriangle, ArrowRight } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { formatQuantity } from "@/inventory/locations";
import {
  NOT_STOCKED_HERE_TEXT,
  countCadenceWarning,
  donorContext,
  lastCountedText,
  nextMovePrefill,
  openRequestText,
  otherShortText,
  recommendationText,
  replenishmentCategoryLabel,
  replenishmentInactiveReasonLabel,
  shortageText,
} from "@/inventory/replenishment";
import type { ReplenishmentMovePrefill, ReplenishmentRow } from "@/types/inventory-replenishment";

const categoryTone: Record<ReplenishmentRow["category"], string> = {
  move_available: "bg-sky-100 text-sky-900 hover:bg-sky-100",
  partly_covered: "bg-amber-100 text-amber-900 hover:bg-amber-100",
  needs_purchasing: "bg-red-100 text-red-900 hover:bg-red-100",
  ok: "bg-emerald-100 text-emerald-900 hover:bg-emerald-100",
  inactive: "bg-muted text-muted-foreground hover:bg-muted",
};

export interface ReplenishmentRowActions {
  onMove?: (row: ReplenishmentRow, prefill: ReplenishmentMovePrefill) => void;
  onEdit?: (row: ReplenishmentRow) => void;
  onToggleEnabled?: (row: ReplenishmentRow) => void;
}

// One rule: where it stands and what the owner could do. Quantities are in the item's own unit;
// external purchasing is information only.
export function ReplenishmentRowCard({
  row,
  canManage,
  showLocation = true,
  now,
  onMove,
  onEdit,
  onToggleEnabled,
}: {
  row: ReplenishmentRow;
  canManage: boolean;
  showLocation?: boolean;
  now?: Date;
} & ReplenishmentRowActions) {
  const shortage = shortageText(row);
  const recommendation = recommendationText(row);
  const prefill = nextMovePrefill(row);
  const cadence = countCadenceWarning(row);
  const requests = openRequestText(row);
  const otherShort = otherShortText(row);
  const inactive = row.category === "inactive";
  return (
    <li
      className="space-y-2 px-4 py-3"
      data-testid="replenishment-row"
      data-category={row.category}
    >
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="break-words font-medium">{row.itemName}</p>
          {showLocation && (
            <p className="break-words text-sm text-muted-foreground">{row.locationName}</p>
          )}
        </div>
        <Badge className={categoryTone[row.category]}>
          {inactive && row.inactiveReason
            ? replenishmentInactiveReasonLabel[row.inactiveReason]
            : replenishmentCategoryLabel[row.category]}
        </Badge>
      </div>
      <p className="flex flex-wrap gap-x-4 gap-y-1 text-sm tabular-nums">
        <span>
          Current{" "}
          <span className="font-semibold">
            {formatQuantity(row.currentQuantity)} {row.itemUnit}
          </span>
        </span>
        <span>Minimum {formatQuantity(row.minimumQuantity)}</span>
        <span>Target {formatQuantity(row.targetQuantity)}</span>
        {shortage && <span className="font-semibold">{shortage}</span>}
      </p>
      {!inactive && row.notStockedHere && (
        <p className="text-xs text-muted-foreground">{NOT_STOCKED_HERE_TEXT}</p>
      )}
      {!inactive && recommendation && (
        <p
          className="flex items-start gap-1.5 text-sm font-medium"
          data-testid="replenishment-recommendation"
        >
          <ArrowRight className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
          <span className="break-words">{recommendation}</span>
        </p>
      )}
      {!inactive && row.donors.length > 0 && (
        <ul className="space-y-0.5 text-xs text-muted-foreground" aria-label="Stock elsewhere">
          {donorContext(row).map((line) => (
            <li key={line}>{line}</li>
          ))}
        </ul>
      )}
      <p className="flex flex-wrap gap-x-3 gap-y-1 text-xs text-muted-foreground">
        <span>{lastCountedText(row, now)}</span>
        {requests && <span>{requests}</span>}
        {otherShort && <span>{otherShort}</span>}
      </p>
      {cadence && (
        <p className="flex items-center gap-1.5 text-xs text-amber-800">
          <AlertTriangle className="h-3.5 w-3.5" aria-hidden />
          {cadence}
        </p>
      )}
      {canManage && (
        <div className="flex flex-wrap gap-2 pt-1">
          {prefill && onMove && (
            <Button size="sm" onClick={() => onMove(row, prefill)}>
              Move stock
            </Button>
          )}
          {onEdit && row.itemActive && row.locationActive && (
            <Button size="sm" variant="outline" onClick={() => onEdit(row)}>
              Edit
            </Button>
          )}
          {onToggleEnabled && (row.enabled || (row.itemActive && row.locationActive)) && (
            <Button size="sm" variant="ghost" onClick={() => onToggleEnabled(row)}>
              {row.enabled ? "Turn off" : "Turn on"}
            </Button>
          )}
        </div>
      )}
    </li>
  );
}

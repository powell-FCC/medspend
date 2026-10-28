import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { formatQuantity } from "@/inventory/locations";
import { inventoryStatusLabel } from "@/inventory/status";
import { formatWorkspaceDate } from "@/inventory/workspace";
import type { InventoryItemRef } from "@/types/inventory";
import type { WorkspaceLocation, WorkspaceStockRow } from "@/types/inventory-workspace";
import { inventoryStatusTones } from "../status-tones";

export type StockRowAction = { kind: "move" | "adjust"; item: InventoryItemRef };

// Stock at one location. Par and status belong to the item across the whole organization;
// SportSpend has no par per location, so nothing here calls this location low on stock.
export function LocationStockTable({
  location,
  rows,
  canManage,
  onAction,
}: {
  location: WorkspaceLocation;
  rows: WorkspaceStockRow[];
  canManage: boolean;
  onAction?: (action: StockRowAction) => void;
}) {
  const storage = location.kind === "storage";
  if (!rows.length)
    return (
      <div className="rounded-xl border border-dashed bg-card px-6 py-12 text-center text-sm text-muted-foreground">
        {storage ? "No items are stocked here yet." : "Nothing is waiting in Unassigned."}
      </div>
    );
  return (
    <div className="space-y-2">
      <p className="text-xs text-muted-foreground" data-testid="org-par-note">
        Par and status are organization-wide: the item's total across every location against its
        organization par. They are not a threshold for this location.
      </p>
      <div className="overflow-x-auto rounded-xl border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Item</TableHead>
              <TableHead>SKU</TableHead>
              <TableHead className="text-right">Quantity here</TableHead>
              <TableHead>Unit</TableHead>
              <TableHead>Organization par</TableHead>
              <TableHead>Organization status</TableHead>
              {storage && <TableHead>Last counted here</TableHead>}
              {canManage && (
                <TableHead>
                  <span className="sr-only">Actions</span>
                </TableHead>
              )}
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={row.inventoryItemId}>
                <TableCell>
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">{row.name}</span>
                    {!row.itemActive && <Badge variant="outline">Archived item</Badge>}
                  </div>
                </TableCell>
                <TableCell className="font-mono text-xs">{row.sku || "—"}</TableCell>
                <TableCell className="text-right font-semibold tabular-nums">
                  {formatQuantity(row.quantity)}
                </TableCell>
                <TableCell>{row.unit}</TableCell>
                <TableCell className="tabular-nums">
                  {row.organizationParLevel === null
                    ? "—"
                    : formatQuantity(row.organizationParLevel)}
                </TableCell>
                <TableCell>
                  <Badge className={inventoryStatusTones[row.organizationStockStatus]}>
                    {inventoryStatusLabel[row.organizationStockStatus]}
                  </Badge>
                </TableCell>
                {storage && (
                  <TableCell className="text-sm">
                    {row.lastCountedAt ? formatWorkspaceDate(row.lastCountedAt) : "Not counted yet"}
                  </TableCell>
                )}
                {canManage && (
                  <TableCell>
                    <div className="flex justify-end gap-1">
                      {(() => {
                        const item = {
                          id: row.inventoryItemId,
                          name: row.name,
                          unit: row.unit,
                          quantity: row.organizationQuantity,
                        };
                        return (
                          <>
                            <Button
                              size="sm"
                              variant="ghost"
                              aria-label={`Move ${row.name}`}
                              onClick={() => onAction?.({ kind: "move", item })}
                            >
                              Move
                            </Button>
                            <Button
                              size="sm"
                              variant="ghost"
                              aria-label={`Adjust ${row.name}`}
                              onClick={() => onAction?.({ kind: "adjust", item })}
                            >
                              Adjust
                            </Button>
                          </>
                        );
                      })()}
                    </div>
                  </TableCell>
                )}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}

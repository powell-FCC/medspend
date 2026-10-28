import { MoreHorizontal } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { inventoryStatusLabel } from "@/inventory/status";
import { formatQuantity } from "@/inventory/locations";
import { stockPlacementLabel } from "@/inventory/workspace";
import type { WorkspaceItem } from "@/types/inventory-workspace";
import { inventoryStatusTones } from "./status-tones";

// Items with their organization quantity and where it is. Owners get the row actions;
// admins (canManage false) get the same rows with none.
export function InventoryTable({
  items,
  canManage,
  onEdit,
  onArchive,
  onAdjust,
  onLocations,
}: {
  items: WorkspaceItem[];
  canManage: boolean;
  onEdit?: (item: WorkspaceItem) => void;
  onArchive?: (item: WorkspaceItem) => void;
  onAdjust?: (item: WorkspaceItem) => void;
  onLocations?: (item: WorkspaceItem) => void;
}) {
  if (!items.length)
    return (
      <div className="rounded-xl border border-dashed bg-card px-6 py-16 text-center">
        <p className="font-medium">No inventory items found</p>
        <p className="mt-1 text-sm text-muted-foreground">
          {canManage ? "Add an item or adjust the filters." : "Adjust the filters."}
        </p>
      </div>
    );
  return (
    <div className="overflow-x-auto rounded-xl border bg-card">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Item</TableHead>
            <TableHead>SKU</TableHead>
            <TableHead>Category</TableHead>
            <TableHead>Vendor</TableHead>
            <TableHead>Quantity</TableHead>
            <TableHead>Unit</TableHead>
            <TableHead>Par Level</TableHead>
            <TableHead>Status</TableHead>
            {canManage && (
              <TableHead className="w-12">
                <span className="sr-only">Actions</span>
              </TableHead>
            )}
          </TableRow>
        </TableHeader>
        <TableBody>
          {items.map((item) => {
            const placement = (
              <>
                <span className="block font-semibold tabular-nums">
                  {formatQuantity(item.quantity)}
                </span>
                <span className="block text-xs text-muted-foreground underline-offset-2 hover:underline">
                  {stockPlacementLabel(item)}
                </span>
              </>
            );
            return (
              <TableRow key={item.id}>
                <TableCell>
                  <div className="font-medium">{item.name}</div>
                  {item.manufacturer && (
                    <div className="text-xs text-muted-foreground">{item.manufacturer}</div>
                  )}
                </TableCell>
                <TableCell className="font-mono text-xs">{item.sku || "—"}</TableCell>
                <TableCell>{item.category || "—"}</TableCell>
                <TableCell>{item.vendorName || "—"}</TableCell>
                <TableCell>
                  {canManage && onLocations ? (
                    <button
                      type="button"
                      className="text-left"
                      onClick={() => onLocations(item)}
                      aria-label={`Stock locations for ${item.name}`}
                    >
                      {placement}
                    </button>
                  ) : (
                    <div>{placement}</div>
                  )}
                </TableCell>
                <TableCell>{item.unit}</TableCell>
                <TableCell>
                  {item.parLevel === null ? "—" : formatQuantity(item.parLevel)}
                </TableCell>
                <TableCell>
                  <Badge className={inventoryStatusTones[item.stockStatus]}>
                    {inventoryStatusLabel[item.stockStatus]}
                  </Badge>
                </TableCell>
                {canManage && (
                  <TableCell>
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild>
                        <Button size="icon" variant="ghost" aria-label={`Actions for ${item.name}`}>
                          <MoreHorizontal className="h-4 w-4" />
                        </Button>
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end">
                        <DropdownMenuItem onClick={() => onEdit?.(item)}>Edit</DropdownMenuItem>
                        <DropdownMenuItem onClick={() => onLocations?.(item)}>
                          Locations &amp; move stock
                        </DropdownMenuItem>
                        <DropdownMenuItem onClick={() => onAdjust?.(item)}>
                          Adjust quantity
                        </DropdownMenuItem>
                        <DropdownMenuItem onClick={() => onArchive?.(item)}>
                          {item.active ? "Archive" : "Restore"}
                        </DropdownMenuItem>
                      </DropdownMenuContent>
                    </DropdownMenu>
                  </TableCell>
                )}
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </div>
  );
}

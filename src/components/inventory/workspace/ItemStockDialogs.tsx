import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { adjustInventoryQuantityFn, moveInventoryStockFn } from "@/lib/inventory.functions";
import {
  getWorkspaceItemBalancesFn,
  listWorkspaceLocationsFn,
} from "@/lib/inventory-workspace.functions";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { workspaceQueryKey } from "@/inventory/workspace";
import type { InventoryItemRef, LocationAdjustmentReason } from "@/types/inventory";
import { ItemLocationsDialog } from "../ItemLocationsDialog";
import { QuantityAdjustmentDialog } from "../QuantityAdjustmentDialog";

export type ItemStockAction = { kind: "move" | "adjust"; item: InventoryItemRef };

// The owner's Move and Adjust dialogs for one item. They read every location and only this
// item's balances, so they never depend on loading the organization's whole balance set.
// Owner only: the workspace renders this only when canManage.
export function ItemStockDialogs({
  organizationId,
  action,
  onClose,
}: {
  organizationId: string;
  action?: ItemStockAction;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const listLocations = useServerFn(listWorkspaceLocationsFn);
  const getBalances = useServerFn(getWorkspaceItemBalancesFn);
  const move = useServerFn(moveInventoryStockFn);
  const adjust = useServerFn(adjustInventoryQuantityFn);
  const itemId = action?.item.id;
  const locations = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "locations", "all"],
    queryFn: () => listLocations({ data: { organizationId, status: "all" } }),
    enabled: Boolean(action),
  });
  const balances = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "item-balances", itemId],
    queryFn: () => getBalances({ data: { organizationId, inventoryItemId: itemId! } }),
    enabled: Boolean(itemId),
  });
  const ready = Boolean(action && locations.data && balances.data);
  const item =
    action && balances.data ? { ...action.item, quantity: balances.data.quantity } : undefined;
  const refresh = () =>
    queryClient.invalidateQueries({ queryKey: workspaceQueryKey(organizationId) });

  const loadError = locations.error ?? balances.error;

  return (
    <>
      <Dialog open={Boolean(action && loadError)} onOpenChange={(open) => !open && onClose()}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>Could not load stock for {action?.item.name}</DialogTitle>
            <DialogDescription role="alert">
              {loadError instanceof Error ? loadError.message : "Try again."}
            </DialogDescription>
          </DialogHeader>
        </DialogContent>
      </Dialog>
      <ItemLocationsDialog
        item={ready && action?.kind === "move" ? item : undefined}
        locations={locations.data?.locations ?? []}
        balances={balances.data?.balances ?? []}
        onOpenChange={(open) => !open && onClose()}
        onMove={async (input) => {
          if (!itemId) return;
          await move({
            data: {
              organizationId,
              inventoryItemId: itemId,
              fromInventoryLocationId: input.fromId,
              toInventoryLocationId: input.toId,
              quantity: input.quantity,
              requestKey: input.requestKey,
            },
          });
          await refresh();
        }}
      />
      <QuantityAdjustmentDialog
        item={ready && action?.kind === "adjust" ? item : undefined}
        locations={locations.data?.locations ?? []}
        balances={balances.data?.balances ?? []}
        onOpenChange={(open) => !open && onClose()}
        onAdjust={async (
          inventoryLocationId: string,
          amount: number,
          reason: LocationAdjustmentReason,
        ) => {
          if (!itemId) return;
          await adjust({
            data: { organizationId, inventoryItemId: itemId, inventoryLocationId, amount, reason },
          });
          await refresh();
        }}
      />
    </>
  );
}

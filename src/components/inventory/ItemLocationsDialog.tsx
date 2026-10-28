import { useEffect, useMemo, useState } from "react";
import { ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  formatQuantity,
  itemLocationBreakdown,
  reconcileMoveSource,
  sortInventoryLocations,
  validateMove,
} from "@/inventory/locations";
import type {
  InventoryItemRef,
  InventoryLocationBalance,
  InventoryLocationRef,
} from "@/types/inventory";

export interface MoveStockInput {
  fromId: string;
  toId: string;
  quantity: number;
  requestKey: string;
}

const newRequestKey = () =>
  typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `move-${Date.now()}-${Math.random().toString(36).slice(2)}`;

// Where one item's stock is, and a single explicit move between two locations.
export function ItemLocationsDialog({
  item,
  locations,
  balances,
  onOpenChange,
  onMove,
}: {
  item?: InventoryItemRef;
  locations: InventoryLocationRef[];
  balances: InventoryLocationBalance[];
  onOpenChange: (open: boolean) => void;
  onMove: (input: MoveStockInput) => Promise<void>;
}) {
  const [fromId, setFromId] = useState("");
  const [toId, setToId] = useState("");
  const [quantity, setQuantity] = useState("");
  const [requestKey, setRequestKey] = useState(newRequestKey);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const breakdown = useMemo(
    () => (item ? itemLocationBreakdown(item.id, locations, balances) : []),
    [item, locations, balances],
  );
  const available = (id: string) =>
    item
      ? (balances.find(
          (balance) => balance.inventoryItemId === item.id && balance.inventoryLocationId === id,
        )?.quantity ?? 0)
      : 0;
  const sources = breakdown.filter((entry) => entry.quantity > 0).map((entry) => entry.location);
  const destinations = sortInventoryLocations(
    locations.filter((location) => location.active && location.id !== fromId),
  );

  // Balances refresh after every move; keep the form's source on a location that still has
  // stock (reopening the dialog used to be the only fix).
  const sourceIds = sources.map((location) => location.id).join(",");
  useEffect(() => {
    if (!item) return;
    const next = reconcileMoveSource({ fromId, toId }, sourceIds ? sourceIds.split(",") : []);
    if (next.fromId !== fromId) {
      setFromId(next.fromId);
      setToId(next.toId);
    }
  }, [item, sourceIds, fromId, toId]);

  useEffect(() => {
    if (!item) return;
    const firstSource = breakdown.find((entry) => entry.quantity > 0)?.location.id ?? "";
    setFromId(firstSource);
    setToId("");
    setQuantity("");
    setError("");
    setNotice("");
    setRequestKey(newRequestKey());
    // Reset only when a different item opens; balance refreshes keep the form.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item?.id]);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (saving || !item) return;
    const amount = Number(quantity);
    const problem = validateMove({ fromId, toId, quantity: amount, available: available(fromId) });
    if (problem) {
      setError(problem);
      return;
    }
    setSaving(true);
    setError("");
    setNotice("");
    try {
      await onMove({ fromId, toId, quantity: amount, requestKey });
      const from = locations.find((location) => location.id === fromId)?.name;
      const to = locations.find((location) => location.id === toId)?.name;
      setNotice(`Moved ${formatQuantity(amount)} ${item.unit} from ${from} to ${to}.`);
      setQuantity("");
      setRequestKey(newRequestKey());
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not move stock.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Dialog open={Boolean(item)} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[92dvh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle className="break-words">{item?.name}</DialogTitle>
          <DialogDescription>
            Total on hand:{" "}
            <span className="font-semibold text-foreground tabular-nums">
              {item ? formatQuantity(item.quantity) : 0} {item?.unit}
            </span>{" "}
            across all locations.
          </DialogDescription>
        </DialogHeader>
        <section aria-label="Stock by location">
          <ul className="divide-y rounded-lg border" data-section="item-location-breakdown">
            {breakdown.map(({ location, quantity: held }) => (
              <li
                key={location.id}
                className="flex items-center justify-between gap-3 px-3 py-2.5 text-sm"
              >
                <span className="min-w-0 break-words">
                  {location.name}
                  {location.kind === "unassigned" && (
                    <span className="ml-1 text-xs text-muted-foreground">(not yet placed)</span>
                  )}
                  {!location.active && (
                    <span className="ml-1 text-xs text-muted-foreground">(archived)</span>
                  )}
                </span>
                <span className="shrink-0 font-semibold tabular-nums">
                  {formatQuantity(held)} {item?.unit}
                </span>
              </li>
            ))}
          </ul>
        </section>
        <form onSubmit={submit} className="space-y-4 border-t pt-4" aria-label="Move stock">
          <h3 className="font-medium">Move stock</h3>
          {sources.length === 0 ? (
            <p className="text-sm text-muted-foreground">This item has no stock to move.</p>
          ) : (
            <>
              <div className="grid gap-3 sm:grid-cols-[1fr_auto_1fr] sm:items-end">
                <div>
                  <Label htmlFor="move-from" className="mb-2 block">
                    From
                  </Label>
                  <select
                    id="move-from"
                    className="h-11 w-full rounded-md border bg-background px-3 text-sm"
                    value={fromId}
                    onChange={(e) => {
                      setFromId(e.target.value);
                      if (e.target.value === toId) setToId("");
                    }}
                  >
                    {sources.map((location) => (
                      <option key={location.id} value={location.id}>
                        {location.name} ({formatQuantity(available(location.id))})
                      </option>
                    ))}
                  </select>
                </div>
                <ArrowRight
                  className="mx-auto hidden h-4 w-4 text-muted-foreground sm:mb-3.5 sm:block"
                  aria-hidden
                />
                <div>
                  <Label htmlFor="move-to" className="mb-2 block">
                    To
                  </Label>
                  <select
                    id="move-to"
                    className="h-11 w-full rounded-md border bg-background px-3 text-sm"
                    value={toId}
                    onChange={(e) => setToId(e.target.value)}
                    required
                  >
                    <option value="">Choose a location</option>
                    {destinations.map((location) => (
                      <option key={location.id} value={location.id}>
                        {location.name}
                      </option>
                    ))}
                  </select>
                </div>
              </div>
              {destinations.filter((location) => location.kind !== "unassigned").length === 0 && (
                <p className="text-xs text-muted-foreground">
                  Add an inventory location first to place this stock somewhere physical.
                </p>
              )}
              <div>
                <Label htmlFor="move-quantity" className="mb-2 block">
                  Quantity ({item?.unit})
                </Label>
                <div className="flex gap-2">
                  <Input
                    id="move-quantity"
                    type="number"
                    inputMode="decimal"
                    min="0"
                    step="any"
                    className="h-11"
                    value={quantity}
                    onChange={(e) => setQuantity(e.target.value)}
                    required
                  />
                  <Button
                    type="button"
                    variant="outline"
                    className="h-11 shrink-0"
                    onClick={() => setQuantity(String(available(fromId)))}
                  >
                    All {formatQuantity(available(fromId))}
                  </Button>
                </div>
              </div>
            </>
          )}
          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}
          {notice && (
            <p role="status" className="text-sm text-emerald-700 dark:text-emerald-400">
              {notice}
            </p>
          )}
          <DialogFooter className="gap-2">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Done
            </Button>
            {sources.length > 0 && (
              <Button disabled={saving || !toId || !quantity}>
                {saving ? "Moving…" : "Move stock"}
              </Button>
            )}
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

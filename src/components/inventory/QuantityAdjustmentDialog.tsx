import { useEffect, useState } from "react";
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
  sortInventoryLocations,
  validateLocationAdjustment,
} from "@/inventory/locations";
import { locationAdjustmentReasons } from "@/types/inventory";
import type {
  InventoryItemRef,
  InventoryLocationBalance,
  InventoryLocationRef,
  LocationAdjustmentReason,
} from "@/types/inventory";

// An adjustment changes one location's stock and the organization total by the same amount.
// It never borrows from another location.
export function QuantityAdjustmentDialog({
  item,
  locations,
  balances,
  onOpenChange,
  onAdjust,
}: {
  item?: InventoryItemRef;
  locations: InventoryLocationRef[];
  balances: InventoryLocationBalance[];
  onOpenChange: (open: boolean) => void;
  onAdjust: (locationId: string, amount: number, reason: LocationAdjustmentReason) => Promise<void>;
}) {
  const [amount, setAmount] = useState("");
  const [reason, setReason] = useState<LocationAdjustmentReason>("Manual adjustment");
  const [locationId, setLocationId] = useState("");
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const held = (id: string) =>
    item
      ? (balances.find(
          (balance) => balance.inventoryItemId === item.id && balance.inventoryLocationId === id,
        )?.quantity ?? 0)
      : 0;
  // Any active location, plus an archived one that still (unexpectedly) holds this item.
  const choices = sortInventoryLocations(
    locations.filter((location) => location.active || held(location.id) > 0),
  );
  useEffect(() => {
    setAmount("");
    setReason("Manual adjustment");
    setError("");
    setLocationId(locations.find((location) => location.kind === "unassigned")?.id ?? "");
    // Reset only when a different item opens.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item?.id]);
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (saving) return;
    const value = Number(amount);
    const problem = validateLocationAdjustment({ amount: value, available: held(locationId) });
    if (problem) {
      setError(problem);
      return;
    }
    setSaving(true);
    setError("");
    try {
      await onAdjust(locationId, value, reason);
      onOpenChange(false);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not adjust quantity.");
    } finally {
      setSaving(false);
    }
  }
  return (
    <Dialog open={Boolean(item)} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Adjust quantity</DialogTitle>
          <DialogDescription className="break-words">
            {item?.name}: {item ? formatQuantity(item.quantity) : 0} {item?.unit} on hand in total
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={submit} className="space-y-4">
          <div>
            <Label htmlFor="adjust-location" className="mb-2 block">
              Location
            </Label>
            <select
              id="adjust-location"
              className="h-11 w-full rounded-md border bg-background px-3 text-sm"
              value={locationId}
              onChange={(e) => setLocationId(e.target.value)}
              required
            >
              {choices.map((location) => (
                <option key={location.id} value={location.id}>
                  {location.name} ({formatQuantity(held(location.id))} {item?.unit})
                </option>
              ))}
            </select>
          </div>
          <div>
            <Label htmlFor="adjust-amount" className="mb-2 block">
              Adjustment amount
            </Label>
            <Input
              id="adjust-amount"
              type="number"
              inputMode="decimal"
              step="any"
              className="h-11"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              required
            />
            <p className="mt-1 text-xs text-muted-foreground">
              Use a negative number to reduce stock at this location.
            </p>
          </div>
          <div>
            <Label htmlFor="adjust-reason" className="mb-2 block">
              Reason
            </Label>
            <select
              id="adjust-reason"
              className="h-11 w-full rounded-md border bg-background px-3 text-sm"
              value={reason}
              onChange={(e) => setReason(e.target.value as LocationAdjustmentReason)}
            >
              {locationAdjustmentReasons.map((value) => (
                <option key={value}>{value}</option>
              ))}
            </select>
          </div>
          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}
          <DialogFooter className="gap-2">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button disabled={!amount || Number(amount) === 0 || !locationId || saving}>
              {saving ? "Saving…" : "Apply adjustment"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

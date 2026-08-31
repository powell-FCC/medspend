import { useEffect, useState } from "react";
import {
  catalogInventoryUnitPrefill,
  type CatalogAdminResult,
} from "@/catalog-admin/catalog-admin";
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

export interface CatalogStockSubmission {
  catalogVendorProductId: string;
  unit: string;
  parLevel: number | null;
}

export function CatalogStockDialog({
  row,
  onOpenChange,
  onStock,
}: {
  row: CatalogAdminResult | null;
  onOpenChange: (open: boolean) => void;
  onStock: (input: CatalogStockSubmission) => Promise<void>;
}) {
  const [unit, setUnit] = useState("");
  const [parLevel, setParLevel] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    setUnit(row ? catalogInventoryUnitPrefill(row) : "");
    setParLevel("");
    setError("");
  }, [row]);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!row) return;

    const normalizedUnit = unit.trim();
    if (!normalizedUnit) {
      setError("Enter the inventory unit this organization will use.");
      return;
    }
    const normalizedParLevel = parLevel.trim() === "" ? null : Number(parLevel);
    if (
      normalizedParLevel !== null &&
      (!Number.isFinite(normalizedParLevel) || normalizedParLevel < 0)
    ) {
      setError("Par level must be zero or greater.");
      return;
    }

    setSaving(true);
    setError("");
    try {
      await onStock({
        catalogVendorProductId: row.catalogVendorProductId,
        unit: normalizedUnit,
        parLevel: normalizedParLevel,
      });
      onOpenChange(false);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Unable to add this item to inventory.");
    } finally {
      setSaving(false);
    }
  }

  const explicitUnitRequired = row?.packageStatus !== "verified";

  return (
    <Dialog
      open={Boolean(row)}
      onOpenChange={(open) => {
        if (!saving) onOpenChange(open);
      }}
    >
      <DialogContent className="sm:max-w-lg" data-section="catalog-stock-dialog">
        <DialogHeader>
          <DialogTitle>Add to inventory</DialogTitle>
          <DialogDescription>
            {row
              ? `${row.productName} · ${row.vendorName} SKU ${row.vendorSku}`
              : "Create inventory from an adopted catalog item."}
          </DialogDescription>
        </DialogHeader>
        <form className="space-y-5" onSubmit={submit}>
          <div>
            <Label htmlFor="catalog-stock-unit">Inventory unit</Label>
            <Input
              id="catalog-stock-unit"
              className="mt-2"
              value={unit}
              maxLength={80}
              onChange={(event) => setUnit(event.target.value)}
              placeholder={explicitUnitRequired ? "Enter a unit, such as each or box" : undefined}
              required
              autoFocus
            />
            <p className="mt-1.5 text-xs text-muted-foreground">
              {explicitUnitRequired
                ? "The source package is not verified, so an explicit inventory unit is required."
                : "Prefilled from the verified catalog package unit. Confirm it before continuing."}
            </p>
          </div>
          <div>
            <Label htmlFor="catalog-stock-par">Par level (optional)</Label>
            <Input
              id="catalog-stock-par"
              className="mt-2"
              type="number"
              min="0"
              step="any"
              value={parLevel}
              onChange={(event) => setParLevel(event.target.value)}
              placeholder="No par level"
            />
          </div>
          <div>
            <Label htmlFor="catalog-stock-quantity">Initial quantity</Label>
            <Input
              id="catalog-stock-quantity"
              className="mt-2"
              value="0"
              readOnly
              aria-describedby="catalog-stock-quantity-help"
            />
            <p id="catalog-stock-quantity-help" className="mt-1.5 text-xs text-muted-foreground">
              New catalog inventory starts at zero. Organization owners can record later stock
              changes through Inventory.
            </p>
          </div>
          {error && (
            <p className="text-sm text-destructive" role="alert">
              {error}
            </p>
          )}
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={saving}
              onClick={() => onOpenChange(false)}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? "Adding…" : "Add to inventory"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

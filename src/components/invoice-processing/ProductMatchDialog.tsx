import { useEffect, useMemo, useState } from "react";
import { Loader2, Search } from "lucide-react";
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
import type { InvoiceReviewProduct, ReviewItem } from "@/types/invoice-processing";

export function ProductMatchDialog({
  open,
  onOpenChange,
  item,
  products,
  onConfirm,
  onCreate,
  onUnlink,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  item?: ReviewItem;
  products: InvoiceReviewProduct[];
  onConfirm: (productId: string) => Promise<void>;
  onCreate: () => Promise<void>;
  onUnlink: (forget: boolean) => Promise<void>;
}) {
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState("");
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (open) {
      setQuery("");
      setSelected(item?.productMatch.productId ?? "");
    }
  }, [open, item]);
  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return products
      .filter(
        (product) =>
          !needle ||
          [
            product.name,
            product.description,
            product.manufacturer,
            product.internalItemCode,
            product.vendorItemNumber,
          ].some((value) => value.toLowerCase().includes(needle)),
      )
      .slice(0, 30);
  }, [products, query]);
  if (!item) return null;
  async function run(action: () => Promise<void>) {
    setBusy(true);
    try {
      await action();
      onOpenChange(false);
    } finally {
      setBusy(false);
    }
  }
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>Match invoice line to a product</DialogTitle>
          <DialogDescription>
            Choose the canonical product this vendor line represents. Package size, unit, and
            dimensions should agree.
          </DialogDescription>
        </DialogHeader>
        <div className="rounded-lg border bg-muted/30 p-3">
          <p className="font-medium">{item.description}</p>
          <p className="mt-1 text-sm text-muted-foreground">
            SKU {item.sku || "—"} · {item.packageSize || item.unitOfMeasure}
          </p>
        </div>
        {item.productMatch.state === "SUGGESTED" && (
          <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm">
            <span className="font-medium">Suggested:</span> {item.productMatch.productName} (
            {item.productMatch.score}% match). Confirm before it is remembered.
          </div>
        )}
        <div className="relative">
          <Search className="absolute left-3 top-3 h-4 w-4 text-muted-foreground" />
          <Input
            className="pl-9"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search product, manufacturer, or item code"
          />
        </div>
        <div className="max-h-64 space-y-2 overflow-y-auto pr-1">
          {filtered.map((product) => (
            <button
              type="button"
              key={product.id}
              onClick={() => setSelected(product.id)}
              className={`w-full rounded-lg border p-3 text-left ${selected === product.id ? "border-primary bg-primary/5" : "hover:bg-muted/50"}`}
            >
              <p className="font-medium">{product.name}</p>
              <p className="mt-1 text-xs text-muted-foreground">
                {[
                  product.manufacturer,
                  product.packSize,
                  product.unitOfMeasure,
                  product.internalItemCode || product.vendorItemNumber,
                ]
                  .filter(Boolean)
                  .join(" · ") || "No additional identifiers"}
              </p>
            </button>
          ))}
        </div>
        {!filtered.length && (
          <p className="py-4 text-center text-sm text-muted-foreground">
            No existing products match that search.
          </p>
        )}
        <DialogFooter className="flex-wrap sm:justify-between">
          <div className="flex flex-wrap gap-2">
            {item.productId && (
              <Button variant="outline" disabled={busy} onClick={() => run(() => onUnlink(false))}>
                Remove match
              </Button>
            )}
            {item.vendorProductId && (
              <Button variant="outline" disabled={busy} onClick={() => run(() => onUnlink(true))}>
                Remove and forget mapping
              </Button>
            )}
            <Button variant="secondary" disabled={busy} onClick={() => run(onCreate)}>
              Create product from line
            </Button>
          </div>
          <Button disabled={busy || !selected} onClick={() => run(() => onConfirm(selected))}>
            {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Confirm match
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

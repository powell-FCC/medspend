import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Loader2, Search } from "lucide-react";
import { Badge } from "@/components/ui/badge";
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
import {
  MIN_CATALOG_SEARCH_LENGTH,
  catalogSearchTerm,
  describeCatalogUnavailable,
  searchOrganizationProducts,
} from "@/invoice/catalog-match";
import type {
  InvoiceCatalogSearch,
  InvoiceReviewProduct,
  ReviewItem,
} from "@/types/invoice-processing";

type Selection = { source: "product" | "catalog"; id: string };

export function ProductMatchDialog({
  open,
  onOpenChange,
  item,
  products,
  vendorName,
  hasVendor,
  searchCatalog,
  onConfirm,
  onConfirmCatalog,
  onCreate,
  onUnlink,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  item?: ReviewItem;
  products: InvoiceReviewProduct[];
  vendorName: string;
  hasVendor: boolean;
  searchCatalog: (query: string) => Promise<InvoiceCatalogSearch>;
  onConfirm: (productId: string) => Promise<void>;
  onConfirmCatalog: (catalogVendorProductId: string) => Promise<void>;
  onCreate: () => Promise<void>;
  onUnlink: (forget: boolean) => Promise<void>;
}) {
  const [query, setQuery] = useState("");
  // The term is tied to the line it was built for, so opening another line never searches
  // the catalog with the previous line's SKU.
  const [catalogSearch, setCatalogSearch] = useState({ itemId: "", term: "" });
  const [selected, setSelected] = useState<Selection | null>(null);
  const [confirmingCreate, setConfirmingCreate] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const lineSku = item?.sku ?? "";
  useEffect(() => {
    if (open) {
      setQuery("");
      setCatalogSearch({ itemId: item?.id ?? "", term: catalogSearchTerm("", lineSku) });
      setSelected(
        item?.productMatch.productId
          ? { source: "product", id: item.productMatch.productId }
          : null,
      );
      setConfirmingCreate(false);
      setError("");
    }
  }, [open, item, lineSku]);
  // The catalog is searched on the server; wait for typing to pause.
  const itemId = item?.id ?? "";
  useEffect(() => {
    const timer = setTimeout(
      () => setCatalogSearch({ itemId, term: catalogSearchTerm(query, lineSku) }),
      250,
    );
    return () => clearTimeout(timer);
  }, [query, lineSku, itemId]);
  const catalogTerm = catalogSearch.term;
  const filtered = useMemo(() => searchOrganizationProducts(products, query), [products, query]);
  const catalog = useQuery({
    queryKey: ["invoice-catalog-search", item?.invoiceId, catalogTerm],
    queryFn: () => searchCatalog(catalogTerm),
    enabled: open && Boolean(item) && catalogSearch.itemId === itemId,
    staleTime: 30_000,
    retry: false,
  });
  if (!item) return null;
  const catalogName = catalog.data?.catalogVendorName || vendorName;
  const catalogHeading = catalogName ? `${catalogName} catalog` : "Vendor catalog";
  const selectedListing =
    selected?.source === "catalog"
      ? catalog.data?.results.find((listing) => listing.catalogVendorProductId === selected.id)
      : undefined;
  // A catalog item can only be confirmed while it is on screen.
  const chosen = selected?.source === "catalog" && !selectedListing ? null : selected;
  const chosenProductId =
    chosen?.source === "product" ? chosen.id : (selectedListing?.organizationProductId ?? null);
  // The line's SKU is a catalog-adopted mapping. Matching the line to a different product
  // never changes that mapping, so the SKU is not remembered for the new product.
  const keepsCatalogMapping =
    item.skuFromCatalog && Boolean(item.sku) && chosenProductId !== item.productId;
  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError("");
    try {
      await action();
      onOpenChange(false);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not update the product match.");
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
        {confirmingCreate ? (
          <div className="space-y-3 rounded-lg border p-4">
            <p className="font-medium">Create a new product from this line?</p>
            <dl className="grid grid-cols-[8rem_1fr] gap-x-3 gap-y-1 text-sm">
              <dt className="text-muted-foreground">Name</dt>
              <dd>{item.description}</dd>
              <dt className="text-muted-foreground">Vendor SKU</dt>
              <dd>{item.sku || "None on this line"}</dd>
              <dt className="text-muted-foreground">Unit</dt>
              <dd>{item.unitOfMeasure || "each"}</dd>
              <dt className="text-muted-foreground">Package</dt>
              <dd>{item.packageSize || "Not set"}</dd>
              <dt className="text-muted-foreground">Manufacturer</dt>
              <dd>{item.manufacturer || "Not set"}</dd>
              <dt className="text-muted-foreground">Category</dt>
              <dd>{item.category || "Not set"}</dd>
            </dl>
            <p className="text-sm text-muted-foreground">
              Only what this line says is copied; nothing else is filled in.
              {item.sku
                ? ` Vendor SKU ${item.sku} will be remembered for future ${vendorName || "vendor"} invoices.`
                : ""}{" "}
              No stock is added until the invoice is approved.
            </p>
            <p className="text-xs text-muted-foreground" data-hint="organization-only">
              Saved for your organization only. It is not added to the shared vendor catalog; owners
              and admins can see it under Catalog Vendors.
            </p>
          </div>
        ) : (
          <>
            <div className="relative">
              <Search className="absolute left-3 top-3 h-4 w-4 text-muted-foreground" />
              <Input
                className="pl-9"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Search by product name, manufacturer, or vendor SKU"
              />
            </div>
            <div className="space-y-4">
              <section aria-label="Your products">
                <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                  Your products
                </h3>
                <div className="max-h-40 space-y-2 overflow-y-auto pr-1">
                  {filtered.map((product) => (
                    <button
                      type="button"
                      key={product.id}
                      onClick={() => setSelected({ source: "product", id: product.id })}
                      className={`w-full rounded-lg border p-3 text-left ${chosen?.source === "product" && chosen.id === product.id ? "border-primary bg-primary/5" : "hover:bg-muted/50"}`}
                    >
                      <p className="font-medium">{product.name}</p>
                      <p className="mt-1 text-xs text-muted-foreground">
                        {[
                          product.manufacturer,
                          product.packSize,
                          product.unitOfMeasure,
                          product.vendorSkus[0] ||
                            product.internalItemCode ||
                            product.vendorItemNumber,
                        ]
                          .filter(Boolean)
                          .join(" · ") || "No additional identifiers"}
                      </p>
                    </button>
                  ))}
                </div>
                {!filtered.length && (
                  <p className="py-2 text-sm text-muted-foreground">
                    None of your products match that search.
                  </p>
                )}
              </section>
              <section aria-label={catalogHeading}>
                <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                  {catalogHeading}
                </h3>
                {catalog.isPending ? (
                  <p className="flex items-center gap-2 py-2 text-sm text-muted-foreground">
                    <Loader2 className="h-4 w-4 animate-spin" />
                    Searching the catalog...
                  </p>
                ) : catalog.isError ? (
                  <p className="py-2 text-sm text-muted-foreground">
                    Catalog search is unavailable right now. You can still choose one of your
                    products or create a product from this line.
                  </p>
                ) : !catalog.data.available ? (
                  <p className="py-2 text-sm text-muted-foreground">
                    {describeCatalogUnavailable(catalog.data.reason, vendorName)}
                  </p>
                ) : catalogTerm.length < MIN_CATALOG_SEARCH_LENGTH ? (
                  <p className="py-2 text-sm text-muted-foreground">
                    Type a vendor SKU or product name to search the {catalogHeading}.
                  </p>
                ) : !catalog.data.results.length ? (
                  <p className="py-2 text-sm text-muted-foreground">
                    No {catalogHeading} items match &ldquo;{catalogTerm}&rdquo;. If this is a new
                    product, create it from this line.
                  </p>
                ) : (
                  <div className="max-h-40 space-y-2 overflow-y-auto pr-1">
                    {catalog.data.results.map((listing) => (
                      <button
                        type="button"
                        key={listing.catalogVendorProductId}
                        onClick={() =>
                          setSelected({ source: "catalog", id: listing.catalogVendorProductId })
                        }
                        className={`w-full rounded-lg border border-dashed p-3 text-left ${chosen?.source === "catalog" && chosen.id === listing.catalogVendorProductId ? "border-primary bg-primary/5" : "hover:bg-muted/50"}`}
                      >
                        <div className="flex flex-wrap items-center gap-2">
                          <p className="font-medium">{listing.name}</p>
                          <Badge variant="outline">
                            {listing.organizationProductId ? "Already in your products" : "Catalog"}
                          </Badge>
                          {!listing.verified && <Badge variant="secondary">Not verified</Badge>}
                        </div>
                        <p className="mt-1 text-xs text-muted-foreground">
                          {[
                            `SKU ${listing.vendorSku}`,
                            listing.manufacturer,
                            listing.packageDescription,
                          ]
                            .filter(Boolean)
                            .join(" · ")}
                        </p>
                      </button>
                    ))}
                  </div>
                )}
              </section>
            </div>
            {chosen && (
              <p className="text-sm text-muted-foreground">
                {selectedListing && !selectedListing.organizationProductId
                  ? "This catalog item will be added to your products. No stock is added. "
                  : ""}
                {keepsCatalogMapping
                  ? `Vendor SKU ${item.sku} is a ${vendorName || "vendor"} catalog item. Choosing a different product matches this line on this invoice only; the SKU stays mapped to its catalog product.`
                  : item.sku
                    ? `Vendor SKU ${item.sku} will be remembered for future ${vendorName || "vendor"} invoices.`
                    : ""}
              </p>
            )}
          </>
        )}
        {error && (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}
        {confirmingCreate ? (
          <DialogFooter>
            <Button variant="outline" disabled={busy} onClick={() => setConfirmingCreate(false)}>
              Back
            </Button>
            <Button disabled={busy} onClick={() => run(onCreate)}>
              {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Create product
            </Button>
          </DialogFooter>
        ) : (
          <DialogFooter className="flex-wrap sm:justify-between">
            <div className="flex flex-wrap gap-2">
              {item.productId && (
                <Button
                  variant="outline"
                  disabled={busy}
                  onClick={() => run(() => onUnlink(false))}
                >
                  Remove match
                </Button>
              )}
              {item.vendorProductId && (
                <Button variant="outline" disabled={busy} onClick={() => run(() => onUnlink(true))}>
                  Remove and forget mapping
                </Button>
              )}
              <Button
                variant="secondary"
                disabled={busy || !hasVendor || Boolean(item.productId)}
                title={
                  !hasVendor
                    ? "Select an existing vendor on this invoice before creating a product"
                    : item.productId
                      ? "Remove the current match before creating a new product"
                      : undefined
                }
                onClick={() => {
                  setError("");
                  setConfirmingCreate(true);
                }}
              >
                Create product from line
              </Button>
            </div>
            <Button
              disabled={busy || !chosen}
              onClick={() =>
                chosen &&
                run(() =>
                  chosen.source === "catalog" ? onConfirmCatalog(chosen.id) : onConfirm(chosen.id),
                )
              }
            >
              {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              {selectedListing && !selectedListing.organizationProductId
                ? "Add to your products and match"
                : "Confirm match"}
            </Button>
          </DialogFooter>
        )}
      </DialogContent>
    </Dialog>
  );
}

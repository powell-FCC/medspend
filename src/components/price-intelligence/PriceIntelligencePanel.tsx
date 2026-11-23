// Phase 6B.1 Price Intelligence workspace inside Budget & Purchasing: the keyset-paged list,
// its filters, and the product vendor history sheet (also opened by ?priceProduct= or
// ?priceInventoryItem= deep links from request review, Replenishment and the catalog).
import { useState } from "react";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { SectionError, SectionLoading } from "@/components/budget-purchasing/CommandCenterSections";
import { PriceIntelligenceList } from "@/components/price-intelligence/PriceIntelligenceSections";
import { ProductVendorHistory } from "@/components/price-intelligence/ProductVendorHistory";
import {
  getPriceIntelligenceSummaryFn,
  listPriceIntelligenceFn,
} from "@/lib/price-intelligence.functions";
import type {
  PriceFilter,
  PriceListCursor,
  PriceSort,
} from "@/price-intelligence/vendor-intelligence";

export type PriceTarget = { productId: string } | { inventoryItemId: string };

export function PriceIntelligencePanel({
  organizationId,
  target,
  onTargetChange,
}: {
  organizationId: string;
  target: PriceTarget | null;
  onTargetChange: (target: PriceTarget | null) => void;
}) {
  const fetchList = useServerFn(listPriceIntelligenceFn);
  const fetchSummary = useServerFn(getPriceIntelligenceSummaryFn);
  const [filter, setFilter] = useState<PriceFilter>("all");
  const [sort, setSort] = useState<PriceSort>("recent");
  const [vendorId, setVendorId] = useState<string | null>(null);

  const summary = useQuery({
    queryKey: ["price-intelligence", organizationId, "summary"],
    queryFn: () => fetchSummary({ data: { organizationId } }),
  });
  const list = useInfiniteQuery({
    queryKey: ["price-intelligence", organizationId, "list", sort, filter, vendorId],
    initialPageParam: null as PriceListCursor,
    queryFn: ({ pageParam }) =>
      fetchList({ data: { organizationId, sort, filter, vendorId, cursor: pageParam } }),
    getNextPageParam: (page) => (page.exhausted ? undefined : page.nextCursor),
  });

  // A filtered page may come back short (or empty) while more products remain to scan:
  // "Load more" continues from the cursor.
  const rows = list.data?.pages.flatMap((p) => p.rows) ?? [];
  const selectedProductId = target && "productId" in target ? target.productId : null;
  const selectedName = rows.find((r) => r.productId === selectedProductId)?.productName;

  return (
    <>
      {list.isPending ? (
        <SectionLoading label="Loading price intelligence…" />
      ) : list.isError ? (
        <SectionError
          message="Price intelligence could not be loaded."
          onRetry={() => list.refetch()}
        />
      ) : (
        <PriceIntelligenceList
          summary={summary.data}
          rows={rows}
          filter={filter}
          sort={sort}
          vendorId={vendorId}
          selectedProductId={selectedProductId}
          canLoadMore={list.hasNextPage}
          loadingMore={list.isFetchingNextPage}
          onFilter={setFilter}
          onSort={setSort}
          onVendor={setVendorId}
          onSelect={(productId) => onTargetChange({ productId })}
          onLoadMore={() => void list.fetchNextPage()}
        />
      )}
      <Sheet open={!!target} onOpenChange={(open) => !open && onTargetChange(null)}>
        <SheetContent className="w-full overflow-y-auto sm:max-w-3xl">
          {target && (
            <>
              <SheetHeader className="mb-4">
                <SheetTitle>{selectedName ?? "Purchase history"}</SheetTitle>
                <SheetDescription>
                  Prices you have paid, by vendor, with the source purchase behind each one.
                </SheetDescription>
              </SheetHeader>
              <ProductVendorHistory
                organizationId={organizationId}
                target={target}
                showProductName={!selectedName}
              />
            </>
          )}
        </SheetContent>
      </Sheet>
    </>
  );
}

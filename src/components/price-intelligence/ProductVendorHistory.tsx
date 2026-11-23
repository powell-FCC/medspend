// Phase 6B.1 product vendor history: the shared product-detail view used by Budget &
// Purchasing (Price Intelligence) and the catalog product page. Read-only. Owners can open the
// posted source document through the Phase 7E document drill-down; admins see the reference.
import { useState } from "react";
import { useInfiniteQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { DocumentDetailDrill } from "@/components/budget-analytics/SpendWorkspace";
import { SectionError, SectionLoading } from "@/components/budget-purchasing/CommandCenterSections";
import { ProductVendorHistoryView } from "@/components/price-intelligence/PriceIntelligenceSections";
import { getProductVendorHistoryFn } from "@/lib/price-intelligence.functions";

type Target = { productId: string } | { inventoryItemId: string };
type Cursor = { purchaseDate: string; createdAt: string; observationId: string } | null;

export function ProductVendorHistory({
  organizationId,
  target,
  showProductName = false,
}: {
  organizationId: string;
  target: Target;
  showProductName?: boolean;
}) {
  const fetchHistory = useServerFn(getProductVendorHistoryFn);
  const [documentId, setDocumentId] = useState<string | null>(null);
  const key = "productId" in target ? target.productId : `item:${target.inventoryItemId}`;
  const history = useInfiniteQuery({
    queryKey: ["price-intelligence", organizationId, "product", key],
    initialPageParam: null as Cursor,
    queryFn: ({ pageParam }) =>
      fetchHistory({ data: { organizationId, ...target, cursor: pageParam } }),
    getNextPageParam: (page) => page.nextCursor,
  });
  if (history.isPending) return <SectionLoading label="Loading purchase history…" />;
  if (history.isError)
    return <SectionError message={history.error.message} onRetry={() => history.refetch()} />;
  const first = history.data.pages[0];
  return (
    <>
      {showProductName && (
        <p className="mb-3 text-base font-semibold text-[#102a49]">{first.productName}</p>
      )}
      <ProductVendorHistoryView
        history={first}
        observations={history.data.pages.flatMap((p) => p.observations)}
        canLoadMore={history.hasNextPage}
        loadingMore={history.isFetchingNextPage}
        onLoadMore={() => void history.fetchNextPage()}
        onOpenDocument={first.canOpenSourceDocument ? setDocumentId : undefined}
      />
      <Sheet open={!!documentId} onOpenChange={(open) => !open && setDocumentId(null)}>
        <SheetContent className="w-full overflow-y-auto sm:max-w-2xl">
          {documentId && (
            <DocumentDetailDrill organizationId={organizationId} invoiceId={documentId} />
          )}
        </SheetContent>
      </Sheet>
    </>
  );
}

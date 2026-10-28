import { useInfiniteQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { listWorkspaceLocationStockFn } from "@/lib/inventory-workspace.functions";
import { workspaceQueryKey } from "@/inventory/workspace";
import type { WorkspaceLocation } from "@/types/inventory-workspace";
import { type ItemStockAction } from "./ItemStockDialogs";
import { LocationStockTable } from "./LocationStockTable";

const PAGE = 100;

export function LocationStockTab({
  organizationId,
  location,
  canManage,
  onAction,
}: {
  organizationId: string;
  location: WorkspaceLocation;
  canManage: boolean;
  onAction: (action: ItemStockAction) => void;
}) {
  const list = useServerFn(listWorkspaceLocationStockFn);
  const stock = useInfiniteQuery({
    queryKey: [...workspaceQueryKey(organizationId), "location-stock", location.id],
    queryFn: ({ pageParam }) =>
      list({ data: { organizationId, locationId: location.id, cursor: pageParam, limit: PAGE } }),
    initialPageParam: null as WorkspaceStockPageParam,
    getNextPageParam: (page) => page.nextCursor,
  });
  if (stock.isLoading)
    return <p className="py-8 text-center text-sm text-muted-foreground">Loading stock…</p>;
  if (stock.isError)
    return (
      <Alert variant="destructive">
        <AlertTitle>Could not load stock</AlertTitle>
        <AlertDescription>
          {stock.error instanceof Error ? stock.error.message : "Try again."}
        </AlertDescription>
      </Alert>
    );
  const rows = stock.data?.pages.flatMap((page) => page.rows) ?? [];
  return (
    <div className="space-y-3">
      <LocationStockTable
        location={location}
        rows={rows}
        canManage={canManage}
        onAction={onAction}
      />
      {stock.hasNextPage && (
        <div className="text-center">
          <Button
            variant="outline"
            disabled={stock.isFetchingNextPage}
            onClick={() => void stock.fetchNextPage()}
          >
            {stock.isFetchingNextPage ? "Loading…" : "Load more"}
          </Button>
        </div>
      )}
    </div>
  );
}

type WorkspaceStockPageParam = { name: string; id: string } | null;

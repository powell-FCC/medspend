import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import {
  getInventoryOverviewFn,
  listAdjustmentHistoryFn,
  listCountHistoryFn,
  listTransferHistoryFn,
} from "@/lib/inventory-workspace.functions";
import { workspaceQueryKey } from "@/inventory/workspace";
import { NeedsAttention, OverviewSnapshotCards, RecentActivityLists } from "./OverviewSections";

const RECENT = 5;

// Phase 7B.4 Overview: the snapshot and needs-attention lists come from one database read;
// recent activity reuses the Counts and Activity reads with a page of five. Read-only.
export function InventoryOverviewTab({ organizationId }: { organizationId: string }) {
  const getOverview = useServerFn(getInventoryOverviewFn);
  const listCounts = useServerFn(listCountHistoryFn);
  const listTransfers = useServerFn(listTransferHistoryFn);
  const listAdjustments = useServerFn(listAdjustmentHistoryFn);
  const key = workspaceQueryKey(organizationId);
  const overview = useQuery({
    queryKey: [...key, "overview"],
    queryFn: () => getOverview({ data: { organizationId } }),
  });
  const counts = useQuery({
    queryKey: [...key, "overview-recent-counts"],
    queryFn: () => listCounts({ data: { organizationId, limit: RECENT } }),
  });
  const transfers = useQuery({
    queryKey: [...key, "overview-recent-transfers"],
    queryFn: () => listTransfers({ data: { organizationId, limit: RECENT } }),
  });
  const adjustments = useQuery({
    queryKey: [...key, "overview-recent-adjustments"],
    queryFn: () => listAdjustments({ data: { organizationId, limit: RECENT } }),
  });
  const recentError = [counts, transfers, adjustments].find((query) => query.isError)?.error;

  return (
    <div className="space-y-6" data-testid="inventory-overview">
      {overview.isLoading && (
        <p className="py-8 text-center text-sm text-muted-foreground">Loading overview…</p>
      )}
      {overview.isError && (
        <Alert variant="destructive">
          <AlertTitle>Could not load the overview</AlertTitle>
          <AlertDescription>
            {overview.error instanceof Error ? overview.error.message : "Try again."}
          </AlertDescription>
        </Alert>
      )}
      {overview.data && (
        <>
          <OverviewSnapshotCards snapshot={overview.data.snapshot} />
          <NeedsAttention overview={overview.data} />
        </>
      )}
      {recentError ? (
        <Alert variant="destructive">
          <AlertTitle>Could not load recent activity</AlertTitle>
          <AlertDescription>
            {recentError instanceof Error ? recentError.message : "Try again."}
          </AlertDescription>
        </Alert>
      ) : (
        <RecentActivityLists
          counts={counts.data?.rows ?? null}
          transfers={transfers.data?.rows ?? null}
          adjustments={adjustments.data?.rows ?? null}
        />
      )}
    </div>
  );
}

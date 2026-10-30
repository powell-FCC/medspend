import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { listTransferHistoryFn } from "@/lib/inventory-workspace.functions";
import { transferEmptyMessage } from "@/inventory/activity";
import { workspaceQueryKey } from "@/inventory/workspace";
import { TransferHistoryTable } from "./ActivityTables";

const RECENT = 5;

// Phase 7B.4 Unassigned workspace: the newest moves into and out of Unassigned, with the
// full history one tab away. Read-only for everyone.
export function UnassignedRecentTransfers({
  organizationId,
  locationId,
}: {
  organizationId: string;
  locationId: string;
}) {
  const list = useServerFn(listTransferHistoryFn);
  const transfers = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "unassigned-recent-transfers", locationId],
    queryFn: () => list({ data: { organizationId, locationId, limit: RECENT } }),
  });
  return (
    <section className="space-y-3" data-testid="unassigned-recent-transfers">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-lg font-semibold">Recent transfers</h2>
        <Link
          to="/inventory/locations/$locationId"
          params={{ locationId }}
          search={{ tab: "activity" }}
          className="text-sm text-primary hover:underline"
        >
          All Unassigned activity
        </Link>
      </div>
      {transfers.isLoading && <p className="text-sm text-muted-foreground">Loading transfers…</p>}
      {transfers.isError && (
        <Alert variant="destructive">
          <AlertTitle>Could not load transfers</AlertTitle>
          <AlertDescription>
            {transfers.error instanceof Error ? transfers.error.message : "Try again."}
          </AlertDescription>
        </Alert>
      )}
      {transfers.data && (
        <TransferHistoryTable
          rows={transfers.data.rows}
          locationId={locationId}
          emptyMessage={transferEmptyMessage({ filtered: false, forLocation: true })}
        />
      )}
    </section>
  );
}

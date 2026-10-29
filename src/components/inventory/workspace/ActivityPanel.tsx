import { useState } from "react";
import { useInfiniteQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  listAdjustmentHistoryFn,
  listTransferHistoryFn,
} from "@/lib/inventory-workspace.functions";
import {
  ADJUSTMENT_TOTALS_NOTE,
  adjustmentEmptyMessage,
  transferEmptyMessage,
  type ActivityView,
} from "@/inventory/activity";
import { workspaceQueryKey } from "@/inventory/workspace";
import type { ActivityCursor } from "@/types/inventory-workspace";
import { ActivityFilterBar } from "./ActivityFilters";
import { AdjustmentHistoryTable, TransferHistoryTable } from "./ActivityTables";
import { useActivityFilterState } from "./useActivityFilterState";

const PAGE = 50;

// Phase 7B.3 Activity: transfers and manual adjustments, for the whole organization
// (Inventory > Activity) or one location (location > Activity). Two separate lists with their
// own filters and pages; physical counts stay in Counts. Defaults show all history, newest
// first, a page at a time; nothing is date-limited unless the viewer chooses a range.
export function ActivityPanel({
  organizationId,
  locationId,
}: {
  organizationId: string;
  locationId?: string;
}) {
  const [view, setView] = useState<ActivityView>("transfers");
  return (
    <Tabs
      value={view}
      onValueChange={(value) => setView(value as ActivityView)}
      data-testid="activity-panel"
    >
      <TabsList aria-label="Activity type">
        <TabsTrigger value="transfers">Transfers</TabsTrigger>
        <TabsTrigger value="adjustments">Adjustments</TabsTrigger>
      </TabsList>
      <TabsContent value="transfers" className="mt-4">
        <TransferHistoryPanel organizationId={organizationId} locationId={locationId} />
      </TabsContent>
      <TabsContent value="adjustments" className="mt-4">
        <AdjustmentHistoryPanel organizationId={organizationId} locationId={locationId} />
      </TabsContent>
    </Tabs>
  );
}

function TransferHistoryPanel({
  organizationId,
  locationId,
}: {
  organizationId: string;
  locationId?: string;
}) {
  const list = useServerFn(listTransferHistoryFn);
  const state = useActivityFilterState(locationId);
  const history = useInfiniteQuery({
    queryKey: [...workspaceQueryKey(organizationId), "transfer-history", state.filters],
    queryFn: ({ pageParam }) =>
      list({ data: { organizationId, ...state.filters, cursor: pageParam, limit: PAGE } }),
    initialPageParam: null as ActivityCursor | null,
    getNextPageParam: (page) => page.nextCursor,
    enabled: !state.invalidRange,
  });
  return (
    <div className="space-y-4" data-testid="transfer-history-panel">
      <ActivityFilterBar
        organizationId={organizationId}
        locationId={locationId}
        state={state}
        personLabel="Moved by"
      />
      <HistoryStatus
        query={history}
        invalidRange={state.invalidRange}
        noun="transfers"
        render={(pages) => (
          <TransferHistoryTable
            rows={pages.flatMap((page) => page.rows)}
            locationId={locationId}
            emptyMessage={transferEmptyMessage({
              filtered: state.filtered,
              forLocation: Boolean(locationId),
            })}
          />
        )}
      />
    </div>
  );
}

function AdjustmentHistoryPanel({
  organizationId,
  locationId,
}: {
  organizationId: string;
  locationId?: string;
}) {
  const list = useServerFn(listAdjustmentHistoryFn);
  const state = useActivityFilterState(locationId);
  const filters = { ...state.filters, reason: state.reason };
  const history = useInfiniteQuery({
    queryKey: [...workspaceQueryKey(organizationId), "adjustment-history", filters],
    queryFn: ({ pageParam }) =>
      list({ data: { organizationId, ...filters, cursor: pageParam, limit: PAGE } }),
    initialPageParam: null as ActivityCursor | null,
    getNextPageParam: (page) => page.nextCursor,
    enabled: !state.invalidRange,
  });
  return (
    <div className="space-y-4" data-testid="adjustment-history-panel">
      <p className="max-w-3xl text-sm text-muted-foreground" data-testid="adjustment-explainer">
        Manual quantity changes. Physical count corrections are shown in Counts.{" "}
        {ADJUSTMENT_TOTALS_NOTE}
      </p>
      <ActivityFilterBar
        organizationId={organizationId}
        locationId={locationId}
        state={state}
        personLabel="Adjusted by"
        showReason
      />
      <HistoryStatus
        query={history}
        invalidRange={state.invalidRange}
        noun="adjustments"
        render={(pages) => (
          <AdjustmentHistoryTable
            rows={pages.flatMap((page) => page.rows)}
            showLocation={!locationId}
            emptyMessage={adjustmentEmptyMessage({
              filtered: state.filtered,
              forLocation: Boolean(locationId),
            })}
          />
        )}
      />
    </div>
  );
}

// Loading, error, the list, and "Load more", the same way for both lists.
function HistoryStatus<P>({
  query,
  invalidRange,
  noun,
  render,
}: {
  query: {
    isLoading: boolean;
    isError: boolean;
    error: unknown;
    data?: { pages: P[] };
    hasNextPage: boolean;
    isFetchingNextPage: boolean;
    fetchNextPage: () => Promise<unknown>;
  };
  invalidRange: boolean;
  noun: string;
  render: (pages: P[]) => React.ReactNode;
}) {
  return (
    <>
      {!invalidRange && query.isLoading && (
        <p className="py-8 text-center text-sm text-muted-foreground">Loading {noun}…</p>
      )}
      {query.isError && (
        <Alert variant="destructive">
          <AlertTitle>Could not load {noun}</AlertTitle>
          <AlertDescription>
            {query.error instanceof Error ? query.error.message : "Try again."}
          </AlertDescription>
        </Alert>
      )}
      {!invalidRange && query.data && render(query.data.pages)}
      {query.hasNextPage && (
        <div className="text-center">
          <Button
            variant="outline"
            disabled={query.isFetchingNextPage}
            onClick={() => void query.fetchNextPage()}
          >
            {query.isFetchingNextPage ? "Loading…" : "Load more"}
          </Button>
        </div>
      )}
    </>
  );
}

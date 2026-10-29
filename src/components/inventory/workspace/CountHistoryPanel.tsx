import { useState } from "react";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { listOrgMembersFn } from "@/lib/orgs.functions";
import { listCountHistoryFn, listWorkspaceLocationsFn } from "@/lib/inventory-workspace.functions";
import {
  COUNT_HISTORY_EXPLAINER,
  countDateRange,
  countHistoryEmptyMessage,
} from "@/inventory/count-history";
import { workspaceQueryKey } from "@/inventory/workspace";
import { CountHistoryTable } from "./CountHistoryTable";

const PAGE = 50;

// Count history with server-side filters, for the whole organization (Inventory > Counts)
// or one location (location > Counts). Defaults show all history, newest first, a page at a
// time; nothing is date-limited unless the viewer chooses a range.
export function CountHistoryPanel({
  organizationId,
  locationId,
}: {
  organizationId: string;
  locationId?: string;
}) {
  const listHistory = useServerFn(listCountHistoryFn);
  const listLocations = useServerFn(listWorkspaceLocationsFn);
  const listMembers = useServerFn(listOrgMembersFn);
  const [location, setLocation] = useState("");
  const [countedBy, setCountedBy] = useState("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [changedOnly, setChangedOnly] = useState(false);
  const range = countDateRange(from, to);
  const invalidRange = Boolean(from && to && from > to);
  const filters = {
    locationId: locationId ?? (location || null),
    countedBy: countedBy || null,
    changedOnly,
    submittedFrom: range.submittedFrom,
    submittedBefore: range.submittedBefore,
  };
  const history = useInfiniteQuery({
    queryKey: [...workspaceQueryKey(organizationId), "count-history", filters],
    queryFn: ({ pageParam }) =>
      listHistory({ data: { organizationId, ...filters, cursor: pageParam, limit: PAGE } }),
    initialPageParam: null as { submittedAt: string; id: string } | null,
    getNextPageParam: (page) => page.nextCursor,
    enabled: !invalidRange,
  });
  const locations = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "locations", "all"],
    queryFn: () => listLocations({ data: { organizationId, status: "all" } }),
    enabled: !locationId,
    select: (data) => data.locations.filter((row) => row.kind === "storage"),
  });
  const members = useQuery({
    queryKey: ["org-members", organizationId],
    queryFn: () => listMembers({ data: { organizationId } }),
    select: (rows) => [...rows].sort((a, b) => a.fullName.localeCompare(b.fullName)),
  });
  const filtered = Boolean((!locationId && location) || countedBy || from || to || changedOnly);
  const rows = history.data?.pages.flatMap((page) => page.rows) ?? [];

  return (
    <div className="space-y-4" data-testid="count-history-panel">
      <p className="max-w-3xl text-sm text-muted-foreground" data-testid="count-explainer">
        {COUNT_HISTORY_EXPLAINER}
      </p>
      <div
        className={`grid gap-3 rounded-xl border bg-card p-4 sm:grid-cols-2 ${locationId ? "lg:grid-cols-[minmax(0,1fr)_10rem_10rem_auto]" : "lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_10rem_10rem_auto]"}`}
      >
        {!locationId && (
          <select
            aria-label="Location filter"
            className="h-9 min-w-0 rounded-md border bg-background px-3 text-sm"
            value={location}
            onChange={(e) => setLocation(e.target.value)}
          >
            <option value="">All locations</option>
            {locations.data?.map((row) => (
              <option key={row.id} value={row.id}>
                {row.name}
                {row.active ? "" : " (archived)"}
              </option>
            ))}
          </select>
        )}
        <select
          aria-label="Counted by filter"
          className="h-9 min-w-0 rounded-md border bg-background px-3 text-sm"
          value={countedBy}
          onChange={(e) => setCountedBy(e.target.value)}
        >
          <option value="">Anyone</option>
          {members.data?.map((member) => (
            <option key={member.userId} value={member.userId}>
              {member.fullName}
            </option>
          ))}
        </select>
        <Input
          type="date"
          aria-label="Counted from"
          className="min-w-0"
          value={from}
          onChange={(e) => setFrom(e.target.value)}
        />
        <Input
          type="date"
          aria-label="Counted to"
          className="min-w-0"
          value={to}
          onChange={(e) => setTo(e.target.value)}
        />
        <label className="flex h-9 items-center gap-2 whitespace-nowrap text-sm">
          <input
            type="checkbox"
            checked={changedOnly}
            onChange={(e) => setChangedOnly(e.target.checked)}
          />
          Has corrections
        </label>
      </div>
      {invalidRange && (
        <p role="alert" className="text-sm text-destructive">
          The start date must be on or before the end date.
        </p>
      )}
      {!invalidRange && history.isLoading && (
        <p className="py-8 text-center text-sm text-muted-foreground">Loading counts…</p>
      )}
      {history.isError && (
        <Alert variant="destructive">
          <AlertTitle>Could not load counts</AlertTitle>
          <AlertDescription>
            {history.error instanceof Error ? history.error.message : "Try again."}
          </AlertDescription>
        </Alert>
      )}
      {!invalidRange && history.data && (
        <CountHistoryTable
          rows={rows}
          showLocation={!locationId}
          emptyMessage={countHistoryEmptyMessage({ filtered, forLocation: Boolean(locationId) })}
        />
      )}
      {history.hasNextPage && (
        <div className="text-center">
          <Button
            variant="outline"
            disabled={history.isFetchingNextPage}
            onClick={() => void history.fetchNextPage()}
          >
            {history.isFetchingNextPage ? "Loading…" : "Load more"}
          </Button>
        </div>
      )}
    </div>
  );
}

import { createFileRoute, Link, Outlet, useMatch } from "@tanstack/react-router";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { ClipboardList } from "lucide-react";
import { useState } from "react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { getStaffDashboardFn } from "@/lib/supply-requests.functions";
import { RequestSummaryCard } from "@/components/staff/RequestSummaryCard";
import { StaffEmptyState } from "@/components/staff/StaffEmptyState";
import {
  StaffErrorState,
  StaffListSkeleton,
  StaffSectionHeader,
} from "@/components/staff/StaffStates";
import {
  STAFF_PAST_REQUEST_MAX,
  STAFF_PAST_REQUEST_PAGE_SIZE,
} from "@/supply-requests/staff-dashboard";

export const Route = createFileRoute("/_authenticated/staff/requests")({
  head: () => ({
    meta: [{ title: "My requests — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: StaffRequests,
});

function StaffRequests() {
  const detailMatch = useMatch({
    from: "/_authenticated/staff/requests/$id",
    shouldThrow: false,
  });
  return detailMatch ? <Outlet /> : <MyRequests />;
}

// Open requests first (ready ones on top), then past requests one page at a time.
// Each card already carries date, item count, contents and plain-language status, and
// has room for future per-request actions without a redesign.
function MyRequests() {
  const { active } = useActiveOrg();
  const [pastLimit, setPastLimit] = useState(STAFF_PAST_REQUEST_PAGE_SIZE);
  const fetcher = useServerFn(getStaffDashboardFn);
  const q = useQuery({
    queryKey: ["me", active?.organizationId, "requests", "history", pastLimit],
    queryFn: () => fetcher({ data: { organizationId: active!.organizationId, pastLimit } }),
    enabled: !!active,
    placeholderData: keepPreviousData,
  });
  const openRequests = [...(q.data?.openRequests ?? [])].sort(
    (a, b) => Number(b.statusGroup === "READY") - Number(a.statusGroup === "READY"),
  );
  const pastRequests = q.data?.pastRequests ?? [];
  const isEmpty = q.data && openRequests.length === 0 && pastRequests.length === 0;

  return (
    <div className="space-y-8">
      <header>
        <p className="text-xs font-semibold uppercase tracking-[0.16em] text-[#697687]">History</p>
        <h1 className="mt-1 text-[1.7rem] font-semibold tracking-tight text-[#071d38]">
          My Requests
        </h1>
      </header>
      {q.isLoading && <StaffListSkeleton label="Loading your requests" />}
      {q.isError && !q.data && (
        <StaffErrorState
          message="We couldn't load your requests."
          onRetry={() => void q.refetch()}
        />
      )}
      {isEmpty && (
        <StaffEmptyState
          icon={<ClipboardList className="size-5" />}
          title="No requests yet"
          description="Requests you submit will appear here."
          action={
            <Link
              to="/staff"
              className="inline-flex min-h-11 items-center rounded-xl bg-[#071d38] px-4 text-sm font-semibold text-white"
            >
              Request supplies
            </Link>
          }
        />
      )}
      {openRequests.length > 0 && (
        <section aria-labelledby="active-requests-title">
          <StaffSectionHeader
            id="active-requests-title"
            title={`In progress · ${openRequests.length}`}
          />
          <div className="mt-2 space-y-2.5">
            {openRequests.map((request) => (
              <RequestSummaryCard key={request.id} request={request} />
            ))}
          </div>
        </section>
      )}
      {pastRequests.length > 0 && (
        <section aria-labelledby="completed-requests-title">
          <StaffSectionHeader id="completed-requests-title" title="Past requests" />
          <div className="mt-2 space-y-2.5">
            {pastRequests.map((request) => (
              <RequestSummaryCard key={request.id} request={request} />
            ))}
          </div>
          {q.data?.hasMorePastRequests && pastLimit < STAFF_PAST_REQUEST_MAX && (
            <button
              type="button"
              onClick={() =>
                setPastLimit((limit) =>
                  Math.min(limit + STAFF_PAST_REQUEST_PAGE_SIZE, STAFF_PAST_REQUEST_MAX),
                )
              }
              disabled={q.isFetching}
              className="mt-3 flex min-h-12 w-full items-center justify-center rounded-xl border border-[#dce2e8] bg-white text-sm font-semibold text-[#344256] active:bg-[#f2f4f6] disabled:opacity-60"
            >
              {q.isFetching ? "Loading…" : "Show older requests"}
            </button>
          )}
          {q.isError && q.data && (
            <div className="mt-3">
              <StaffErrorState
                message="We couldn't load more requests."
                onRetry={() => void q.refetch()}
              />
            </div>
          )}
        </section>
      )}
    </div>
  );
}

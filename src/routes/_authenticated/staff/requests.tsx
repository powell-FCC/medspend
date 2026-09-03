import { createFileRoute, Outlet, useMatch } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useActiveOrg } from "@/hooks/use-active-org";
import { getStaffDashboardFn } from "@/lib/supply-requests.functions";
import { RequestSummaryCard } from "@/components/staff/RequestSummaryCard";
import { StaffEmptyState } from "@/components/staff/StaffEmptyState";

export const Route = createFileRoute("/_authenticated/staff/requests")({
  head: () => ({ meta: [{ title: "My requests — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: StaffRequests,
});

function StaffRequests() {
  const detailMatch = useMatch({
    from: "/_authenticated/staff/requests/$id",
    shouldThrow: false,
  });
  return detailMatch ? <Outlet /> : <MyRequests />;
}

function MyRequests() {
  const { active } = useActiveOrg();
  const fetcher = useServerFn(getStaffDashboardFn);
  const q = useQuery({
    queryKey: ["me", active?.organizationId, "requests"],
    queryFn: () => fetcher({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });
  const activeRequests = q.data?.recentRequests.filter((request) => request.statusGroup !== "COMPLETED") ?? [];
  const completedRequests = q.data?.recentRequests.filter((request) => request.statusGroup === "COMPLETED") ?? [];

  return (
    <div className="space-y-8">
      <header>
        <p className="text-xs font-semibold uppercase tracking-[0.16em] text-[#697687]">History</p>
        <h1 className="mt-1 text-[1.7rem] font-semibold tracking-tight text-[#071d38]">My Requests</h1>
      </header>
      {(q.data?.recentRequests.length ?? 0) > 0 ? (<>
        {activeRequests.length > 0 && <section aria-labelledby="active-requests-title">
          <h2 id="active-requests-title" className="text-sm font-semibold text-[#34445a]">Active</h2>
          <div className="mt-3 space-y-3">
          {activeRequests.map((request) => (
            <RequestSummaryCard key={request.id} request={request} />
          ))}
          </div>
        </section>}
        {completedRequests.length > 0 && <section aria-labelledby="completed-requests-title">
          <h2 id="completed-requests-title" className="text-sm font-semibold text-[#34445a]">Completed</h2>
          <div className="mt-3 space-y-3">
            {completedRequests.map((request) => <RequestSummaryCard key={request.id} request={request} />)}
          </div>
        </section>}
      </>) : (
        <StaffEmptyState title="No requests yet" description="Requests you submit will appear here." />
      )}
    </div>
  );
}

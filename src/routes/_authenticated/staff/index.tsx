import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Activity, CheckCircle2, Clock3 } from "lucide-react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { useAuth } from "@/hooks/use-auth";
import { getStaffDashboardFn } from "@/lib/supply-requests.functions";
import { RequestSummaryCard } from "@/components/staff/RequestSummaryCard";
import { StaffEmptyState } from "@/components/staff/StaffEmptyState";
import { StaffHeader } from "@/components/staff/StaffHeader";
import { StaffPrimaryAction } from "@/components/staff/StaffPrimaryAction";
import { StaffSummaryCard } from "@/components/staff/StaffSummaryCard";

export const Route = createFileRoute("/_authenticated/staff/")({
  head: () => ({ meta: [{ title: "Staff — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: StaffHome,
});

function StaffHome() {
  const { active } = useActiveOrg();
  const { user } = useAuth();
  const fetcher = useServerFn(getStaffDashboardFn);
  const q = useQuery({
    queryKey: ["me", active?.organizationId, "requests"],
    queryFn: () => fetcher({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });
  const firstName = user?.user_metadata?.full_name?.split(" ")[0];
  const hour = new Date().getHours();
  const greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";

  return (
    <div className="space-y-8">
      <StaffHeader greeting={`${greeting}${firstName ? `, ${firstName}` : ""}`} team={active?.organizationName ?? "Medical Team"} />

      <StaffPrimaryAction />

      <section aria-labelledby="request-summary-title">
        <h2 id="request-summary-title" className="text-sm font-semibold text-[#34445a]">Your Requests</h2>
        <div className="mt-3 grid grid-cols-3 gap-2.5">
          <StaffSummaryCard label="Active" value={q.data?.summary.activeRequests ?? 0} icon={<Activity className="size-4" aria-hidden="true" />} />
          <StaffSummaryCard label="Ready" value={q.data?.summary.readyRequests ?? 0} icon={<Clock3 className="size-4" aria-hidden="true" />} />
          <StaffSummaryCard label="Completed" value={q.data?.summary.completedRequests ?? 0} icon={<CheckCircle2 className="size-4" aria-hidden="true" />} />
        </div>
      </section>

      {q.data && q.data.attentionItems.length > 0 && (
        <section aria-labelledby="attention-title">
          <h2 id="attention-title" className="text-sm font-semibold text-[#34445a]">Needs attention</h2>
          <div className="mt-3 space-y-3">
            {q.data.attentionItems.map((request) => <RequestSummaryCard key={request.id} request={request} />)}
          </div>
        </section>
      )}

      <section aria-labelledby="recent-title">
        <div className="flex items-center justify-between">
          <h2 id="recent-title" className="text-sm font-semibold text-[#34445a]">Recent Requests</h2>
          <Link to="/staff/requests" className="min-h-11 px-1 py-3 text-xs font-semibold text-[#d95700]">
            View all
          </Link>
        </div>
        {(q.data?.recentRequests.length ?? 0) > 0 ? (
          <div className="mt-2 space-y-3">
            {q.data?.recentRequests.slice(0, 5).map((request) => (
              <RequestSummaryCard key={request.id} request={request} />
            ))}
          </div>
        ) : (
          <div className="mt-2">
            <StaffEmptyState title="No requests yet" description="Your recent supply requests will appear here." />
          </div>
        )}
      </section>
    </div>
  );
}

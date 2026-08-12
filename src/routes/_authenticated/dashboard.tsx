import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { ArrowRight, CheckCircle2, ClipboardCheck, PackageCheck, Truck } from "lucide-react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { getAdminSupplyRequestDashboardFn } from "@/lib/supply-requests.functions";

export const Route = createFileRoute("/_authenticated/dashboard")({
  head: () => ({ meta: [{ title: "Dashboard — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Dashboard,
});

function Dashboard() {
  const { active } = useActiveOrg();
  const fetcher = useServerFn(getAdminSupplyRequestDashboardFn);
  const queue = useQuery({
    queryKey: ["org", active?.organizationId, "requests"],
    queryFn: () => fetcher({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });

  const summary = queue.data?.summary;
  return (
    <div className="min-h-screen bg-[#f5f7f9] px-4 py-8 sm:px-6 lg:px-10">
      <div className="mx-auto max-w-6xl">
        <p className="text-xs font-semibold uppercase tracking-[0.15em] text-[#718092]">Overview</p>
        <h1 className="mt-1 text-3xl font-semibold tracking-tight text-[#102a49]">{active?.organizationName}</h1>

        <section className="mt-8 rounded-2xl border border-[#dfe5eb] bg-white p-5 shadow-[0_5px_20px_rgba(16,42,73,0.04)] sm:p-6" aria-labelledby="supply-operations-title">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div><h2 id="supply-operations-title" className="text-lg font-semibold text-[#102a49]">Supply Operations</h2><p className="mt-1 text-sm text-[#697687]">Current request workload by next operational step.</p></div>
            <Link to="/supply-requests" className="inline-flex min-h-11 items-center gap-2 self-start rounded-lg bg-[#102a49] px-4 text-sm font-semibold text-white hover:bg-[#193b61]">View Supply Requests <ArrowRight className="size-4" /></Link>
          </div>
          {queue.isLoading && <p className="mt-6 text-sm text-[#697687]">Loading supply operations…</p>}
          {queue.isError && <p role="alert" className="mt-6 rounded-lg bg-[#fff0f1] p-3 text-sm text-[#a83340]">Could not load supply operations.</p>}
          <div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <OperationMetric label="Needs Review" value={summary?.needsReview ?? 0} icon={<ClipboardCheck className="size-4" />} />
            <OperationMetric label="Awaiting Order" value={summary?.awaitingOrder ?? 0} icon={<PackageCheck className="size-4" />} />
            <OperationMetric label="Awaiting Delivery" value={summary?.awaitingDelivery ?? 0} icon={<Truck className="size-4" />} />
            <OperationMetric label="Ready for Staff" value={summary?.readyForStaff ?? 0} icon={<CheckCircle2 className="size-4" />} />
          </div>
          <p className="mt-4 text-xs text-[#7a8592]">Completed requests: {summary?.completed ?? 0}</p>
        </section>
      </div>
    </div>
  );
}

function OperationMetric({ label, value, icon }: { label: string; value: number; icon: React.ReactNode }) {
  return <div className="rounded-xl border border-[#e2e7ec] bg-[#fafbfc] p-4"><div className="flex items-center justify-between text-sm font-medium text-[#5e6d7e]"><span>{label}</span>{icon}</div><div className="mt-4 text-3xl font-semibold tabular-nums text-[#102a49]">{value}</div></div>;
}

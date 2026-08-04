import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useActiveOrg } from "@/hooks/use-active-org";
import { listOrgRequestsFn } from "@/lib/supply-requests.functions";

export const Route = createFileRoute("/_authenticated/dashboard")({
  head: () => ({ meta: [{ title: "Dashboard — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Dashboard,
});

function Dashboard() {
  const { active } = useActiveOrg();
  const fetcher = useServerFn(listOrgRequestsFn);
  const q = useQuery({
    queryKey: ["org", active?.organizationId, "requests"],
    queryFn: () => fetcher({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });

  const openCount = (q.data ?? []).filter((r) =>
    ["submitted", "under_review", "approved", "ordered"].includes(r.status),
  ).length;

  return (
    <div className="max-w-5xl mx-auto px-6 py-8">
      <div className="text-sm text-muted-foreground">Overview</div>
      <h1 className="mt-1 text-2xl font-semibold">{active?.organizationName}</h1>
      <div className="mt-6 grid grid-cols-1 md:grid-cols-3 gap-3">
        <Stat label="Open requests" value={openCount} />
        <Stat label="Total requests" value={q.data?.length ?? 0} />
        <Stat label="Your role" value={active?.role ?? "—"} />
      </div>
      <p className="mt-8 text-sm text-muted-foreground">
        Invoice management, purchasing analytics, and dashboards come in Phase 2.
      </p>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-xl border bg-card p-4">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="mt-1 text-2xl font-semibold">{value}</div>
    </div>
  );
}
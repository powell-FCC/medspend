import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { ClipboardList } from "lucide-react";
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
      <div className="mt-8">
        {q.isLoading && <p className="py-8 text-center text-sm text-muted-foreground">Loading requests...</p>}
        {q.isError && (
          <div role="alert" className="rounded-xl border border-destructive/40 bg-destructive/5 px-5 py-4">
            <p className="font-medium text-destructive">Could not load supply requests</p>
            <p className="mt-1 text-sm text-muted-foreground">{q.error instanceof Error ? q.error.message : "An unexpected error occurred."}</p>
          </div>
        )}
        {q.isSuccess && q.data.length === 0 && (
          <div className="rounded-xl border border-dashed bg-card px-6 py-12 text-center">
            <span className="mx-auto flex h-11 w-11 items-center justify-center rounded-full bg-muted"><ClipboardList className="h-5 w-5 text-muted-foreground" /></span>
            <p className="mt-4 font-medium">No supply requests yet.</p>
            <p className="mx-auto mt-1 max-w-md text-sm text-muted-foreground">New supply requests for this organization will appear here.</p>
          </div>
        )}
      </div>
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

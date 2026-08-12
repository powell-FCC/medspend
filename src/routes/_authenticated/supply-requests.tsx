import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { ClipboardList, RefreshCw } from "lucide-react";
import { useState } from "react";
import { AdminQueueTabs, adminQueueLabel, type AdminQueueKey } from "@/components/admin/supply-requests/AdminQueueTabs";
import { AdminRequestCard } from "@/components/admin/supply-requests/AdminRequestCard";
import { AdminRequestDetail } from "@/components/admin/supply-requests/AdminRequestDetail";
import { useActiveOrg } from "@/hooks/use-active-org";
import { getAdminSupplyRequestDashboardFn, listRequestUpdatesFn, updateRequestStatusFn } from "@/lib/supply-requests.functions";
import type { AdminSupplyRequestViewModel } from "@/supply-requests/admin-dashboard";
import type { SupplyRequestStatus } from "@/supply-requests/lifecycle";

export const Route = createFileRoute("/_authenticated/supply-requests")({
  head: () => ({ meta: [{ title: "Supply Requests — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Page,
});

function Page() {
  const { active } = useActiveOrg();
  const fetchDashboard = useServerFn(getAdminSupplyRequestDashboardFn);
  const fetchUpdates = useServerFn(listRequestUpdatesFn);
  const updateStatus = useServerFn(updateRequestStatusFn);
  const queryClient = useQueryClient();
  const [queue, setQueue] = useState<AdminQueueKey>("needsReview");
  const [selected, setSelected] = useState<AdminSupplyRequestViewModel | null>(null);
  const [busy, setBusy] = useState(false);
  const [mutationError, setMutationError] = useState<string | null>(null);

  const dashboard = useQuery({
    queryKey: ["org", active?.organizationId, "requests"],
    queryFn: () => fetchDashboard({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });
  const updates = useQuery({
    queryKey: ["org", active?.organizationId, "requests", selected?.id, "updates"],
    queryFn: () => fetchUpdates({ data: { requestId: selected!.id } }),
    enabled: !!selected,
  });

  async function transition(status: SupplyRequestStatus, staffMessage: string, internalNote: string) {
    if (!selected || !active) return;
    setBusy(true);
    setMutationError(null);
    try {
      await updateStatus({ data: {
        organizationId: active.organizationId,
        id: selected.id,
        status,
        staffVisibleNote: staffMessage.trim() || null,
        internalNote: internalNote.trim() || null,
      } });
      await queryClient.invalidateQueries({ queryKey: ["org", active.organizationId, "requests"] });
      setSelected(null);
    } catch (error) {
      setMutationError(error instanceof Error ? error.message : "The request could not be updated.");
    } finally {
      setBusy(false);
    }
  }

  const requests = dashboard.data?.queues[queue] ?? [];

  return (
    <div className="min-h-screen bg-[#f5f7f9] px-4 py-8 sm:px-6 lg:px-10">
      <div className="mx-auto max-w-7xl">
        <header className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p className="text-xs font-semibold uppercase tracking-[0.15em] text-[#718092]">Operations</p>
            <h1 className="mt-1 text-3xl font-semibold tracking-tight text-[#102a49]">Supply Requests</h1>
            <p className="mt-2 text-sm text-[#657284]">Review requests, coordinate next steps, and keep staff informed.</p>
          </div>
          <button type="button" onClick={() => dashboard.refetch()} disabled={dashboard.isFetching} className="inline-flex min-h-11 items-center justify-center gap-2 self-start rounded-lg border border-[#d9e0e7] bg-white px-4 text-sm font-semibold text-[#3c4f65] hover:bg-[#f9fafb] disabled:opacity-60">
            <RefreshCw className={`size-4 ${dashboard.isFetching ? "animate-spin" : ""}`} /> Refresh
          </button>
        </header>

        <div className="mt-8">
          {dashboard.data && <AdminQueueTabs active={queue} summary={dashboard.data.summary} onChange={setQueue} />}
        </div>

        <section className="mt-8" aria-labelledby="active-queue-heading">
          <div className="flex items-center justify-between">
            <h2 id="active-queue-heading" className="text-lg font-semibold text-[#223850]">{adminQueueLabel(queue)}</h2>
            <span className="text-sm text-[#75808e]">{requests.length} request{requests.length === 1 ? "" : "s"}</span>
          </div>

          {dashboard.isLoading && <div className="mt-4 rounded-2xl border border-[#dfe5eb] bg-white p-8 text-center text-sm text-[#697687]">Loading request queue…</div>}
          {dashboard.isError && <div role="alert" className="mt-4 rounded-2xl border border-[#efc8cd] bg-[#fff4f5] p-5"><div className="font-semibold text-[#a83340]">Could not load supply requests</div><p className="mt-1 text-sm text-[#76545a]">{dashboard.error instanceof Error ? dashboard.error.message : "Please try again."}</p></div>}
          {dashboard.isSuccess && requests.length === 0 && <div className="mt-4 rounded-2xl border border-dashed border-[#ccd5de] bg-white px-6 py-14 text-center"><span className="mx-auto flex size-12 items-center justify-center rounded-full bg-[#eef2f6] text-[#687789]"><ClipboardList className="size-5" /></span><p className="mt-4 font-semibold text-[#263c54]">This queue is clear</p><p className="mt-1 text-sm text-[#75808e]">Requests will appear here when they reach this stage.</p></div>}
          <div className="mt-4 grid gap-3">
            {requests.map((request) => <AdminRequestCard key={request.id} request={request} onOpen={(item) => { setMutationError(null); setSelected(item); }} />)}
          </div>
        </section>
      </div>

      {selected && <AdminRequestDetail request={selected} updates={updates.data ?? []} loadingUpdates={updates.isLoading} busy={busy} error={mutationError} onClose={() => setSelected(null)} onTransition={transition} />}
    </div>
  );
}

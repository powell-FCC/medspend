import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { RefreshCw } from "lucide-react";
import { useRef, useState } from "react";
import { AdminQueueTabs, adminQueueLabel, type AdminQueueKey } from "@/components/admin/supply-requests/AdminQueueTabs";
import { AdminRequestCard } from "@/components/admin/supply-requests/AdminRequestCard";
import { AdminRequestDetail } from "@/components/admin/supply-requests/AdminRequestDetail";
import { useActiveOrg } from "@/hooks/use-active-org";
import { decideSupplyRequestFn, getAdminSupplyRequestDashboardFn, listRequestUpdatesFn, updateRequestStatusFn } from "@/lib/supply-requests.functions";
import type { SupplyRequestStatus } from "@/supply-requests/lifecycle";

export const Route = createFileRoute("/_authenticated/supply-requests")({
  head: () => ({ meta: [{ title: "Request Inbox — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Page,
});

function Page() {
  const { active } = useActiveOrg();
  const fetchDashboard = useServerFn(getAdminSupplyRequestDashboardFn);
  const fetchUpdates = useServerFn(listRequestUpdatesFn);
  const updateStatus = useServerFn(updateRequestStatusFn);
  const decide = useServerFn(decideSupplyRequestFn);
  const queryClient = useQueryClient();
  const [queue, setQueue] = useState<AdminQueueKey>("needsReview");
  const [selection, setSelection] = useState<{ organizationId: string; id: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const submitting = useRef(false);
  const [mutationError, setMutationError] = useState<string | null>(null);
  const [feedback, setFeedback] = useState<string | null>(null);
  const dashboard = useQuery({
    queryKey: ["org", active?.organizationId, "requests"],
    queryFn: () => fetchDashboard({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });
  const selected = selection?.organizationId === active?.organizationId
    ? Object.values(dashboard.data?.queues ?? {}).flat().find((request) => request.id === selection?.id)
    : undefined;
  const updates = useQuery({
    queryKey: ["org", active?.organizationId, "requests", selected?.id, "updates"],
    queryFn: () => fetchUpdates({ data: { requestId: selected!.id } }),
    enabled: !!active && !!selected,
  });

  async function transition(status: SupplyRequestStatus, staffMessage: string, internalNote: string) {
    if (!selected || !active || submitting.current) return;
    submitting.current = true;
    setBusy(true);
    setMutationError(null);
    setFeedback(null);
    const organizationId = active.organizationId;
    const data = {
      organizationId, id: selected.id,
      staffVisibleNote: staffMessage.trim() || null,
      internalNote: internalNote.trim() || null,
    };
    try {
      const pending = selected.lifecycleStatus === "submitted" || selected.lifecycleStatus === "under_review";
      if (pending && (status === "approved" || status === "denied")) {
        await decide({ data: { ...data, decision: status } });
      } else {
        await updateStatus({ data: { ...data, status } });
      }
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["org", organizationId, "requests"] }),
        queryClient.invalidateQueries({ queryKey: ["me", organizationId, "requests"] }),
      ]);
      setSelection(null);
      setFeedback(status === "approved" ? "Request approved. Staff can see the decision."
        : status === "denied" ? "Request declined. Your reason is visible to staff." : "Request updated.");
    } catch (error) {
      setMutationError(error instanceof Error ? error.message : "The request could not be updated.");
      await queryClient.invalidateQueries({ queryKey: ["org", organizationId, "requests"] });
    } finally {
      submitting.current = false;
      setBusy(false);
    }
  }

  const requests = dashboard.data?.queues[queue] ?? [];
  return (
    <div className="min-h-screen bg-[#f5f7f9] px-4 py-6 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl">
        <header className="flex items-start justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight text-[#102a49]">Request Inbox</h1>
            <p className="mt-1 text-sm text-[#657284]">Review what staff need. Approve or decline with a clear decision.</p>
          </div>
          <button type="button" onClick={() => dashboard.refetch()} disabled={dashboard.isFetching} className="inline-flex min-h-11 shrink-0 items-center gap-2 rounded-lg border border-[#d9e0e7] bg-white px-3 text-sm font-medium text-[#3c4f65] focus-visible:ring-2 focus-visible:ring-[#f56600] disabled:opacity-60">
            <RefreshCw aria-hidden="true" className={"size-4 " + (dashboard.isFetching ? "animate-spin" : "")} /><span className="hidden sm:inline">Refresh</span><span className="sr-only sm:hidden">Refresh requests</span>
          </button>
        </header>
        {feedback && <p role="status" className="mt-4 rounded-lg border border-[#cbe2d5] bg-[#f0f8f3] p-3 text-sm text-[#286443]">{feedback}</p>}
        <div className="mt-5">
          {dashboard.data && <AdminQueueTabs active={queue} summary={dashboard.data.summary} onChange={setQueue} />}
        </div>
        <section id="request-queue" role="tabpanel" aria-labelledby={dashboard.data ? "queue-" + queue : "active-queue-heading"} className="mt-5">
          <div className="mb-3 flex items-center justify-between gap-4">
            <h2 id="active-queue-heading" className="text-sm font-semibold text-[#223850]">{queue === "needsReview" ? "Awaiting your decision" : adminQueueLabel(queue)}</h2>
            <span className="text-xs text-[#697687]">{requests.length} request{requests.length === 1 ? "" : "s"}</span>
          </div>
          {dashboard.isLoading && <div role="status" className="rounded-lg border border-[#dfe5eb] bg-white p-8 text-sm text-[#697687]">Loading request inbox…</div>}
          {dashboard.isError && <div role="alert" className="mb-4 rounded-lg border border-[#efc8cd] bg-[#fff4f5] p-4"><p className="font-semibold text-[#a83340]">Could not load requests</p><p className="mt-1 text-sm text-[#76545a]">Please refresh to try again. Any previously loaded requests remain below.</p></div>}
          {dashboard.isSuccess && requests.length === 0 && <div className="rounded-lg border border-dashed border-[#ccd5de] bg-white px-6 py-10 text-center"><p className="font-semibold text-[#263c54]">{queue === "needsReview" ? "You're all caught up" : "No requests in this queue"}</p><p className="mt-1 text-sm text-[#75808e]">{queue === "needsReview" ? "New staff requests will appear here for your decision." : "Other requests are available in the queues above."}</p></div>}
          {requests.length > 0 && <div className="overflow-hidden rounded-lg border border-[#dfe5eb]">
            <div aria-hidden="true" className="hidden gap-4 border-b border-[#dfe5eb] bg-[#edf1f5] px-4 py-2 text-xs font-medium text-[#657284] lg:grid lg:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)_minmax(0,1.1fr)_8rem]"><span>Requested items</span><span>Requester</span><span>Submitted / context</span><span>Decision</span></div>
            {requests.map((request) => <AdminRequestCard key={request.id} request={request} onOpen={(item) => { setMutationError(null); setSelection({ organizationId: active!.organizationId, id: item.id }); }} />)}
          </div>}
        </section>
      </div>
      {selected && <AdminRequestDetail key={selected.id} request={selected} updates={updates.data ?? []} loadingUpdates={updates.isLoading} updatesError={updates.isError} onRetryUpdates={() => void updates.refetch()} busy={busy} error={mutationError} onClose={() => { if (!submitting.current) setSelection(null); }} onTransition={transition} />}
    </div>
  );
}

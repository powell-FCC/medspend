import * as Dialog from "@radix-ui/react-dialog";
import { X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { AdminActionButton } from "@/components/admin/supply-requests/AdminActionButton";
import { AdminMessagePanel } from "@/components/admin/supply-requests/AdminMessagePanel";
import type { SupplyRequestStatus } from "@/supply-requests/lifecycle";
import { translateAdminRequestStatus, type AdminSupplyRequestViewModel } from "@/supply-requests/admin-dashboard";
import { requestItemIsCustom, requestTimestamp } from "@/supply-requests/admin-request-inbox";

type Update = {
  id: string;
  statusFrom: SupplyRequestStatus | null;
  statusTo: SupplyRequestStatus | null;
  staffVisibleNote: string | null;
  internalNote?: string | null;
  createdAt: string;
};

const primaryTransition: Partial<Record<SupplyRequestStatus, SupplyRequestStatus>> = {
  submitted: "approved", under_review: "approved", approved: "ordered",
  ordered: "received", received: "completed",
};
const primaryActionLabel: Partial<Record<SupplyRequestStatus, string>> = {
  submitted: "Approve", under_review: "Approve", approved: "Mark Ordered",
  ordered: "Mark Received", received: "Complete Request",
};

export function AdminRequestDetail({ request, updates, loadingUpdates, updatesError, onRetryUpdates,
  busy, error, onClose, onTransition,
}: {
  request: AdminSupplyRequestViewModel;
  updates: Update[];
  loadingUpdates: boolean;
  updatesError: boolean;
  onRetryUpdates: () => void;
  busy: boolean;
  error: string | null;
  onClose: () => void;
  onTransition: (status: SupplyRequestStatus, staffMessage: string, internalNote: string) => void;
}) {
  const [staffMessage, setStaffMessage] = useState("");
  const [internalNote, setInternalNote] = useState("");
  const [mode, setMode] = useState<"review" | "decline">("review");
  const [denialError, setDenialError] = useState<string | null>(null);
  const messageRef = useRef<HTMLTextAreaElement>(null);
  const pending = request.lifecycleStatus === "submitted" || request.lifecycleStatus === "under_review";
  const declining = pending && mode === "decline";
  const nextStatus = primaryTransition[request.lifecycleStatus];

  useEffect(() => {
    if (declining) messageRef.current?.focus();
  }, [declining]);

  function submit(event: React.FormEvent) {
    event.preventDefault();
    if (busy || !nextStatus) return;
    if (declining && !staffMessage.trim()) {
      setDenialError("Add a short reason so staff understand the decision.");
      messageRef.current?.focus();
      return;
    }
    setDenialError(null);
    onTransition(declining ? "denied" : nextStatus, staffMessage, internalNote);
  }

  return (
    <Dialog.Root open onOpenChange={(open) => { if (!open && !busy) onClose(); }}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-[#071d38]/35" />
        <Dialog.Content aria-describedby="request-detail-description" onEscapeKeyDown={(event) => { if (busy) event.preventDefault(); }} onInteractOutside={(event) => { if (busy) event.preventDefault(); }} className="fixed inset-y-0 right-0 z-50 flex w-full max-w-3xl flex-col bg-white shadow-2xl focus:outline-none">
          <header className="flex shrink-0 items-start justify-between gap-3 border-b border-[#dfe5eb] px-5 py-4">
            <div className="min-w-0">
              <p className="text-xs font-semibold text-[#697687]">{request.statusLabel} · {request.itemCount} item{request.itemCount === 1 ? "" : "s"}</p>
              <Dialog.Title className="mt-1 text-xl font-semibold text-[#102a49] [overflow-wrap:anywhere]">{request.itemName}</Dialog.Title>
              <Dialog.Description id="request-detail-description" className="sr-only">Review the requested items and staff context before making a decision.</Dialog.Description>
            </div>
            <Dialog.Close disabled={busy} aria-label="Close request details" className="flex size-11 shrink-0 items-center justify-center rounded-lg text-[#657284] hover:bg-[#f0f3f6] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f56600] disabled:opacity-50"><X className="size-5" /></Dialog.Close>
          </header>
          <form onSubmit={submit} noValidate className="flex min-h-0 flex-1 flex-col">
            <div className="min-h-0 flex-1 space-y-6 overflow-y-auto p-5 sm:p-6">
              <dl className="grid grid-cols-2 gap-4 text-sm sm:grid-cols-3">
                <Detail label="Requested by" value={request.requesterName} />
                {request.requesterEmail && <Detail label="Email" value={request.requesterEmail} />}
                <Detail label="Submitted" value={requestTimestamp(request.submittedAt)} />
                <Detail label="Team" value={request.team ?? "Not specified"} />
                <Detail label="Location" value={request.location ?? "Not specified"} />
                <Detail label="Request type" value={request.requestTypeLabel} />
              </dl>

              <section aria-labelledby="requested-items-heading">
                <h3 id="requested-items-heading" className="border-b border-[#dfe5eb] pb-2 text-sm font-semibold text-[#102a49]">Requested items · {request.itemCount}</h3>
                <ul aria-label="Requested items" className="divide-y divide-[#e6ebf0]">
                  {request.items.map((item) => <li key={item.id} className="flex items-start justify-between gap-4 py-3">
                    <div className="min-w-0">
                      <div className="font-medium text-[#293e55] [overflow-wrap:anywhere]">{item.name}</div>
                      {requestItemIsCustom(item) ? <p className="mt-1 text-xs text-[#697687]">Custom item</p> : <>
                        {(item.manufacturer || item.vendorName) && <p className="mt-1 text-xs leading-5 text-[#697687] [overflow-wrap:anywhere]">{[item.manufacturer, item.vendorName].filter((value, index, values) => value && values.indexOf(value) === index).join(" · ")}</p>}
                        {(item.vendorSku || item.packageDisplay) && <p className="text-xs leading-5 text-[#697687] [overflow-wrap:anywhere]">{[item.vendorSku ? "SKU " + item.vendorSku : null, item.packageDisplay].filter(Boolean).join(" · ")}</p>}
                      </>}
                    </div>
                    <div className="shrink-0 text-right text-sm"><span className="text-xs text-[#697687]">Qty </span><span className="font-semibold tabular-nums text-[#293e55]">{item.quantity}</span>{item.unit && <p className="mt-1 text-xs text-[#697687]">{item.unit}</p>}</div>
                  </li>)}
                </ul>
              </section>

              <section aria-labelledby="staff-note-heading">
                <h3 id="staff-note-heading" className="text-sm font-semibold text-[#102a49]">Staff note</h3>
                <p className="mt-2 whitespace-pre-wrap rounded-lg bg-[#f5f7f9] p-3 text-sm leading-6 text-[#526174] [overflow-wrap:anywhere]">{request.staffNote || "No note provided."}</p>
              </section>

              {nextStatus && <AdminMessagePanel staffMessage={staffMessage} internalNote={internalNote}
                onStaffMessageChange={(value) => { setStaffMessage(value); if (value.trim()) setDenialError(null); }}
                onInternalNoteChange={setInternalNote} staffMessageRequired={declining} disabled={busy} staffMessageRef={messageRef}
                staffGuidance={declining ? "Explain why this request is being declined." : pending ? "Optional context for your decision." : "Share any useful update."}
                staffPlaceholder={declining ? "We already have these supplies in storage." : pending ? "Optional message about this request" : "When or where to expect these supplies"}
              />}

              <details className="border-t border-[#dfe5eb] pt-3">
                <summary className="min-h-11 cursor-pointer py-2 text-sm font-semibold text-[#526174]">Activity &amp; messages</summary>
                {loadingUpdates ? <p role="status" className="py-3 text-sm text-[#697687]">Loading updates…</p> : updatesError ? <div role="alert" className="py-3 text-sm text-[#a83340]">Could not load activity. <button type="button" onClick={onRetryUpdates} className="min-h-11 underline">Try again</button></div> : (
                  <ol className="space-y-4 border-l border-[#dce2e8] pl-4 text-sm">
                    <li><div className="font-medium text-[#263b53]">Submitted</div><time dateTime={request.submittedAt} className="text-xs text-[#75808e]">{requestTimestamp(request.submittedAt)}</time></li>
                    {updates.map((update) => <li key={update.id}>
                      <div className="font-medium text-[#263b53]">{update.statusTo ? translateAdminRequestStatus(update.statusTo).statusLabel : "Update"}</div>
                      <time dateTime={update.createdAt} className="text-xs text-[#75808e]">{requestTimestamp(update.createdAt)}</time>
                      {update.staffVisibleNote && <div className="mt-2 rounded border border-[#edd8c9] bg-[#fff8f3] p-3"><div className="text-xs font-semibold text-[#8c4b1f]">Staff Communication</div><p className="mt-1 whitespace-pre-wrap text-[#624b3b] [overflow-wrap:anywhere]">{update.staffVisibleNote}</p></div>}
                      {update.internalNote && <div className="mt-2 rounded border border-[#dce2e8] bg-[#f7f9fb] p-3"><div className="text-xs font-semibold text-[#586779]">Internal Note · Admins only</div><p className="mt-1 whitespace-pre-wrap text-[#526174] [overflow-wrap:anywhere]">{update.internalNote}</p></div>}
                    </li>)}
                  </ol>
                )}
              </details>
            </div>
            <footer className="shrink-0 border-t border-[#dfe5eb] bg-white px-5 py-4">
              {(error || denialError) && <p role="alert" className="mb-3 rounded-lg bg-[#fff0f1] p-3 text-sm text-[#a83340]">{error ?? denialError}</p>}
              <div className="flex flex-wrap items-center justify-end gap-2">
                {pending && !declining && <AdminActionButton variant="danger" disabled={busy} onClick={() => setMode("decline")}>Decline</AdminActionButton>}
                {declining && <AdminActionButton variant="secondary" disabled={busy} onClick={() => { setMode("review"); setDenialError(null); }}>Cancel</AdminActionButton>}
                {nextStatus && <AdminActionButton type="submit" variant={declining ? "danger" : "primary"} disabled={busy}>{busy ? "Saving…" : declining ? "Decline Request" : primaryActionLabel[request.lifecycleStatus]}</AdminActionButton>}
                {!nextStatus && <AdminActionButton variant="secondary" onClick={onClose}>Close</AdminActionButton>}
              </div>
            </footer>
          </form>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return <div className="min-w-0"><dt className="text-xs text-[#697687]">{label}</dt><dd className="mt-1 font-medium text-[#293e55] [overflow-wrap:anywhere]">{value}</dd></div>;
}

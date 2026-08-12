import { X } from "lucide-react";
import { useState } from "react";
import { AdminActionButton } from "@/components/admin/supply-requests/AdminActionButton";
import { AdminMessagePanel } from "@/components/admin/supply-requests/AdminMessagePanel";
import { allowedNextSupplyRequestStatuses, type SupplyRequestStatus } from "@/supply-requests/lifecycle";
import { translateAdminRequestStatus, type AdminSupplyRequestViewModel } from "@/supply-requests/admin-dashboard";

type Update = {
  id: string;
  statusFrom: SupplyRequestStatus | null;
  statusTo: SupplyRequestStatus | null;
  staffVisibleNote: string | null;
  internalNote?: string | null;
  createdAt: string;
};

const primaryTransition: Partial<Record<SupplyRequestStatus, SupplyRequestStatus>> = {
  submitted: "under_review",
  under_review: "approved",
  approved: "ordered",
  ordered: "received",
  received: "completed",
};

const primaryActionLabel: Partial<Record<SupplyRequestStatus, string>> = {
  submitted: "Review Request",
  under_review: "Approve Request",
  approved: "Mark Ordered",
  ordered: "Mark Received",
  received: "Complete Request",
};

const communicationGuidance: Record<SupplyRequestStatus, { guidance: string; placeholder: string }> = {
  submitted: { guidance: "Optionally let the requester know their request is being reviewed.", placeholder: "We're reviewing your request." },
  under_review: { guidance: "Optionally confirm approval and what happens next.", placeholder: "Approved. Ordering today." },
  approved: { guidance: "What should staff know about the order?", placeholder: "Arriving Friday morning." },
  ordered: { guidance: "Notify the requester that supplies are ready.", placeholder: "Available in medical storage." },
  received: { guidance: "Optionally confirm that the request has been fulfilled.", placeholder: "Your request has been completed." },
  completed: { guidance: "This request is closed.", placeholder: "" },
  denied: { guidance: "This request is closed.", placeholder: "" },
};

export function AdminRequestDetail({
  request,
  updates,
  loadingUpdates,
  busy,
  error,
  onClose,
  onTransition,
}: {
  request: AdminSupplyRequestViewModel;
  updates: Update[];
  loadingUpdates: boolean;
  busy: boolean;
  error: string | null;
  onClose: () => void;
  onTransition: (status: SupplyRequestStatus, staffMessage: string, internalNote: string) => void;
}) {
  const [staffMessage, setStaffMessage] = useState("");
  const [internalNote, setInternalNote] = useState("");
  const [denialError, setDenialError] = useState<string | null>(null);
  const nextStatus = primaryTransition[request.lifecycleStatus];
  const canDeny = allowedNextSupplyRequestStatuses(request.lifecycleStatus).includes("denied");
  const guidance = communicationGuidance[request.lifecycleStatus];

  function deny() {
    if (!staffMessage.trim()) {
      setDenialError("Add a message explaining why this request cannot be fulfilled.");
      return;
    }
    setDenialError(null);
    onTransition("denied", staffMessage, internalNote);
  }

  return (
    <div className="fixed inset-0 z-50 flex justify-end bg-[#071d38]/35 backdrop-blur-[2px]" onMouseDown={(event) => { if (event.currentTarget === event.target) onClose(); }}>
      <section role="dialog" aria-modal="true" aria-labelledby="request-detail-title" className="h-full w-full max-w-xl overflow-y-auto bg-white shadow-2xl">
        <div className="sticky top-0 z-10 flex items-center justify-between border-b border-[#e2e7ec] bg-white/95 px-5 py-4 backdrop-blur">
          <div>
            <p className="text-xs font-semibold uppercase tracking-[0.13em] text-[#718092]">Request Detail</p>
            <h2 id="request-detail-title" className="mt-1 text-xl font-semibold text-[#102a49]">{request.itemName}</h2>
          </div>
          <button type="button" onClick={onClose} className="flex size-11 items-center justify-center rounded-full text-[#657284] hover:bg-[#f0f3f6]" aria-label="Close request details"><X className="size-5" /></button>
        </div>

        <div className="space-y-7 p-5 sm:p-6">
          <section className="rounded-2xl bg-[#102a49] p-5 text-white">
            <div className="flex flex-wrap items-start justify-between gap-4">
              <div><div className="text-sm text-white/65">Current state</div><div className="mt-1 text-lg font-semibold">{request.statusLabel}</div></div>
              <div className="text-right"><div className="text-sm text-white/65">Quantity</div><div className="mt-1 font-semibold">{request.quantity ?? "—"}{request.quantity && request.unit ? ` ${request.unit}` : ""}</div></div>
            </div>
          </section>

          <section className="grid gap-4 rounded-xl border border-[#e1e6eb] p-4 text-sm sm:grid-cols-2">
            <Detail label="Requested by" value={request.requesterName} />
            {request.requesterEmail && <Detail label="Requester email" value={request.requesterEmail} />}
            <Detail label="Request type" value={request.requestTypeLabel} />
            <Detail label="Team" value={request.team ?? "Not specified"} />
            <Detail label="Location" value={request.location ?? "Not specified"} />
            <Detail label="Age" value={request.ageInDays === 0 ? "Today" : `${request.ageInDays} day${request.ageInDays === 1 ? "" : "s"}`} />
            <Detail label="Product" value={request.hasExistingProduct ? "Existing product" : "New item request"} />
          </section>

          <section className="rounded-xl border border-[#e1e6eb] p-4">
            <h3 className="font-semibold text-[#102a49]">Requested Items · {request.itemCount}</h3>
            <div className="mt-3 divide-y divide-[#edf0f3]">{request.items.map((item) => <div key={item.id} className="flex items-center justify-between py-3 text-sm"><span className="font-medium text-[#293e55]">{item.name}</span><span className="text-[#657284]">{item.quantity}{item.unit ? ` ${item.unit}` : ""}</span></div>)}</div>
          </section>

          {request.staffNote && <section><h3 className="font-semibold text-[#102a49]">Staff Note</h3><p className="mt-2 rounded-xl bg-[#f5f7f9] p-4 text-sm leading-6 text-[#526174]">{request.staffNote}</p></section>}

          <section>
            <h3 className="font-semibold text-[#102a49]">Timeline</h3>
            {loadingUpdates ? <p className="mt-3 text-sm text-[#697687]">Loading updates…</p> : (
              <ol className="mt-4 space-y-4 border-l border-[#dce2e8] pl-5">
                <li><div className="font-medium text-[#263b53]">Submitted</div><time className="text-xs text-[#75808e]">{new Date(request.submittedAt).toLocaleString()}</time></li>
                {updates.map((update) => <li key={update.id}>
                  <div className="font-medium text-[#263b53]">{update.statusTo ? translateAdminRequestStatus(update.statusTo).statusLabel : "Update"}</div>
                  <time className="text-xs text-[#75808e]">{new Date(update.createdAt).toLocaleString()}</time>
                  {update.staffVisibleNote && <div className="mt-2 rounded-lg border border-[#f3d1b9] bg-[#fff8f3] p-3"><div className="text-[0.68rem] font-semibold uppercase tracking-wide text-[#9a4a16]">Staff Communication</div><p className="mt-1 text-sm text-[#624b3b]">{update.staffVisibleNote}</p></div>}
                  {update.internalNote && <div className="mt-2 rounded-lg border border-[#dce2e8] bg-[#f7f9fb] p-3"><div className="text-[0.68rem] font-semibold uppercase tracking-wide text-[#586779]">Internal Note · Admins only</div><p className="mt-1 text-sm text-[#526174]">{update.internalNote}</p></div>}
                </li>)}
              </ol>
            )}
          </section>

          {nextStatus && <AdminMessagePanel staffMessage={staffMessage} internalNote={internalNote} onStaffMessageChange={(value) => { setStaffMessage(value); if (value.trim()) setDenialError(null); }} onInternalNoteChange={setInternalNote} staffGuidance={guidance.guidance} staffPlaceholder={guidance.placeholder} />}

          {(error || denialError) && <p role="alert" className="rounded-lg bg-[#fff0f1] p-3 text-sm text-[#a83340]">{error ?? denialError}</p>}

          <div className="flex flex-col-reverse gap-2 border-t border-[#e2e7ec] pt-5 sm:flex-row sm:justify-end">
            {canDeny && <AdminActionButton variant="danger" disabled={busy} onClick={deny}>Decline Request</AdminActionButton>}
            {nextStatus && <AdminActionButton disabled={busy} onClick={() => onTransition(nextStatus, staffMessage, internalNote)}>{busy ? "Updating…" : primaryActionLabel[request.lifecycleStatus]}</AdminActionButton>}
            {!nextStatus && <AdminActionButton variant="secondary" onClick={onClose}>Close</AdminActionButton>}
          </div>
        </div>
      </section>
    </div>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return <div><dt className="text-xs font-medium text-[#7a8592]">{label}</dt><dd className="mt-1 font-medium text-[#293e55]">{value}</dd></div>;
}

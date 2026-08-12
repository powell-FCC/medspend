import { Clock3, MapPin, Users } from "lucide-react";
import { AdminActionButton } from "@/components/admin/supply-requests/AdminActionButton";
import type { AdminSupplyRequestViewModel } from "@/supply-requests/admin-dashboard";

function ageLabel(days: number) {
  if (days === 0) return "New";
  if (days === 1) return "Waiting 1 day";
  return `Waiting ${days} days`;
}

function ageTone(days: number) {
  if (days >= 7) return "bg-[#fff1e8] text-[#9a430c]";
  if (days >= 2) return "bg-[#f5f1e8] text-[#755b25]";
  return "bg-[#eef4f7] text-[#526779]";
}

export function AdminRequestCard({
  request,
  onOpen,
}: {
  request: AdminSupplyRequestViewModel;
  onOpen: (request: AdminSupplyRequestViewModel) => void;
}) {
  return (
    <article className="rounded-2xl border border-[#dfe5eb] bg-white p-5 shadow-[0_5px_20px_rgba(16,42,73,0.045)]">
      <div className="flex flex-col gap-5 lg:flex-row lg:items-center">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="rounded-full bg-[#eef2f6] px-2.5 py-1 text-[0.68rem] font-semibold uppercase tracking-wide text-[#516176]">
              {request.statusLabel}
            </span>
            {request.isNewItem && (
              <span className="rounded-full bg-[#fff0e5] px-2.5 py-1 text-[0.68rem] font-semibold uppercase tracking-wide text-[#a84300]">
                New item
              </span>
            )}
          </div>
          <h2 className="mt-3 text-lg font-semibold tracking-tight text-[#102a49]">{request.itemName}</h2>
          <p className="mt-1 text-sm text-[#647183]">
            {request.quantity ?? "Quantity not specified"}{request.quantity && request.unit ? ` ${request.unit}` : ""}
          </p>
          <div className="mt-4 grid gap-2 text-sm text-[#536174] sm:grid-cols-3">
            <span className="flex items-center gap-2"><Users className="size-4 text-[#87919e]" />{request.requesterName}</span>
            {(request.team || request.location) && (
              <span className="flex items-center gap-2"><MapPin className="size-4 text-[#87919e]" />{[request.team, request.location].filter(Boolean).join(" · ")}</span>
            )}
            <span className={`flex w-fit items-center gap-2 rounded-full px-2.5 py-1 text-xs font-medium ${ageTone(request.ageInDays)}`}><Clock3 className="size-3.5" />{ageLabel(request.ageInDays)}</span>
          </div>
        </div>
        <div className="flex shrink-0 flex-col items-stretch gap-2 sm:flex-row lg:flex-col lg:items-end">
          <div className="text-xs font-medium text-[#778290]">Next action</div>
          {request.nextAction ? (
            <AdminActionButton onClick={() => onOpen(request)}>{request.nextAction}</AdminActionButton>
          ) : (
            <AdminActionButton variant="secondary" onClick={() => onOpen(request)}>View Details</AdminActionButton>
          )}
        </div>
      </div>
    </article>
  );
}

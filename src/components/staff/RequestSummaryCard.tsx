import { RequestStatusBadge } from "@/components/staff/RequestStatusBadge";
import type { StaffRequestViewModel } from "@/supply-requests/staff-dashboard";
import { Link } from "@tanstack/react-router";
import { ChevronRight } from "lucide-react";

function updatedLabel(value: string) {
  const date = new Date(value);
  const today = new Date();
  if (date.toDateString() === today.toDateString()) return "Updated today";
  return `Updated ${new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(date)}`;
}

export function RequestSummaryCard({ request }: { request: StaffRequestViewModel }) {
  return (
    <article className="rounded-[1.2rem] border border-[#e1e6ec] bg-white shadow-[0_5px_22px_rgba(7,29,56,0.045)]">
      <Link to="/staff/requests/$id" params={{ id: request.id }} className="flex min-h-24 items-center gap-3 rounded-[1.2rem] p-4 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f56600]">
        <div className="min-w-0 flex-1">
          <div className="truncate font-semibold text-[#071d38]">{request.itemName}</div>
          <div className="mt-1 text-sm text-[#657182]">
            {request.quantity ?? "Quantity not specified"}{request.quantity && request.unit ? ` ${request.unit}` : ""}
          </div>
          <div className="mt-2 text-xs text-[#7a8491]">{updatedLabel(request.lastUpdatedAt)}</div>
        </div>
        <div className="flex shrink-0 items-center gap-1.5">
          <RequestStatusBadge label={request.statusLabel} group={request.statusGroup} />
          <ChevronRight className="size-4 text-[#9aa3ad]" aria-hidden="true" />
        </div>
      </Link>
    </article>
  );
}

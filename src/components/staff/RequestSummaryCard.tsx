import { Link } from "@tanstack/react-router";
import { ChevronRight, MessageCircle } from "lucide-react";
import { RequestStatusBadge } from "@/components/staff/RequestStatusBadge";
import {
  describeRequestContents,
  type StaffRequestViewModel,
} from "@/supply-requests/staff-dashboard";

const shortDate = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });

function requestedOnLabel(value: string, today = new Date()) {
  const date = new Date(value);
  if (date.toDateString() === today.toDateString()) return "Requested today";
  return `Requested ${shortDate.format(date)}`;
}

// A request at a glance: when, how many items, what they were, and where it stands.
// The whole card opens the request.
export function RequestSummaryCard({ request }: { request: StaffRequestViewModel }) {
  const count = `${request.itemCount} ${request.itemCount === 1 ? "item" : "items"}`;
  return (
    <article className="rounded-2xl border border-[#e1e6ec] bg-white shadow-[0_4px_18px_rgba(7,29,56,0.04)] transition active:scale-[0.995]">
      <Link
        to="/staff/requests/$id"
        params={{ id: request.id }}
        aria-label={`View request: ${describeRequestContents(request.items)}, ${request.statusLabel}`}
        className="flex min-h-[5.5rem] items-center gap-3 rounded-2xl p-4 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f56600]"
      >
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <RequestStatusBadge label={request.statusLabel} group={request.statusGroup} />
            <span className="text-xs text-[#697687]">{request.statusDescription}</span>
          </div>
          <div className="mt-2 line-clamp-2 font-semibold leading-6 text-[#071d38] [overflow-wrap:anywhere]">
            {describeRequestContents(request.items)}
          </div>
          <div className="mt-1 text-xs text-[#697687]">
            {requestedOnLabel(request.submittedAt)} · {count}
          </div>
          {request.staffMessage && (
            <div className="mt-2 flex items-start gap-1.5 text-sm text-[#526174]">
              <MessageCircle
                className="mt-0.5 size-3.5 shrink-0 text-[#f56600]"
                aria-hidden="true"
              />
              <span className="line-clamp-2 [overflow-wrap:anywhere]">{request.staffMessage}</span>
            </div>
          )}
        </div>
        <ChevronRight className="size-5 shrink-0 text-[#9aa3ad]" aria-hidden="true" />
      </Link>
    </article>
  );
}

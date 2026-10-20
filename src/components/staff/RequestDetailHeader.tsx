import { RequestStatusBadge } from "@/components/staff/RequestStatusBadge";
import {
  describeRequestContents,
  type StaffRequestDetailViewModel,
} from "@/supply-requests/staff-dashboard";

const longDate = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
});

export function RequestDetailHeader({ request }: { request: StaffRequestDetailViewModel }) {
  return (
    <header className="rounded-2xl border border-[#e1e6ec] bg-white p-5 shadow-[0_4px_18px_rgba(7,29,56,0.04)]">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
        <RequestStatusBadge label={request.statusLabel} group={request.statusGroup} />
        <span className="text-sm text-[#526174]">{request.statusDescription}</span>
      </div>
      <h1 className="mt-4 text-[1.4rem] font-semibold leading-tight tracking-tight text-[#071d38] [overflow-wrap:anywhere]">
        {describeRequestContents(request.items, 3)}
      </h1>
      <p className="mt-1.5 text-sm text-[#697687]">
        Submitted {longDate.format(new Date(request.submittedAt))} · {request.itemCount}{" "}
        {request.itemCount === 1 ? "item" : "items"}
      </p>
    </header>
  );
}

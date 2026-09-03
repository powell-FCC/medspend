import { AdminActionButton } from "@/components/admin/supply-requests/AdminActionButton";
import type { AdminSupplyRequestViewModel } from "@/supply-requests/admin-dashboard";
import { requestTimestamp } from "@/supply-requests/admin-request-inbox";

export function AdminRequestCard({ request, onOpen }: {
  request: AdminSupplyRequestViewModel;
  onOpen: (request: AdminSupplyRequestViewModel) => void;
}) {
  const pending = request.queueGroup === "NEEDS_REVIEW";
  return (
    <article aria-label={"Request from " + request.requesterName + ": " + request.itemName} className="border-b border-[#e2e7ec] bg-white p-4 last:border-b-0 hover:bg-[#fafbfc]">
      <div className="grid items-start gap-4 lg:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)_minmax(0,1.1fr)_8rem]">
        <div className="min-w-0">
          <h3 className="font-semibold text-[#102a49] [overflow-wrap:anywhere]">{request.itemName}</h3>
          <div className="mt-1 text-sm text-[#526174]">
            {request.items.slice(0, 3).map((item) => <p key={item.id} className="[overflow-wrap:anywhere]">
              {request.itemCount > 1 && <span>{item.name} · </span>}Qty {item.quantity}{item.unit ? " " + item.unit : ""}
            </p>)}
            {request.itemCount > 3 && <p className="mt-1 text-xs">+{request.itemCount - 3} more in request</p>}
          </div>
          {request.staffNote && <p className="mt-2 line-clamp-2 text-xs leading-5 text-[#697687]"><span className="font-medium">Staff note: </span>{request.staffNote}</p>}
        </div>
        <div className="min-w-0 text-sm">
          <p className="font-medium text-[#293e55] [overflow-wrap:anywhere]">{request.requesterName}</p>
          {request.requesterEmail && <p className="mt-1 break-all text-xs text-[#697687]">{request.requesterEmail}</p>}
          <p className="mt-1 text-xs text-[#697687]">{request.itemCount} item{request.itemCount === 1 ? "" : "s"} · {request.requestTypeLabel}</p>
        </div>
        <div className="min-w-0 text-xs leading-5 text-[#697687]">
          <time dateTime={request.submittedAt} className="font-medium text-[#3b5068]">{requestTimestamp(request.submittedAt)}</time>
          {request.team && <p className="mt-1 [overflow-wrap:anywhere]">{request.team}</p>}
          {request.location && <p className="[overflow-wrap:anywhere]">{request.location}</p>}
        </div>
        <div className="flex items-center justify-between gap-3 lg:flex-col lg:items-stretch">
          <span className={"text-xs font-semibold " + (pending ? "text-[#a14e17]" : "text-[#526174]")}>{request.statusLabel}</span>
          <AdminActionButton variant={pending ? "primary" : "secondary"} onClick={() => onOpen(request)} className="whitespace-nowrap px-3">
            {request.nextAction ?? "View Details"}
          </AdminActionButton>
        </div>
      </div>
    </article>
  );
}

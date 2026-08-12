import { RequestStatusBadge } from "@/components/staff/RequestStatusBadge";
import type { StaffRequestDetailViewModel } from "@/supply-requests/staff-dashboard";

export function RequestDetailHeader({ request }: { request: StaffRequestDetailViewModel }) {
  return (
    <header className="rounded-[1.5rem] bg-[#071d38] p-6 text-white shadow-[0_14px_36px_rgba(7,29,56,0.18)]">
      <RequestStatusBadge label={request.statusLabel} group={request.statusGroup} />
      <h1 className="mt-5 text-2xl font-semibold tracking-tight">{request.itemName}</h1>
      <p className="mt-1 text-sm text-white/65">
        {request.quantity ?? "Quantity not specified"}{request.quantity && request.unit ? ` ${request.unit}` : ""}
      </p>
    </header>
  );
}

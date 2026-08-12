import type { AdminSupplyRequestDashboard } from "@/supply-requests/admin-dashboard";

export type AdminQueueKey = keyof AdminSupplyRequestDashboard["queues"];

const queueLabels: Record<AdminQueueKey, string> = {
  needsReview: "Needs Review",
  awaitingOrder: "Awaiting Order",
  awaitingDelivery: "Awaiting Delivery",
  readyForStaff: "Ready for Staff",
  completed: "Completed",
};

export function AdminQueueTabs({
  active,
  summary,
  onChange,
}: {
  active: AdminQueueKey;
  summary: AdminSupplyRequestDashboard["summary"];
  onChange: (queue: AdminQueueKey) => void;
}) {
  return (
    <div className="overflow-x-auto pb-1" role="tablist" aria-label="Supply request queues">
      <div className="flex min-w-max gap-2">
        {(Object.keys(queueLabels) as AdminQueueKey[]).map((queue) => {
          const selected = active === queue;
          return (
            <button
              key={queue}
              type="button"
              role="tab"
              aria-selected={selected}
              onClick={() => onChange(queue)}
              className={`min-h-16 min-w-36 rounded-xl border px-4 py-2 text-left transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f56600] ${
                selected
                  ? "border-[#102a49] bg-[#102a49] text-white shadow-sm"
                  : "border-[#dfe5eb] bg-white text-[#273a51] hover:border-[#bcc7d2]"
              }`}
            >
              <span className={`block text-xs font-medium ${selected ? "text-white/70" : "text-[#697687]"}`}>
                {queueLabels[queue]}
              </span>
              <span className="mt-1 block text-xl font-semibold tabular-nums">{summary[queue]}</span>
            </button>
          );
        })}
      </div>
    </div>
  );
}

export function adminQueueLabel(queue: AdminQueueKey): string {
  return queueLabels[queue];
}

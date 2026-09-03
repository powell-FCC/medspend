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
    <div role="tablist" aria-label="Supply request queues">
      <div className="flex flex-wrap gap-1 border-b border-[#dce2e8]">
        {(Object.keys(queueLabels) as AdminQueueKey[]).map((queue) => {
          const selected = active === queue;
          return (
            <button
              key={queue}
              type="button"
              role="tab"
              aria-selected={selected}
              aria-controls="request-queue"
              id={`queue-${queue}`}
              onClick={() => onChange(queue)}
              onKeyDown={(event) => {
                const keys = Object.keys(queueLabels) as AdminQueueKey[];
                const index = keys.indexOf(queue);
                const next = event.key === "ArrowRight" ? (index + 1) % keys.length
                  : event.key === "ArrowLeft" ? (index + keys.length - 1) % keys.length
                  : event.key === "Home" ? 0 : event.key === "End" ? keys.length - 1 : null;
                if (next !== null) {
                  event.preventDefault();
                  onChange(keys[next]);
                  document.getElementById(`queue-${keys[next]}`)?.focus();
                }
              }}
              tabIndex={selected ? 0 : -1}
              className={`inline-flex min-h-12 items-center gap-2 border-b-2 px-3 py-2 text-sm transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f56600] ${
                selected
                  ? "border-[#102a49] font-semibold text-[#102a49]"
                  : "border-transparent text-[#647183] hover:text-[#102a49]"
              }`}
            >
              <span>
                {queueLabels[queue]}
              </span>
              <span className={`rounded px-1.5 py-0.5 text-xs font-semibold tabular-nums ${queue === "needsReview" && summary.needsReview ? "bg-[#fff0e5] text-[#a14e17]" : "bg-[#edf1f5] text-[#536174]"}`}>{summary[queue]}</span>
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

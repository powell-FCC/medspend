import { Check } from "lucide-react";
import type { StaffRequestTimelineItem } from "@/supply-requests/staff-dashboard";

const date = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });

// Stored events only (creation time and staff-safe audited updates). This is a summary
// for the requester, not the audit log.
export function RequestDetailTimeline({ items }: { items: StaffRequestTimelineItem[] }) {
  return (
    <ol aria-label="Request history">
      {items.map((item, index) => (
        <li
          key={`${item.label}-${item.occurredAt}-${index}`}
          className="relative flex gap-3.5 pb-5 last:pb-0"
        >
          {index < items.length - 1 && (
            <span
              className="absolute left-[11px] top-7 h-[calc(100%-1.5rem)] w-px bg-[#d8dee6]"
              aria-hidden="true"
            />
          )}
          <span
            className="relative z-10 mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-full bg-[#071d38] text-white"
            aria-hidden="true"
          >
            <Check className="size-3.5" />
          </span>
          <div className="min-w-0">
            <div className="text-sm font-medium text-[#071d38]">
              {item.label}
              <span className="font-normal text-[#6b7685]"> · </span>
              <time className="font-normal text-[#6b7685]" dateTime={item.occurredAt}>
                {date.format(new Date(item.occurredAt))}
              </time>
            </div>
            {item.message && (
              <p className="mt-1 text-sm leading-6 text-[#4f5c6c] [overflow-wrap:anywhere]">
                {item.message}
              </p>
            )}
          </div>
        </li>
      ))}
    </ol>
  );
}

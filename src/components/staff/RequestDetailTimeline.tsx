import { Check } from "lucide-react";
import type { StaffRequestTimelineItem } from "@/supply-requests/staff-dashboard";

const date = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });

export function RequestDetailTimeline({ items }: { items: StaffRequestTimelineItem[] }) {
  return (
    <ol className="space-y-0">
      {items.map((item, index) => (
        <li key={`${item.label}-${item.occurredAt}`} className="relative flex gap-4 pb-6 last:pb-0">
          {index < items.length - 1 && <span className="absolute left-[15px] top-8 h-[calc(100%-1.25rem)] w-px bg-[#d8dee6]" />}
          <span className="relative z-10 flex size-8 shrink-0 items-center justify-center rounded-full bg-[#071d38] text-white">
            <Check className="size-4" aria-hidden="true" />
          </span>
          <div className="pt-1">
            <div className="font-medium text-[#071d38]">{item.label}</div>
            <time className="text-sm text-[#6b7685]" dateTime={item.occurredAt}>{date.format(new Date(item.occurredAt))}</time>
            {item.message && <p className="mt-1 text-sm text-[#4f5c6c]">{item.message}</p>}
          </div>
        </li>
      ))}
    </ol>
  );
}

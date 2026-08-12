import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import type { StaffRequestStatusGroup } from "@/supply-requests/staff-dashboard";

const tones: Record<StaffRequestStatusGroup, string> = {
  ACTIVE: "border-[#dce3eb] bg-[#edf1f5] text-[#33445a]",
  READY: "border-[#ffd7bc] bg-[#fff0e5] text-[#a84300]",
  COMPLETED: "border-[#d9e6de] bg-[#edf7f1] text-[#286443]",
  ACTION_REQUIRED: "border-[#f1cbd0] bg-[#fff0f1] text-[#a83340]",
};

export function RequestStatusBadge({
  label,
  group,
  className,
}: {
  label: string;
  group: StaffRequestStatusGroup;
  className?: string;
}) {
  return <Badge className={cn("whitespace-nowrap rounded-full border px-2.5 py-1 text-[0.65rem] uppercase tracking-[0.08em] shadow-none", tones[group], className)}>{label}</Badge>;
}

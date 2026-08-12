import type { ReactNode } from "react";

export function StaffSummaryCard({ label, value, icon }: { label: string; value: number; icon?: ReactNode }) {
  return (
    <div className="min-w-0 rounded-2xl border border-[#e3e8ed] bg-white p-3.5 shadow-[0_4px_18px_rgba(7,29,56,0.04)]">
      <div className="flex items-center justify-between text-[#647080]">
        <span className="truncate text-xs font-medium">{label}</span>
        {icon}
      </div>
      <div className="mt-3 text-2xl font-semibold tracking-tight text-[#071d38]">{value}</div>
    </div>
  );
}

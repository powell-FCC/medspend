import type { ReactNode } from "react";

export function StaffEmptyState({
  title,
  description,
  icon,
  action,
}: {
  title: string;
  description?: string;
  icon?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="rounded-2xl border border-dashed border-[#cfd6de] bg-white/70 px-5 py-6 text-center">
      {icon && (
        <div
          className="mx-auto mb-3 flex size-11 items-center justify-center rounded-full bg-[#eef1f4] text-[#526174]"
          aria-hidden="true"
        >
          {icon}
        </div>
      )}
      <div className="font-semibold text-[#071d38]">{title}</div>
      {description && (
        <div className="mx-auto mt-1 max-w-xs text-sm leading-6 text-[#697687]">{description}</div>
      )}
      {action && <div className="mt-4">{action}</div>}
    </div>
  );
}

import { AlertCircle, RotateCw } from "lucide-react";
import type { ReactNode } from "react";

export function StaffSectionHeader({
  id,
  title,
  action,
}: {
  id: string;
  title: string;
  action?: ReactNode;
}) {
  return (
    <div className="flex min-h-11 items-center justify-between gap-3">
      <h2 id={id} className="text-[0.95rem] font-semibold tracking-tight text-[#071d38]">
        {title}
      </h2>
      {action}
    </div>
  );
}

export function StaffListSkeleton({ label, rows = 3 }: { label: string; rows?: number }) {
  return (
    <div role="status" aria-label={label} className="space-y-2.5">
      {Array.from({ length: rows }, (_, row) => (
        <div
          key={row}
          className="flex h-[4.5rem] items-center gap-3 rounded-2xl border border-[#e5e9ed] bg-white px-4"
        >
          <div className="min-w-0 flex-1 space-y-2">
            <div className="h-3.5 w-2/3 animate-pulse rounded-full bg-[#eef1f4]" />
            <div className="h-3 w-1/3 animate-pulse rounded-full bg-[#f2f4f6]" />
          </div>
          <div className="size-11 shrink-0 animate-pulse rounded-xl bg-[#f2f4f6]" />
        </div>
      ))}
      <span className="sr-only">{label}</span>
    </div>
  );
}

export function StaffErrorState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div
      role="alert"
      className="flex flex-wrap items-center justify-between gap-2 rounded-2xl border border-[#f1c8cc] bg-[#fff5f5] px-4 py-3 text-sm text-[#8d2d39]"
    >
      <span className="flex min-w-0 items-center gap-2">
        <AlertCircle className="size-4 shrink-0" aria-hidden="true" />
        {message}
      </span>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="inline-flex min-h-11 items-center gap-1.5 rounded-xl px-3 font-semibold text-[#a83340] hover:bg-[#ffe9eb] active:bg-[#ffdfe2]"
        >
          <RotateCw className="size-4" aria-hidden="true" />
          Try again
        </button>
      )}
    </div>
  );
}

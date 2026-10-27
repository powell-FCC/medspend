import { ShieldAlert } from "lucide-react";

// One wording for every label or location that can't be opened: unknown, another
// organization's, replaced, or archived. Nothing here names a location or organization.
export function CountUnavailable({
  message,
  onBack,
  backLabel = "Back",
}: {
  message: string;
  onBack: () => void;
  backLabel?: string;
}) {
  return (
    <div className="space-y-4" data-count-state="unavailable">
      <p className="pr-16 text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-[#5c6878]">
        Physical inventory count
      </p>
      <div role="alert" className="rounded-3xl border border-[#e1e6ec] bg-white p-5 text-center">
        <ShieldAlert className="mx-auto size-9 text-[#8a96a3]" aria-hidden="true" />
        <h1 className="mt-2 text-lg font-semibold text-[#071d38]">Can't open this count</h1>
        <p className="mt-1 text-sm text-[#4d5b6c]">{message}</p>
      </div>
      <button
        type="button"
        onClick={onBack}
        className="min-h-12 w-full rounded-2xl border border-[#dce2e8] bg-white px-5 font-semibold text-[#344256] active:bg-[#f2f4f6]"
      >
        {backLabel}
      </button>
    </div>
  );
}

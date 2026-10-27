import { ChevronRight, MapPin } from "lucide-react";

export interface CountableLocation {
  id: string;
  name: string;
  lastCountedAt: string | null;
}

const shortDate = (iso: string) =>
  new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric" });

// The no-camera path: this organization's active storage locations, names only. Choosing one
// opens the same count a label would; membership, not the label, is what authorizes it.
export function CountLocationPicker({
  locations,
  loading,
  error,
  onRetry,
  onSelect,
}: {
  locations: CountableLocation[] | undefined;
  loading: boolean;
  error: string | null;
  onRetry: () => void;
  onSelect: (locationId: string) => void;
}) {
  return (
    <section aria-labelledby="choose-location-title" className="space-y-2.5">
      <h2
        id="choose-location-title"
        className="text-[0.95rem] font-semibold tracking-tight text-[#071d38]"
      >
        No label handy? Choose the location
      </h2>
      {loading && (
        <p role="status" className="text-sm text-[#697687]">
          Loading locations…
        </p>
      )}
      {error && (
        <div
          role="alert"
          className="flex flex-wrap items-center justify-between gap-2 rounded-2xl border border-[#f1c8cc] bg-[#fff5f5] px-4 py-3 text-sm text-[#8d2d39]"
        >
          {error}
          <button type="button" onClick={onRetry} className="min-h-11 px-2 font-semibold">
            Try again
          </button>
        </div>
      )}
      {locations && locations.length === 0 && (
        <p className="rounded-2xl border border-dashed border-[#cfd6de] bg-white px-4 py-5 text-center text-sm text-[#697687]">
          No storage locations are set up yet. An owner adds them on the Inventory page.
        </p>
      )}
      {locations && locations.length > 0 && (
        <ul className="divide-y overflow-hidden rounded-2xl border border-[#e1e6ec] bg-white">
          {locations.map((location) => (
            <li key={location.id}>
              <button
                type="button"
                onClick={() => onSelect(location.id)}
                className="flex min-h-14 w-full items-center gap-3 px-4 py-2.5 text-left active:bg-[#f5f7f9]"
              >
                <MapPin className="size-4 shrink-0 text-[#d95700]" aria-hidden="true" />
                <span className="min-w-0 flex-1">
                  <span className="block break-words font-medium text-[#071d38]">
                    {location.name}
                  </span>
                  <span className="block text-xs text-[#697687]">
                    {location.lastCountedAt
                      ? `Last counted ${shortDate(location.lastCountedAt)}`
                      : "Not counted yet"}
                  </span>
                </span>
                <ChevronRight className="size-4 shrink-0 text-[#9aa5b1]" aria-hidden="true" />
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

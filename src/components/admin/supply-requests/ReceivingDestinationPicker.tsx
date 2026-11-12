import {
  orderReceivingDestinations,
  receivingDestinationLabel,
  type ReceivingDestination,
} from "@/supply-requests/receiving";

// Phase 7C: where the delivery was received. Required before receiving. The request's team and
// location are shown as context only: they are request locations, not inventory locations, and
// are never used to choose a destination.
export function ReceivingDestinationPicker({
  destinations,
  value,
  onChange,
  loading,
  error,
  onRetry,
  disabled,
  requestTeam,
  requestLocation,
}: {
  destinations: readonly ReceivingDestination[];
  value: string;
  onChange: (destinationId: string) => void;
  loading: boolean;
  error: boolean;
  onRetry: () => void;
  disabled: boolean;
  requestTeam: string | null;
  requestLocation: string | null;
}) {
  const ordered = orderReceivingDestinations(destinations);
  return (
    <section
      aria-labelledby="receiving-destination-heading"
      className="rounded-lg border border-[#d9e0e7] bg-[#f8fafc] p-4"
      data-testid="receiving-destination"
    >
      <label
        id="receiving-destination-heading"
        htmlFor="receiving-destination"
        className="text-sm font-semibold text-[#102a49]"
      >
        Receiving destination (required)
      </label>
      <p className="mt-1 text-xs leading-5 text-[#657284]">
        Where was this delivery received? This records the destination only; it does not move
        inventory.
      </p>
      {loading ? (
        <p role="status" className="mt-3 text-sm text-[#697687]">
          Loading destinations…
        </p>
      ) : error ? (
        <p role="alert" className="mt-3 text-sm text-[#a83340]">
          Could not load receiving destinations.{" "}
          <button type="button" onClick={onRetry} className="min-h-11 underline">
            Try again
          </button>
        </p>
      ) : (
        <select
          id="receiving-destination"
          value={value}
          required
          disabled={disabled}
          onChange={(event) => onChange(event.target.value)}
          className="mt-3 min-h-11 w-full rounded-md border border-[#cfd8e1] bg-white px-3 text-sm text-[#293e55]"
        >
          <option value="" disabled>
            Choose where it was received…
          </option>
          {ordered.map((destination) => (
            <option key={destination.id} value={destination.id}>
              {receivingDestinationLabel(destination)}
            </option>
          ))}
        </select>
      )}
      <p className="mt-2 text-xs text-[#697687]" data-testid="receiving-request-context">
        Requested for: {requestTeam ?? "No team"} · {requestLocation ?? "No location"}
      </p>
    </section>
  );
}

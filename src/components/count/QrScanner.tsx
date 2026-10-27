import { Camera, CameraOff, Loader2, QrCode, Smartphone } from "lucide-react";
import type { RefObject } from "react";

export type ScannerState =
  "idle" | "starting" | "scanning" | "denied" | "unsupported" | "unavailable" | "error";

// The printed label works with the phone's ordinary camera: this is always the way out of
// a scanner that can't run.
export function PhoneCameraHelp() {
  return (
    <div
      className="rounded-2xl border border-[#e1e6ec] bg-white p-4"
      data-testid="phone-camera-help"
    >
      <p className="flex items-center gap-2 text-sm font-semibold text-[#071d38]">
        <Smartphone className="size-4 text-[#d95700]" aria-hidden="true" />
        Use your phone's camera instead
      </p>
      <ol className="mt-2 list-decimal space-y-1 pl-5 text-sm text-[#4d5b6c]">
        <li>Open the Camera app and point it at the location's QR label.</li>
        <li>Tap the link that appears. It opens that location's count here.</li>
      </ol>
    </div>
  );
}

const failureCopy: Record<
  "denied" | "unsupported" | "unavailable" | "error",
  { title: string; body: string }
> = {
  denied: {
    title: "Camera access is blocked",
    body: "Allow camera access for this site in your browser settings, then try again. On iPhone: Settings › Safari › Camera.",
  },
  unsupported: {
    title: "This browser can't scan here",
    body: "Scanning inside the app isn't available in this browser.",
  },
  unavailable: {
    title: "No camera found",
    body: "We couldn't start a camera on this device.",
  },
  error: {
    title: "The scanner stopped",
    body: "Something went wrong while scanning.",
  },
};

export function QrScannerView({
  state,
  videoRef,
  notice,
  onStart,
}: {
  state: ScannerState;
  videoRef?: RefObject<HTMLVideoElement | null>;
  notice?: string | null;
  onStart: () => void;
}) {
  if (
    state === "denied" ||
    state === "unsupported" ||
    state === "unavailable" ||
    state === "error"
  ) {
    const copy = failureCopy[state];
    return (
      <div className="space-y-3" data-scanner-state={state}>
        <div role="alert" className="rounded-2xl border border-[#f1d3bf] bg-[#fff8f2] p-4">
          <p className="flex items-center gap-2 font-semibold text-[#8a3b00]">
            <CameraOff className="size-4 shrink-0" aria-hidden="true" />
            {copy.title}
          </p>
          <p className="mt-1 text-sm text-[#6b4a33]">{copy.body}</p>
          {state !== "unsupported" && (
            <button
              type="button"
              onClick={onStart}
              className="mt-3 inline-flex min-h-11 items-center gap-2 rounded-xl border border-[#e4c3aa] bg-white px-4 text-sm font-semibold text-[#8a3b00] active:bg-[#fff1e6]"
            >
              <Camera className="size-4" aria-hidden="true" />
              Try again
            </button>
          )}
        </div>
        <PhoneCameraHelp />
      </div>
    );
  }

  return (
    <div className="space-y-3" data-scanner-state={state}>
      <div className="relative aspect-square w-full overflow-hidden rounded-3xl bg-[#0b1726] sm:aspect-[4/3]">
        <video
          ref={videoRef}
          className={`size-full object-cover ${state === "scanning" ? "" : "hidden"}`}
          playsInline
          muted
          aria-label="Camera view"
        />
        {state === "scanning" && (
          <div
            className="pointer-events-none absolute inset-[18%] rounded-3xl border-[3px] border-white/85 shadow-[0_0_0_9999px_rgba(11,23,38,0.35)]"
            aria-hidden="true"
          />
        )}
        {state !== "scanning" && (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-4 p-6 text-center text-white">
            <QrCode className="size-12 text-white/80" aria-hidden="true" />
            {state === "starting" ? (
              <p className="flex items-center gap-2 text-sm text-white/85">
                <Loader2 className="size-4 animate-spin" aria-hidden="true" />
                Starting camera…
              </p>
            ) : (
              <>
                <p className="max-w-xs text-sm text-white/85">
                  Point your camera at the QR label on a storage location.
                </p>
                <button
                  type="button"
                  onClick={onStart}
                  className="inline-flex min-h-12 items-center gap-2 rounded-2xl bg-[#d95700] px-5 font-semibold text-white active:bg-[#bf4c00]"
                >
                  <Camera className="size-5" aria-hidden="true" />
                  Start camera
                </button>
              </>
            )}
          </div>
        )}
      </div>
      <p className="min-h-5 text-center text-sm text-[#4d5b6c]" role="status" aria-live="polite">
        {state === "scanning" ? (notice ?? "Looking for a QR label…") : ""}
      </p>
    </div>
  );
}

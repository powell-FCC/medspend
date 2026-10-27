// QR detection for the in-app scanner. The phone's own camera opening a printed label's
// link is the primary path and needs none of this.
//
// Uses the browser's BarcodeDetector when it supports QR codes (Chrome on Android, for
// example). Otherwise, notably Safari on iPhone, it loads the barcode-detector ponyfill and
// its zxing-wasm decoder (zxing-fallback.ts). That code and the ~1 MB .wasm load only when
// the scanner opens, and the .wasm is served from this app's own assets, never a CDN.

export interface QrDetector {
  kind: "native" | "wasm";
  detect(source: CanvasImageSource): Promise<string[]>;
}

interface DetectorLike {
  detect(source: CanvasImageSource): Promise<Array<{ rawValue: string }>>;
}
interface DetectorConstructor {
  new (options: { formats: string[] }): DetectorLike;
  getSupportedFormats?: () => Promise<string[]>;
}

export async function nativeQrSupported(scope: unknown = globalThis): Promise<boolean> {
  const Detector = (scope as { BarcodeDetector?: DetectorConstructor }).BarcodeDetector;
  if (!Detector) return false;
  try {
    const formats = (await Detector.getSupportedFormats?.()) ?? [];
    return formats.includes("qr_code");
  } catch {
    return false;
  }
}

function wrap(kind: QrDetector["kind"], detector: DetectorLike): QrDetector {
  return {
    kind,
    detect: async (source) => (await detector.detect(source)).map((code) => code.rawValue),
  };
}

export async function createQrDetector(scope: unknown = globalThis): Promise<QrDetector> {
  if (await nativeQrSupported(scope)) {
    const Detector = (scope as { BarcodeDetector: DetectorConstructor }).BarcodeDetector;
    return wrap("native", new Detector({ formats: ["qr_code"] }));
  }
  const { createWasmQrDetector } = await import("./zxing-fallback");
  return wrap("wasm", await createWasmQrDetector());
}

export type CameraFailure = "denied" | "unsupported" | "unavailable";

// Why the camera could not start, in terms the scanner screen can explain.
export function cameraFailure(error: unknown): CameraFailure {
  const name = (error as { name?: string } | null)?.name ?? "";
  if (name === "NotAllowedError" || name === "SecurityError" || name === "PermissionDeniedError") {
    return "denied";
  }
  if (name === "NotFoundError" || name === "OverconstrainedError" || name === "NotReadableError") {
    return "unavailable";
  }
  return "unsupported";
}

export function cameraSupported(scope: unknown = globalThis): boolean {
  const nav = (scope as { navigator?: { mediaDevices?: { getUserMedia?: unknown } } }).navigator;
  return typeof nav?.mediaDevices?.getUserMedia === "function";
}

import { useCallback, useEffect, useRef, useState } from "react";
import { countTokenFromScan } from "@/inventory/count";
import {
  cameraFailure,
  cameraSupported,
  createQrDetector,
  type QrDetector,
} from "@/count/qr-detector";
import type { ScannerState } from "@/components/count/QrScanner";

// Camera and decoding. Starts only on a tap (iOS requires a user gesture), prefers the rear
// camera, scans a few frames a second, and stops every track on unmount.
export function useQrScanner(onToken: (token: string) => void) {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const timerRef = useRef<number | null>(null);
  const doneRef = useRef(false);
  const [state, setState] = useState<ScannerState>("idle");
  const [notice, setNotice] = useState<string | null>(null);

  const stop = useCallback(() => {
    if (timerRef.current !== null) window.clearTimeout(timerRef.current);
    timerRef.current = null;
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
  }, []);

  useEffect(() => stop, [stop]);

  const start = useCallback(async () => {
    stop();
    doneRef.current = false;
    setNotice(null);
    if (!cameraSupported()) {
      setState("unsupported");
      return;
    }
    setState("starting");
    let detector: QrDetector;
    try {
      streamRef.current = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: { ideal: "environment" } },
        audio: false,
      });
    } catch (error) {
      stop();
      setState(cameraFailure(error));
      return;
    }
    try {
      detector = await createQrDetector();
    } catch {
      stop();
      setState("unsupported");
      return;
    }
    const video = videoRef.current;
    if (!video || !streamRef.current) {
      stop();
      setState("error");
      return;
    }
    video.srcObject = streamRef.current;
    try {
      await video.play();
    } catch {
      stop();
      setState("error");
      return;
    }
    setState("scanning");
    const tick = async () => {
      if (doneRef.current || !streamRef.current) return;
      try {
        if (video.readyState >= 2) {
          for (const raw of await detector.detect(video)) {
            const token = countTokenFromScan(raw);
            if (token) {
              doneRef.current = true;
              stop();
              onToken(token);
              return;
            }
            setNotice("That QR code isn't a SportSpend inventory label.");
          }
        }
      } catch {
        // A frame that can't be decoded is normal; keep scanning.
      }
      timerRef.current = window.setTimeout(tick, 250);
    };
    void tick();
  }, [onToken, stop]);

  return { videoRef, state, notice, start };
}

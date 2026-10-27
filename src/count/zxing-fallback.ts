// Loaded only by qr-detector.ts, only when the browser has no QR-capable BarcodeDetector.
// The decoder's .wasm is bundled by Vite into this app's own assets (zxing-wasm 3.1.3,
// matching barcode-detector 3.2.2), replacing the library's default jsDelivr URL.
import { BarcodeDetector, prepareZXingModule } from "barcode-detector/ponyfill";
import readerWasmUrl from "zxing-wasm/reader/zxing_reader.wasm?url";

export function zxingLocateFile(path: string, prefix: string): string {
  return path.endsWith(".wasm") ? readerWasmUrl : prefix + path;
}

let prepared = false;

export async function createWasmQrDetector() {
  if (!prepared) {
    prepareZXingModule({ overrides: { locateFile: zxingLocateFile } });
    prepared = true;
  }
  return new BarcodeDetector({ formats: ["qr_code"] });
}

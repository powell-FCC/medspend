import QRCode from "qrcode";

// Printed QR labels for storage locations. The code holds only the count link
// (<origin>/count/<opaque token>): no organization, user or quantity data.

export async function qrLabelSvg(url: string): Promise<string> {
  return QRCode.toString(url, { type: "svg", errorCorrectionLevel: "M", margin: 2 });
}

const escapeHtml = (value: string) =>
  value.replace(
    /[&<>"']/g,
    (char) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char] as string,
  );

// A self-contained page for printing one label. The location name is escaped; the SVG comes
// from qrLabelSvg, never from user input.
export function printableLabelHtml(locationName: string, svg: string): string {
  const name = escapeHtml(locationName);
  return `<!doctype html><html><head><meta charset="utf-8"><title>${name} QR label</title>
<style>
  @page { margin: 12mm; }
  body { font-family: system-ui, -apple-system, sans-serif; margin: 0; display: flex; justify-content: center; }
  .label { width: 70mm; border: 1px solid #c9d1da; border-radius: 4mm; padding: 6mm; text-align: center; }
  .label svg { width: 56mm; height: 56mm; }
  .name { font-size: 15pt; font-weight: 700; margin: 2mm 0 1mm; word-break: break-word; }
  .hint { font-size: 9pt; color: #4d5b6c; margin: 0; }
</style></head><body><div class="label">${svg}<p class="name">${name}</p>
<p class="hint">Scan to count this location</p></div></body></html>`;
}

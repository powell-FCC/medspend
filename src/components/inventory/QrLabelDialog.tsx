import { useEffect, useState } from "react";
import { Loader2, Printer, QrCode, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { countLabelUrl } from "@/inventory/count";
import { printableLabelHtml, qrLabelSvg } from "@/inventory/labels";
import type { InventoryLocation } from "@/types/inventory";

// Owner QR labels for one storage location. A label's token is shown only right after it is
// issued (the database keeps a hash), so printing again means issuing another label. Old
// labels keep working until replaced; replacing revokes every earlier label.
export function QrLabelDialog({
  location,
  activeLabelCount,
  origin,
  onOpenChange,
  onIssue,
  onReplace,
  initialIssued,
}: {
  location?: InventoryLocation;
  activeLabelCount: number;
  origin: string;
  onOpenChange: (open: boolean) => void;
  onIssue: () => Promise<{ token: string }>;
  onReplace: () => Promise<{ token: string }>;
  initialIssued?: { url: string; svg: string };
}) {
  const [issued, setIssued] = useState<{ url: string; svg: string } | undefined>(initialIssued);
  const [busy, setBusy] = useState<"issue" | "replace">();
  const [confirmReplace, setConfirmReplace] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    setIssued(initialIssued);
    setConfirmReplace(false);
    setError("");
    // A different location starts fresh.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location?.id]);

  async function run(kind: "issue" | "replace", action: () => Promise<{ token: string }>) {
    if (busy) return;
    setBusy(kind);
    setError("");
    try {
      const { token } = await action();
      const url = countLabelUrl(origin, token);
      setIssued({ url, svg: await qrLabelSvg(url) });
      setConfirmReplace(false);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not issue the label.");
    } finally {
      setBusy(undefined);
    }
  }

  function print() {
    if (!issued || !location) return;
    const frame = document.createElement("iframe");
    frame.setAttribute("aria-hidden", "true");
    frame.style.cssText = "position:fixed;width:0;height:0;border:0;right:0;bottom:0";
    document.body.appendChild(frame);
    const doc = frame.contentWindow?.document;
    if (!doc || !frame.contentWindow) {
      frame.remove();
      return;
    }
    doc.open();
    doc.write(printableLabelHtml(location.name, issued.svg));
    doc.close();
    frame.contentWindow.focus();
    frame.contentWindow.print();
    window.setTimeout(() => frame.remove(), 1000);
  }

  return (
    <Dialog open={!!location} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[92dvh] overflow-y-auto sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="break-words">QR label · {location?.name}</DialogTitle>
          <DialogDescription>
            Staff scan this label with their phone camera to count this location. The label only
            identifies the location; it works only for signed-in members of your organization.
          </DialogDescription>
        </DialogHeader>
        <p className="text-sm text-muted-foreground" data-testid="label-count">
          {activeLabelCount === 0
            ? "No labels issued yet."
            : `${activeLabelCount} active label${activeLabelCount === 1 ? "" : "s"} for this location.`}
        </p>
        {issued ? (
          <div className="space-y-3 text-center" data-testid="issued-label">
            <div
              className="mx-auto w-56 max-w-full rounded-xl border bg-white p-3 [&_svg]:h-auto [&_svg]:w-full"
              role="img"
              aria-label={`QR code for ${location?.name}`}
              // The SVG is generated locally by qrcode from the count URL.
              dangerouslySetInnerHTML={{ __html: issued.svg }}
            />
            <p className="break-all font-mono text-xs text-muted-foreground">{issued.url}</p>
            <Button onClick={print} className="h-11 w-full">
              <Printer className="mr-2 h-4 w-4" />
              Print label
            </Button>
            <p className="text-xs text-muted-foreground">
              This label can't be shown again after you close this window. Print it now; to print
              another copy later, issue another label.
            </p>
          </div>
        ) : (
          <Button
            onClick={() => void run("issue", onIssue)}
            disabled={!!busy}
            className="h-11 w-full"
          >
            {busy === "issue" ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <QrCode className="mr-2 h-4 w-4" />
            )}
            {activeLabelCount === 0 ? "Issue QR label" : "Issue another label"}
          </Button>
        )}
        {error && (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}
        {activeLabelCount > 0 && (
          <div className="rounded-lg border border-dashed p-3 text-sm">
            {confirmReplace ? (
              <div className="space-y-2">
                <p>
                  Every existing label for {location?.name} will stop working, and a new one is
                  issued. Use this if a label was lost or photographed.
                </p>
                <div className="flex flex-wrap gap-2">
                  <Button
                    variant="destructive"
                    size="sm"
                    className="h-10"
                    disabled={!!busy}
                    onClick={() => void run("replace", onReplace)}
                  >
                    {busy === "replace" && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                    Replace all labels
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    className="h-10"
                    onClick={() => setConfirmReplace(false)}
                  >
                    Cancel
                  </Button>
                </div>
              </div>
            ) : (
              <Button
                variant="ghost"
                size="sm"
                className="h-10 px-2"
                onClick={() => setConfirmReplace(true)}
              >
                <RefreshCw className="mr-2 h-4 w-4" />
                Replace labels…
              </Button>
            )}
          </div>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Close
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

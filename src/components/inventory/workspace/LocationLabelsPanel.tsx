import { useEffect, useState } from "react";
import { Ban, Loader2, Printer, QrCode, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { countLabelUrl } from "@/inventory/count";
import { printableLabelHtml, qrLabelSvg } from "@/inventory/labels";
import {
  formatWorkspaceDate,
  replaceFailureMessage,
  replaceLabelsCopy,
  revokeLabelsCopy,
} from "@/inventory/workspace";
import type { WorkspaceLocation } from "@/types/inventory-workspace";

type Busy = "issue" | "replace" | "revoke";
type Confirm = "replace" | "revoke";

// QR labels for one storage location. A label's token is shown only right after it is
// issued (the database keeps only a hash), so another printed copy is always another,
// newly issued label; SportSpend cannot reconstruct an earlier one.
//   Issue label / Issue another label: one more active label; earlier ones keep working.
//   Replace labels: every active label stops working and exactly one new label is issued,
//     in one database transaction.
//   Revoke labels: every active label stops working and nothing is issued.
// Owners only see the controls; admins see the facts.
export function LocationLabelsPanel({
  location,
  canManage,
  origin,
  onIssue,
  onReplace,
  onRevoke,
  initialIssued,
}: {
  location: WorkspaceLocation;
  canManage: boolean;
  origin: string;
  onIssue?: () => Promise<{ token: string }>;
  onReplace?: () => Promise<{ token: string }>;
  onRevoke?: () => Promise<{ revoked: number }>;
  initialIssued?: { url: string; svg: string };
}) {
  const [issued, setIssued] = useState<{ url: string; svg: string } | undefined>(initialIssued);
  const [busy, setBusy] = useState<Busy>();
  const [confirm, setConfirm] = useState<Confirm>();
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const count = location.activeLabelCount ?? 0;

  useEffect(() => {
    setIssued(initialIssued);
    setConfirm(undefined);
    setError("");
    setNotice("");
    // A different location starts fresh.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [location.id]);

  async function issue(kind: "issue" | "replace", action?: () => Promise<{ token: string }>) {
    if (busy || !action) return;
    setBusy(kind);
    setError("");
    setNotice("");
    try {
      const { token } = await action();
      const url = countLabelUrl(origin, token);
      setIssued({ url, svg: await qrLabelSvg(url) });
      setConfirm(undefined);
      if (kind === "replace")
        setNotice("Every earlier label was revoked. Print the new label now.");
    } catch (cause) {
      // Replace is atomic: when it fails, the earlier labels are still active.
      const message = cause instanceof Error ? cause.message : "Could not issue the label.";
      setError(kind === "replace" ? replaceFailureMessage(message) : message);
    } finally {
      setBusy(undefined);
    }
  }

  async function revoke() {
    if (busy || !onRevoke) return;
    setBusy("revoke");
    setError("");
    setNotice("");
    try {
      const { revoked } = await onRevoke();
      setIssued(undefined);
      setConfirm(undefined);
      setNotice(
        `${revoked} label${revoked === 1 ? "" : "s"} revoked. ${location.name} now has no active labels.`,
      );
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not revoke the labels.");
    } finally {
      setBusy(undefined);
    }
  }

  function print() {
    if (!issued) return;
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
    <section aria-labelledby="location-labels-heading" className="space-y-4" data-section="labels">
      <div>
        <h2 id="location-labels-heading" className="font-medium">
          QR labels
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          Staff scan a label with their phone camera to count this location. A label only identifies
          the location; it works only for signed-in members of your organization.
        </p>
      </div>
      <dl
        className="grid gap-3 rounded-lg border p-3 text-sm sm:grid-cols-2"
        data-testid="label-facts"
      >
        <div>
          <dt className="text-xs text-muted-foreground">Active labels</dt>
          <dd className="font-medium tabular-nums">{count}</dd>
        </div>
        <div>
          <dt className="text-xs text-muted-foreground">Last label issued</dt>
          <dd className="font-medium">{formatWorkspaceDate(location.lastLabelIssuedAt)}</dd>
        </div>
        {!location.active && (
          <p className="text-xs text-muted-foreground sm:col-span-2">
            {count > 0
              ? "Labels are suspended while this location is archived. Restoring it makes unrevoked labels work again."
              : "This archived location has no active labels."}
          </p>
        )}
      </dl>

      {issued && (
        <div className="space-y-3 text-center" data-testid="issued-label">
          <div
            className="mx-auto w-56 max-w-full rounded-xl border bg-white p-3 [&_svg]:h-auto [&_svg]:w-full"
            role="img"
            aria-label={`QR code for ${location.name}`}
            // The SVG is generated locally by qrcode from the count URL.
            dangerouslySetInnerHTML={{ __html: issued.svg }}
          />
          <p className="break-all font-mono text-xs text-muted-foreground">{issued.url}</p>
          <Button onClick={print} className="h-11 w-full sm:w-auto">
            <Printer className="mr-2 h-4 w-4" />
            Print label
          </Button>
          <p className="text-xs text-muted-foreground">
            This label can't be shown again after you leave this page. To print another copy later,
            issue another label.
          </p>
        </div>
      )}

      {notice && (
        <p role="status" className="text-sm text-emerald-700">
          {notice}
        </p>
      )}
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}

      {canManage && (
        <div className="space-y-3" data-testid="label-actions">
          {location.active ? (
            <Button
              onClick={() => void issue("issue", onIssue)}
              disabled={!!busy}
              className="h-11 w-full sm:w-auto"
            >
              {busy === "issue" ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              ) : (
                <QrCode className="mr-2 h-4 w-4" />
              )}
              {count === 0 ? "Issue QR label" : "Issue another label"}
            </Button>
          ) : (
            <p className="text-sm text-muted-foreground">
              Restore this location to issue or replace labels.
            </p>
          )}
          {count > 0 && (
            <div className="flex flex-wrap gap-2">
              {location.active && (
                <Button
                  variant="outline"
                  className="h-10"
                  disabled={!!busy}
                  onClick={() => setConfirm("replace")}
                >
                  <RefreshCw className="mr-2 h-4 w-4" />
                  Replace labels…
                </Button>
              )}
              <Button
                variant="outline"
                className="h-10"
                disabled={!!busy}
                onClick={() => setConfirm("revoke")}
              >
                <Ban className="mr-2 h-4 w-4" />
                Revoke labels…
              </Button>
            </div>
          )}
          {confirm === "replace" && (
            <div className="space-y-2 rounded-lg border border-dashed p-3 text-sm" role="group">
              <p>{replaceLabelsCopy(location, count)}</p>
              <div className="flex flex-wrap gap-2">
                <Button
                  variant="destructive"
                  size="sm"
                  className="h-10"
                  disabled={!!busy}
                  onClick={() => void issue("replace", onReplace)}
                >
                  {busy === "replace" && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Replace all labels
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  className="h-10"
                  onClick={() => setConfirm(undefined)}
                >
                  Cancel
                </Button>
              </div>
            </div>
          )}
          {confirm === "revoke" && (
            <div className="space-y-2 rounded-lg border border-dashed p-3 text-sm" role="group">
              {revokeLabelsCopy(location, count).map((line) => (
                <p key={line}>{line}</p>
              ))}
              <div className="flex flex-wrap gap-2">
                <Button
                  variant="destructive"
                  size="sm"
                  className="h-10"
                  disabled={!!busy}
                  onClick={() => void revoke()}
                >
                  {busy === "revoke" && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Revoke all labels
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  className="h-10"
                  onClick={() => setConfirm(undefined)}
                >
                  Cancel
                </Button>
              </div>
            </div>
          )}
        </div>
      )}
    </section>
  );
}

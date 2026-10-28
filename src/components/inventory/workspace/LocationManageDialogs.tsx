import { useEffect, useState } from "react";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import type { WorkspaceLocation } from "@/types/inventory-workspace";

export type LocationManageAction = { kind: "rename" | "archive"; location: WorkspaceLocation };

const message = (cause: unknown, fallback: string) =>
  cause instanceof Error ? cause.message : fallback;

// Owner-only rename and archive dialogs for one storage location.
export function LocationManageDialogs({
  action,
  onClose,
  onRename,
  onArchive,
  onRevoke,
}: {
  action?: LocationManageAction;
  onClose: () => void;
  onRename: (location: WorkspaceLocation, name: string) => Promise<void>;
  onArchive: (location: WorkspaceLocation) => Promise<void>;
  onRevoke: (location: WorkspaceLocation) => Promise<void>;
}) {
  return (
    <>
      <RenameDialog
        location={action?.kind === "rename" ? action.location : undefined}
        onClose={onClose}
        onRename={onRename}
      />
      <ArchiveDialog
        location={action?.kind === "archive" ? action.location : undefined}
        onClose={onClose}
        onArchive={onArchive}
        onRevoke={onRevoke}
      />
    </>
  );
}

function RenameDialog({
  location,
  onClose,
  onRename,
}: {
  location?: WorkspaceLocation;
  onClose: () => void;
  onRename: (location: WorkspaceLocation, name: string) => Promise<void>;
}) {
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    setName(location?.name ?? "");
    setError("");
  }, [location?.id, location?.name]);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!location || saving) return;
    setSaving(true);
    setError("");
    try {
      await onRename(location, name.trim());
      onClose();
    } catch (cause) {
      setError(message(cause, "Could not rename the location."));
    } finally {
      setSaving(false);
    }
  }

  return (
    <Dialog open={Boolean(location)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-md">
        <form onSubmit={submit}>
          <DialogHeader>
            <DialogTitle className="break-words">Rename {location?.name}</DialogTitle>
          </DialogHeader>
          <div className="my-4 space-y-2">
            <Label htmlFor="rename-location">Location name</Label>
            <Input
              id="rename-location"
              value={name}
              maxLength={120}
              onChange={(e) => setName(e.target.value)}
              required
              autoFocus
            />
          </div>
          {error && (
            <p role="alert" className="mb-3 text-sm text-destructive">
              {error}
            </p>
          )}
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button disabled={saving || !name.trim()}>
              {saving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Save
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

// Archiving never revokes labels by default. When the owner opts in, the location is archived
// first and its labels revoked second; if the second step fails the dialog says exactly what
// happened instead of pretending both did.
function ArchiveDialog({
  location,
  onClose,
  onArchive,
  onRevoke,
}: {
  location?: WorkspaceLocation;
  onClose: () => void;
  onArchive: (location: WorkspaceLocation) => Promise<void>;
  onRevoke: (location: WorkspaceLocation) => Promise<void>;
}) {
  const [alsoRevoke, setAlsoRevoke] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [partial, setPartial] = useState("");
  useEffect(() => {
    setAlsoRevoke(false);
    setError("");
    setPartial("");
  }, [location?.id]);
  const labels = location?.activeLabelCount ?? 0;

  async function confirm() {
    if (!location || busy) return;
    setBusy(true);
    setError("");
    try {
      await onArchive(location);
    } catch (cause) {
      setError(message(cause, "Could not archive the location."));
      setBusy(false);
      return;
    }
    if (alsoRevoke && labels > 0) {
      try {
        await onRevoke(location);
      } catch (cause) {
        setPartial(
          `${location.name} was archived, but its ${labels} active label${labels === 1 ? " was" : "s were"} not revoked: ${message(cause, "the request failed")}. Labels stay suspended while ${location.name} is archived; revoke them from its Labels tab.`,
        );
        setBusy(false);
        return;
      }
    }
    setBusy(false);
    onClose();
  }

  return (
    <Dialog open={Boolean(location)} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="break-words">Archive {location?.name}?</DialogTitle>
          <DialogDescription>
            It will no longer be offered for counting or as a move destination. Its history is kept,
            and you can restore it later.
          </DialogDescription>
        </DialogHeader>
        {labels > 0 && !partial && (
          <div className="space-y-2 rounded-lg border p-3 text-sm">
            <p>
              {labels} active label{labels === 1 ? "" : "s"} stop working while it is archived, and
              work again if it is restored.
            </p>
            <label className="flex items-start gap-2">
              <input
                type="checkbox"
                className="mt-0.5"
                checked={alsoRevoke}
                onChange={(e) => setAlsoRevoke(e.target.checked)}
              />
              <span>
                Also revoke {labels} active label{labels === 1 ? "" : "s"} (they will never work
                again, even after a restore)
              </span>
            </label>
          </div>
        )}
        {error && (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}
        {partial && (
          <p role="alert" className="text-sm text-destructive" data-testid="archive-partial">
            {partial}
          </p>
        )}
        <DialogFooter>
          {partial ? (
            <Button onClick={onClose}>Close</Button>
          ) : (
            <>
              <Button variant="outline" onClick={onClose}>
                Cancel
              </Button>
              <Button variant="destructive" disabled={busy} onClick={() => void confirm()}>
                {busy && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                Archive
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

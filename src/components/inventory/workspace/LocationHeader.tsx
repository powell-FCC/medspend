import { Archive, ArchiveRestore, Lock, Pencil } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  canArchiveWorkspaceLocation,
  countAgeLabel,
  formatWorkspaceDate,
} from "@/inventory/workspace";
import type { WorkspaceLocationDetail } from "@/types/inventory-workspace";
import { ReadOnlyBadge } from "./ReadOnlyBadge";

export function LocationHeader({
  location,
  canManage,
  now,
  onRename,
  onArchive,
  onRestore,
}: {
  location: WorkspaceLocationDetail;
  canManage: boolean;
  now?: Date;
  onRename?: () => void;
  onArchive?: () => void;
  onRestore?: () => void;
}) {
  const storage = location.kind === "storage";
  const archive = canArchiveWorkspaceLocation(location);
  return (
    <header className="mt-4 space-y-4" data-testid="location-header">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="break-words text-3xl font-semibold tracking-tight">{location.name}</h1>
            {storage ? (
              <Badge variant="outline">Storage location</Badge>
            ) : (
              <Badge variant="secondary" className="gap-1">
                <Lock className="h-3 w-3" />
                System · Unassigned
              </Badge>
            )}
            <Badge variant={location.active ? "outline" : "secondary"}>
              {location.active ? "Active" : "Archived"}
            </Badge>
            {!canManage && <ReadOnlyBadge />}
          </div>
          <p className="mt-2 text-sm text-muted-foreground">
            {storage
              ? location.description || "A physical place stock is kept."
              : "Received stock not yet placed in a physical location. It is never counted and has no QR labels."}
          </p>
        </div>
        {canManage && storage && (
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" onClick={onRename}>
              <Pencil className="mr-2 h-4 w-4" />
              Rename
            </Button>
            {location.active ? (
              <Button
                variant="outline"
                disabled={!archive.allowed}
                title={archive.reason}
                onClick={onArchive}
              >
                <Archive className="mr-2 h-4 w-4" />
                Archive
              </Button>
            ) : (
              <Button variant="outline" onClick={onRestore}>
                <ArchiveRestore className="mr-2 h-4 w-4" />
                Restore
              </Button>
            )}
          </div>
        )}
      </div>
      {canManage && storage && location.active && !archive.allowed && (
        <p className="text-xs text-muted-foreground">{archive.reason}</p>
      )}
      <dl className="grid gap-3 rounded-xl border bg-card p-4 text-sm sm:grid-cols-2 lg:grid-cols-4">
        <Fact label="Items stocked">
          {location.stockedItemCount}
          {location.archivedStockedItemCount > 0 &&
            ` (${location.archivedStockedItemCount} archived)`}
        </Fact>
        {storage && (
          <>
            <Fact label="Countable items">{location.countableItemCount ?? 0}</Fact>
            <Fact label="Last counted">
              <span className="block">{countAgeLabel(location, now)}</span>
              {location.lastCountedAt && (
                <span className="block text-xs font-normal text-muted-foreground">
                  {formatWorkspaceDate(location.lastCountedAt)}
                  {location.lastCountedByName ? ` by ${location.lastCountedByName}` : ""}
                </span>
              )}
            </Fact>
            <Fact label="Active QR labels">
              {location.activeLabelCount ?? 0}
              <span className="block text-xs font-normal text-muted-foreground">
                Last issued {formatWorkspaceDate(location.lastLabelIssuedAt)}
              </span>
            </Fact>
          </>
        )}
      </dl>
    </header>
  );
}

function Fact({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="font-medium tabular-nums">{children}</dd>
    </div>
  );
}

import { Link } from "@tanstack/react-router";
import { Archive, ArchiveRestore, Lock, MoreHorizontal, Pencil } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  canArchiveWorkspaceLocation,
  countAgeLabel,
  formatWorkspaceDate,
} from "@/inventory/workspace";
import type { WorkspaceLocation } from "@/types/inventory-workspace";

const columns =
  "md:grid md:grid-cols-[minmax(12rem,2fr)_6rem_6rem_6rem_minmax(10rem,1.5fr)_6rem_8rem_3rem] md:items-center md:gap-3";

// Unassigned first and visibly a system location; physical locations after it. Every value
// is factual: there is no count cadence, so no fresh, due or overdue.
export function LocationsTable({
  locations,
  canManage,
  now,
  onRename,
  onArchive,
  onRestore,
}: {
  locations: WorkspaceLocation[];
  canManage: boolean;
  now?: Date;
  onRename?: (location: WorkspaceLocation) => void;
  onArchive?: (location: WorkspaceLocation) => void;
  onRestore?: (location: WorkspaceLocation) => void;
}) {
  if (!locations.length)
    return (
      <div className="rounded-xl border border-dashed bg-card px-6 py-12 text-center text-sm text-muted-foreground">
        No locations match this filter.
      </div>
    );
  return (
    <div className="rounded-xl border bg-card" data-testid="locations-table">
      <div
        className={`hidden border-b px-4 py-2 text-xs font-medium text-muted-foreground ${columns}`}
        aria-hidden="true"
      >
        <span>Location</span>
        <span>Status</span>
        <span>Items stocked</span>
        <span>Countable</span>
        <span>Last counted</span>
        <span>Active labels</span>
        <span>Last label issued</span>
        <span />
      </div>
      <ul className="divide-y">
        {locations.map((location) =>
          location.kind === "unassigned" ? (
            <li
              key={location.id}
              data-location-kind="unassigned"
              className={`bg-muted/40 px-4 py-3 ${columns}`}
            >
              <div className="flex min-w-0 flex-wrap items-center gap-2">
                <Link
                  to="/inventory/locations/$locationId"
                  params={{ locationId: location.id }}
                  className="break-words font-medium hover:underline"
                >
                  {location.name}
                </Link>
                <Badge variant="secondary" className="gap-1">
                  <Lock className="h-3 w-3" />
                  System
                </Badge>
              </div>
              <p className="mt-1 text-xs text-muted-foreground md:col-span-7 md:mt-0">
                Received stock not yet placed in a physical location · {location.stockedItemCount}{" "}
                item{location.stockedItemCount === 1 ? "" : "s"} · Not counted or labeled
              </p>
            </li>
          ) : (
            <StorageRow
              key={location.id}
              location={location}
              canManage={canManage}
              now={now}
              onRename={onRename}
              onArchive={onArchive}
              onRestore={onRestore}
            />
          ),
        )}
      </ul>
    </div>
  );
}

function Stat({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-2 text-sm md:block">
      <span className="text-xs text-muted-foreground md:hidden">{label}</span>
      <span className="text-right tabular-nums md:text-left">{children}</span>
    </div>
  );
}

function StorageRow({
  location,
  canManage,
  now,
  onRename,
  onArchive,
  onRestore,
}: {
  location: WorkspaceLocation;
  canManage: boolean;
  now?: Date;
  onRename?: (location: WorkspaceLocation) => void;
  onArchive?: (location: WorkspaceLocation) => void;
  onRestore?: (location: WorkspaceLocation) => void;
}) {
  const archive = canArchiveWorkspaceLocation(location);
  const age = countAgeLabel(location, now);
  return (
    <li data-location-kind="storage" className={`space-y-1.5 px-4 py-3 md:space-y-0 ${columns}`}>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <Link
          to="/inventory/locations/$locationId"
          params={{ locationId: location.id }}
          className={`break-words font-medium hover:underline ${location.active ? "" : "text-muted-foreground"}`}
        >
          {location.name}
        </Link>
        <span className="md:hidden">
          <Badge variant={location.active ? "outline" : "secondary"}>
            {location.active ? "Active" : "Archived"}
          </Badge>
        </span>
      </div>
      <div className="hidden md:block">
        <Badge variant={location.active ? "outline" : "secondary"}>
          {location.active ? "Active" : "Archived"}
        </Badge>
      </div>
      <Stat label="Items stocked">{location.stockedItemCount}</Stat>
      <Stat label="Countable">{location.countableItemCount ?? 0}</Stat>
      <Stat label="Last counted">
        <span className="block">{age}</span>
        {location.lastCountedAt && (
          <span className="block text-xs text-muted-foreground">
            {formatWorkspaceDate(location.lastCountedAt)}
            {location.lastCountedByName ? ` · ${location.lastCountedByName}` : ""}
          </span>
        )}
      </Stat>
      <Stat label="Active labels">{location.activeLabelCount ?? 0}</Stat>
      <Stat label="Last label issued">{formatWorkspaceDate(location.lastLabelIssuedAt)}</Stat>
      <div className="flex justify-end">
        {canManage && (
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button size="icon" variant="ghost" aria-label={`Actions for ${location.name}`}>
                <MoreHorizontal className="h-4 w-4" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem onClick={() => onRename?.(location)}>
                <Pencil className="mr-2 h-3.5 w-3.5" />
                Rename
              </DropdownMenuItem>
              {location.active ? (
                <DropdownMenuItem
                  disabled={!archive.allowed}
                  title={archive.reason}
                  onClick={() => archive.allowed && onArchive?.(location)}
                >
                  <Archive className="mr-2 h-3.5 w-3.5" />
                  {archive.allowed ? "Archive" : "Archive (move stock out first)"}
                </DropdownMenuItem>
              ) : (
                <DropdownMenuItem onClick={() => onRestore?.(location)}>
                  <ArchiveRestore className="mr-2 h-3.5 w-3.5" />
                  Restore
                </DropdownMenuItem>
              )}
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </div>
    </li>
  );
}

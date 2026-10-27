import { useState } from "react";
import { Archive, ArchiveRestore, Lock, MapPin, Pencil, Plus, QrCode } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { canArchiveInventoryLocation, summarizeInventoryLocations } from "@/inventory/locations";
import type { InventoryLocation, InventoryLocationBalance } from "@/types/inventory";

export interface LocationCountStatus {
  activeLabelCount: number;
  lastCountedAt: string | null;
}

const shortDate = (iso: string) =>
  new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric" });

// Minimal owner administration of physical inventory locations (Phase 7A.1). Cabinets,
// carts and rooms live here, never in Settings > Locations (sites and request destinations).
// Phase 7A.2 adds each storage location's QR label and when it was last counted.
export function InventoryLocationsPanel({
  locations,
  balances,
  onCreate,
  onRename,
  onSetActive,
  countStatus,
  onQrLabel,
}: {
  locations: InventoryLocation[];
  balances: InventoryLocationBalance[];
  onCreate: (name: string) => Promise<void>;
  onRename: (location: InventoryLocation, name: string) => Promise<void>;
  onSetActive: (location: InventoryLocation, active: boolean) => Promise<void>;
  countStatus?: ReadonlyMap<string, LocationCountStatus>;
  onQrLabel?: (location: InventoryLocation) => void;
}) {
  const [name, setName] = useState("");
  const [creating, setCreating] = useState(false);
  const [editingId, setEditingId] = useState<string>();
  const [editName, setEditName] = useState("");
  const [busyId, setBusyId] = useState<string>();
  const [error, setError] = useState("");
  const summaries = summarizeInventoryLocations(locations, balances);

  async function run(id: string | undefined, action: () => Promise<void>) {
    setError("");
    setBusyId(id);
    try {
      await action();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not update the location.");
    } finally {
      setBusyId(undefined);
    }
  }
  async function create(event: React.FormEvent) {
    event.preventDefault();
    if (creating) return;
    setCreating(true);
    await run(undefined, async () => {
      await onCreate(name.trim());
      setName("");
    });
    setCreating(false);
  }

  return (
    <section
      aria-labelledby="inventory-locations-heading"
      className="mt-6 rounded-xl border bg-card p-4 sm:p-5"
      data-section="inventory-locations"
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 id="inventory-locations-heading" className="flex items-center gap-2 font-medium">
            <MapPin className="h-4 w-4 text-primary" />
            Inventory locations
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Physical places stock is kept, such as cabinets, carts and supply rooms. New receipts
            arrive in Unassigned.
          </p>
        </div>
      </div>
      <form onSubmit={create} className="mt-4 flex flex-col gap-2 sm:flex-row">
        <Input
          aria-label="New location name"
          placeholder="e.g. Training Room Cabinet A"
          maxLength={120}
          value={name}
          onChange={(e) => setName(e.target.value)}
          required
          className="h-10 sm:max-w-sm"
        />
        <Button disabled={creating || !name.trim()} className="h-10">
          <Plus className="mr-2 h-4 w-4" />
          {creating ? "Adding…" : "Add location"}
        </Button>
      </form>
      {error && (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error}
        </p>
      )}
      <ul className="mt-4 divide-y rounded-lg border">
        {summaries.map((location) => {
          const archive = canArchiveInventoryLocation(location, balances);
          const busy = busyId === location.id;
          return (
            <li
              key={location.id}
              className="flex flex-col gap-2 px-3 py-3 sm:flex-row sm:items-center sm:justify-between"
              data-location-kind={location.kind}
            >
              {editingId === location.id ? (
                <form
                  className="flex w-full flex-col gap-2 sm:flex-row"
                  onSubmit={(event) => {
                    event.preventDefault();
                    void run(location.id, async () => {
                      await onRename(location, editName.trim());
                      setEditingId(undefined);
                    });
                  }}
                >
                  <Input
                    aria-label={`Rename ${location.name}`}
                    value={editName}
                    maxLength={120}
                    onChange={(e) => setEditName(e.target.value)}
                    required
                    autoFocus
                    className="h-10"
                  />
                  <div className="flex gap-2">
                    <Button size="sm" className="h-10" disabled={busy || !editName.trim()}>
                      Save
                    </Button>
                    <Button
                      size="sm"
                      type="button"
                      variant="ghost"
                      className="h-10"
                      onClick={() => setEditingId(undefined)}
                    >
                      Cancel
                    </Button>
                  </div>
                </form>
              ) : (
                <>
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span
                        className={`break-words font-medium ${location.active ? "" : "text-muted-foreground line-through"}`}
                      >
                        {location.name}
                      </span>
                      {location.kind === "unassigned" && (
                        <Badge variant="secondary" className="gap-1">
                          <Lock className="h-3 w-3" />
                          System
                        </Badge>
                      )}
                      {!location.active && <Badge variant="outline">Archived</Badge>}
                    </div>
                    <p className="mt-0.5 text-xs text-muted-foreground">
                      {location.kind === "unassigned"
                        ? "Received stock not yet placed in a physical location. Protected."
                        : location.itemCount === 0
                          ? "Empty"
                          : `${location.itemCount} item${location.itemCount === 1 ? "" : "s"} stocked here`}
                      {location.kind === "unassigned" &&
                        location.itemCount > 0 &&
                        ` · ${location.itemCount} item${location.itemCount === 1 ? "" : "s"}`}
                      {location.kind === "storage" &&
                        countStatus &&
                        ` · ${(() => {
                          const status = countStatus.get(location.id);
                          return status?.lastCountedAt
                            ? `Counted ${shortDate(status.lastCountedAt)}`
                            : "Not counted yet";
                        })()}`}
                    </p>
                  </div>
                  {location.kind !== "unassigned" && (
                    <div className="flex shrink-0 flex-wrap gap-1">
                      {onQrLabel && location.active && (
                        <Button
                          size="sm"
                          variant="ghost"
                          className="h-9"
                          onClick={() => onQrLabel(location)}
                          aria-label={`QR label for ${location.name}`}
                        >
                          <QrCode className="mr-1 h-3.5 w-3.5" />
                          QR label
                        </Button>
                      )}
                      <Button
                        size="sm"
                        variant="ghost"
                        className="h-9"
                        onClick={() => {
                          setEditingId(location.id);
                          setEditName(location.name);
                          setError("");
                        }}
                        aria-label={`Rename ${location.name}`}
                      >
                        <Pencil className="mr-1 h-3.5 w-3.5" />
                        Rename
                      </Button>
                      {location.active ? (
                        <Button
                          size="sm"
                          variant="ghost"
                          className="h-9"
                          disabled={busy || !archive.allowed}
                          title={archive.reason}
                          aria-label={`Archive ${location.name}`}
                          onClick={() => void run(location.id, () => onSetActive(location, false))}
                        >
                          <Archive className="mr-1 h-3.5 w-3.5" />
                          Archive
                        </Button>
                      ) : (
                        <Button
                          size="sm"
                          variant="ghost"
                          className="h-9"
                          disabled={busy}
                          aria-label={`Restore ${location.name}`}
                          onClick={() => void run(location.id, () => onSetActive(location, true))}
                        >
                          <ArchiveRestore className="mr-1 h-3.5 w-3.5" />
                          Restore
                        </Button>
                      )}
                    </div>
                  )}
                  {location.kind !== "unassigned" && location.active && !archive.allowed && (
                    <p className="text-xs text-muted-foreground sm:hidden">{archive.reason}</p>
                  )}
                </>
              )}
            </li>
          );
        })}
      </ul>
    </section>
  );
}

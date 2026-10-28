import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { MapPin, Plus } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { listWorkspaceLocationsFn } from "@/lib/inventory-workspace.functions";
import { workspaceQueryKey } from "@/inventory/workspace";
import type {
  InventoryWorkspaceStatusFilter,
  WorkspaceLocation,
} from "@/types/inventory-workspace";
import { LocationManageDialogs, type LocationManageAction } from "./LocationManageDialogs";
import { LocationsTable } from "./LocationsTable";
import { useLocationOwnerActions } from "./useLocationOwnerActions";

const filters: Array<{ value: InventoryWorkspaceStatusFilter; label: string }> = [
  { value: "active", label: "Active" },
  { value: "archived", label: "Archived" },
  { value: "all", label: "All" },
];

export function LocationsTab({
  organizationId,
  canManage,
}: {
  organizationId: string;
  canManage: boolean;
}) {
  const [status, setStatus] = useState<InventoryWorkspaceStatusFilter>("active");
  const [manage, setManage] = useState<LocationManageAction>();
  const [error, setError] = useState("");
  const list = useServerFn(listWorkspaceLocationsFn);
  const actions = useLocationOwnerActions(organizationId);
  const locations = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "locations", status],
    queryFn: () => list({ data: { organizationId, status } }),
  });

  async function restore(location: WorkspaceLocation) {
    setError("");
    try {
      await actions.setActive(location, true);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not restore the location.");
    }
  }

  return (
    <section aria-labelledby="inventory-locations-heading" data-section="inventory-locations">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div className="min-w-0">
          <h2 id="inventory-locations-heading" className="flex items-center gap-2 font-medium">
            <MapPin className="h-4 w-4 text-primary" />
            Locations
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Physical places stock is kept, such as cabinets, carts and supply rooms. New receipts
            arrive in Unassigned.
          </p>
        </div>
        <div role="group" aria-label="Location status" className="flex rounded-md border p-0.5">
          {filters.map((filter) => (
            <button
              key={filter.value}
              type="button"
              aria-pressed={status === filter.value}
              onClick={() => setStatus(filter.value)}
              className={`min-h-9 rounded px-3 text-sm ${status === filter.value ? "bg-accent font-medium text-accent-foreground" : "text-muted-foreground hover:bg-muted"}`}
            >
              {filter.label}
            </button>
          ))}
        </div>
      </div>
      {canManage && <AddLocationForm onCreate={actions.create} />}
      {error && (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error}
        </p>
      )}
      <div className="mt-4">
        {locations.isLoading && (
          <p className="py-8 text-center text-sm text-muted-foreground">Loading locations…</p>
        )}
        {locations.isError && (
          <Alert variant="destructive">
            <AlertTitle>Could not load locations</AlertTitle>
            <AlertDescription>
              {locations.error instanceof Error ? locations.error.message : "Try again."}
            </AlertDescription>
          </Alert>
        )}
        {locations.data && (
          <LocationsTable
            locations={locations.data.locations}
            canManage={canManage}
            onRename={(location) => setManage({ kind: "rename", location })}
            onArchive={(location) => setManage({ kind: "archive", location })}
            onRestore={(location) => void restore(location)}
          />
        )}
      </div>
      {canManage && (
        <LocationManageDialogs
          action={manage}
          onClose={() => setManage(undefined)}
          onRename={actions.rename}
          onArchive={(location) => actions.setActive(location, false)}
          onRevoke={async (location) => {
            await actions.revoke(location);
          }}
        />
      )}
    </section>
  );
}

function AddLocationForm({ onCreate }: { onCreate: (name: string) => Promise<void> }) {
  const [name, setName] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (saving) return;
    setSaving(true);
    setError("");
    try {
      await onCreate(name.trim());
      setName("");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not add the location.");
    } finally {
      setSaving(false);
    }
  }
  return (
    <form onSubmit={submit} className="mt-4 flex flex-col gap-2 sm:flex-row">
      <Input
        aria-label="New location name"
        placeholder="e.g. Training Room Cabinet A"
        maxLength={120}
        value={name}
        onChange={(e) => setName(e.target.value)}
        required
        className="h-10 sm:max-w-sm"
      />
      <Button disabled={saving || !name.trim()} className="h-10">
        <Plus className="mr-2 h-4 w-4" />
        {saving ? "Adding…" : "Add location"}
      </Button>
      {error && (
        <p role="alert" className="text-sm text-destructive sm:self-center">
          {error}
        </p>
      )}
    </form>
  );
}

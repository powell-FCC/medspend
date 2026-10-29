import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { AlertCircle, ArrowLeft } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useActiveOrg } from "@/hooks/use-active-org";
import { getWorkspaceLocationFn } from "@/lib/inventory-workspace.functions";
import {
  inventoryWorkspaceAccess,
  type LocationDetailTab,
  workspaceQueryKey,
} from "@/inventory/workspace";
import type { WorkspaceLocationDetail } from "@/types/inventory-workspace";
import { CountHistoryPanel } from "./CountHistoryPanel";
import { ItemStockDialogs, type ItemStockAction } from "./ItemStockDialogs";
import { LocationHeader } from "./LocationHeader";
import { LocationLabelsPanel } from "./LocationLabelsPanel";
import { LocationManageDialogs, type LocationManageAction } from "./LocationManageDialogs";
import { LocationStockTab } from "./LocationStockTab";
import { useLocationOwnerActions } from "./useLocationOwnerActions";

export function LocationDetailPage({
  locationId,
  tab,
  onTabChange,
}: {
  locationId: string;
  tab: LocationDetailTab;
  onTabChange: (tab: LocationDetailTab) => void;
}) {
  const { active, loading } = useActiveOrg();
  const access = inventoryWorkspaceAccess(active?.role);
  const organizationId = active?.organizationId ?? "";
  const get = useServerFn(getWorkspaceLocationFn);
  const location = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "location", locationId],
    queryFn: () => get({ data: { organizationId, locationId } }),
    enabled: Boolean(organizationId && access.canRead),
  });
  if (loading) return <Centered>Loading…</Centered>;
  if (!active || !access.canRead)
    return (
      <div className="mx-auto max-w-3xl px-6 py-16">
        <Alert variant="destructive">
          <AlertCircle />
          <AlertTitle>Owner or admin access required</AlertTitle>
          <AlertDescription>
            Only organization owners and admins can view inventory.
          </AlertDescription>
        </Alert>
      </div>
    );
  return (
    <div className="mx-auto max-w-7xl px-5 py-8 sm:px-8" data-page="inventory-location">
      <Link
        to="/inventory"
        search={{ tab: "locations" }}
        className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="h-4 w-4" />
        Locations
      </Link>
      {location.isLoading && <Centered>Loading location…</Centered>}
      {location.isError && (
        <Alert variant="destructive" className="mt-6">
          <AlertCircle />
          <AlertTitle>Could not load this location</AlertTitle>
          <AlertDescription>
            {location.error instanceof Error ? location.error.message : "Try again."}
          </AlertDescription>
        </Alert>
      )}
      {location.data && (
        <LocationDetail
          organizationId={organizationId}
          location={location.data}
          canManage={access.canManage}
          tab={location.data.kind === "unassigned" ? "stock" : tab}
          onTabChange={onTabChange}
        />
      )}
    </div>
  );
}

function LocationDetail({
  organizationId,
  location,
  canManage,
  tab,
  onTabChange,
}: {
  organizationId: string;
  location: WorkspaceLocationDetail;
  canManage: boolean;
  tab: LocationDetailTab;
  onTabChange: (tab: LocationDetailTab) => void;
}) {
  const [stockAction, setStockAction] = useState<ItemStockAction>();
  const [manage, setManage] = useState<LocationManageAction>();
  const [error, setError] = useState("");
  const actions = useLocationOwnerActions(organizationId);
  const storage = location.kind === "storage";

  return (
    <>
      <LocationHeader
        location={location}
        canManage={canManage}
        onRename={() => setManage({ kind: "rename", location })}
        onArchive={() => setManage({ kind: "archive", location })}
        onRestore={async () => {
          setError("");
          try {
            await actions.setActive(location, true);
          } catch (cause) {
            setError(cause instanceof Error ? cause.message : "Could not restore the location.");
          }
        }}
      />
      {error && (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error}
        </p>
      )}
      <Tabs
        value={tab}
        onValueChange={(value) => onTabChange(value as LocationDetailTab)}
        className="mt-6"
      >
        <TabsList>
          <TabsTrigger value="stock">Stock</TabsTrigger>
          {storage && <TabsTrigger value="labels">Labels</TabsTrigger>}
          {storage && <TabsTrigger value="counts">Counts</TabsTrigger>}
        </TabsList>
        <TabsContent value="stock" className="mt-4">
          <LocationStockTab
            organizationId={organizationId}
            location={location}
            canManage={canManage}
            onAction={setStockAction}
          />
        </TabsContent>
        {storage && (
          <TabsContent value="labels" className="mt-4 max-w-xl">
            <LocationLabelsPanel
              location={location}
              canManage={canManage}
              origin={typeof window === "undefined" ? "" : window.location.origin}
              onIssue={canManage ? () => actions.issue(location) : undefined}
              onReplace={canManage ? () => actions.replace(location) : undefined}
              onRevoke={canManage ? () => actions.revoke(location) : undefined}
            />
          </TabsContent>
        )}
        {storage && (
          <TabsContent value="counts" className="mt-4">
            <CountHistoryPanel organizationId={organizationId} locationId={location.id} />
          </TabsContent>
        )}
      </Tabs>
      {canManage && (
        <>
          <ItemStockDialogs
            organizationId={organizationId}
            action={stockAction}
            onClose={() => setStockAction(undefined)}
          />
          <LocationManageDialogs
            action={manage}
            onClose={() => setManage(undefined)}
            onRename={actions.rename}
            onArchive={(target) => actions.setActive(target, false)}
            onRevoke={async (target) => {
              await actions.revoke(target);
            }}
          />
        </>
      )}
    </>
  );
}

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="py-12 text-center text-sm text-muted-foreground">{children}</div>;
}

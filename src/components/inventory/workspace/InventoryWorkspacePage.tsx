import { AlertCircle } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useActiveOrg } from "@/hooks/use-active-org";
import { inventoryWorkspaceAccess, type WorkspaceTab } from "@/inventory/workspace";
import { CountHistoryPanel } from "./CountHistoryPanel";
import { ItemsTab } from "./ItemsTab";
import { LocationsTab } from "./LocationsTab";
import { ReadOnlyBadge } from "./ReadOnlyBadge";

// Phase 7B.1 Inventory workspace. Owners manage inventory; admins see the same information
// read-only. Counts (7B.2) is read-only history for both. Later packages add Overview and
// Activity tabs here.
export function InventoryWorkspacePage({
  tab,
  onTabChange,
}: {
  tab: WorkspaceTab;
  onTabChange: (tab: WorkspaceTab) => void;
}) {
  const { active, loading } = useActiveOrg();
  const access = inventoryWorkspaceAccess(active?.role);
  if (loading)
    return (
      <div className="mx-auto max-w-7xl px-5 py-12 text-center text-sm text-muted-foreground sm:px-8">
        Loading inventory...
      </div>
    );
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
    <div className="mx-auto max-w-7xl px-5 py-8 sm:px-8" data-page="inventory">
      <div className="flex flex-wrap items-center gap-2">
        <p className="text-sm font-medium text-primary">
          {access.canManage ? "Owner workspace" : "Admin workspace"}
        </p>
        {!access.canManage && <ReadOnlyBadge />}
      </div>
      <h1 className="mt-1 text-3xl font-semibold tracking-tight">Inventory</h1>
      <p className="mt-2 text-sm text-muted-foreground">
        {access.canManage
          ? "Manage supplies and where they are kept."
          : "See supplies and where they are kept. Only owners can change inventory."}
      </p>
      <Tabs
        value={tab}
        onValueChange={(value) => onTabChange(value as WorkspaceTab)}
        className="mt-6"
      >
        <TabsList>
          <TabsTrigger value="items">Items</TabsTrigger>
          <TabsTrigger value="locations">Locations</TabsTrigger>
          <TabsTrigger value="counts">Counts</TabsTrigger>
        </TabsList>
        <TabsContent value="items" className="mt-4">
          <ItemsTab organizationId={active.organizationId} canManage={access.canManage} />
        </TabsContent>
        <TabsContent value="locations" className="mt-4">
          <LocationsTab organizationId={active.organizationId} canManage={access.canManage} />
        </TabsContent>
        <TabsContent value="counts" className="mt-4">
          <CountHistoryPanel organizationId={active.organizationId} />
        </TabsContent>
      </Tabs>
    </div>
  );
}

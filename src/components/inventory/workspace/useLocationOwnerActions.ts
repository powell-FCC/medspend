import { useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import {
  createInventoryLocationFn,
  setInventoryLocationActiveFn,
  updateInventoryLocationFn,
} from "@/lib/inventory.functions";
import {
  issueLocationLabelFn,
  replaceLocationLabelsFn,
  revokeLocationLabelsFn,
} from "@/lib/inventory-count.functions";
import { workspaceQueryKey } from "@/inventory/workspace";
import type { WorkspaceLocation } from "@/types/inventory-workspace";

// Owner location and label mutations. Each server function re-checks the owner role and
// each database function checks it again; the workspace only offers these to owners.
export function useLocationOwnerActions(organizationId: string) {
  const queryClient = useQueryClient();
  const create = useServerFn(createInventoryLocationFn);
  const update = useServerFn(updateInventoryLocationFn);
  const setActive = useServerFn(setInventoryLocationActiveFn);
  const issue = useServerFn(issueLocationLabelFn);
  const revoke = useServerFn(revokeLocationLabelsFn);
  const replace = useServerFn(replaceLocationLabelsFn);
  const refresh = () =>
    queryClient.invalidateQueries({ queryKey: workspaceQueryKey(organizationId) });
  const target = (location: Pick<WorkspaceLocation, "id">) => ({
    organizationId,
    locationId: location.id,
  });

  return {
    async create(name: string) {
      await create({ data: { organizationId, name } });
      await refresh();
    },
    async rename(location: WorkspaceLocation, name: string) {
      await update({
        data: {
          organizationId,
          inventoryLocationId: location.id,
          name,
          description: location.description,
        },
      });
      await refresh();
    },
    async setActive(location: WorkspaceLocation, active: boolean) {
      try {
        await setActive({ data: { organizationId, inventoryLocationId: location.id, active } });
      } finally {
        await refresh();
      }
    },
    async issue(location: WorkspaceLocation) {
      try {
        return await issue({ data: target(location) });
      } finally {
        await refresh();
      }
    },
    async replace(location: WorkspaceLocation) {
      try {
        return await replace({ data: target(location) });
      } finally {
        await refresh();
      }
    },
    async revoke(location: WorkspaceLocation) {
      try {
        return await revoke({ data: target(location) });
      } finally {
        await refresh();
      }
    },
  };
}

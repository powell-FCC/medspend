import { useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import {
  setReplenishmentRuleEnabledFn,
  setReplenishmentRuleFn,
} from "@/lib/inventory-replenishment.functions";
import { replenishmentQueryKey } from "@/inventory/replenishment";
import type { ReplenishmentRow } from "@/types/inventory-replenishment";
import type { RuleDialogState, RuleDialogSubmit } from "@/types/inventory-replenishment";

// Owner rule writes (Phase 7D). Each one refreshes every replenishment query; a stale screen
// gets the database's "changed since you opened it" message.
export function useReplenishmentRuleActions(organizationId: string) {
  const queryClient = useQueryClient();
  const setRule = useServerFn(setReplenishmentRuleFn);
  const setEnabled = useServerFn(setReplenishmentRuleEnabledFn);
  const refresh = () =>
    queryClient.invalidateQueries({ queryKey: replenishmentQueryKey(organizationId) });
  return {
    save: async (state: RuleDialogState, input: RuleDialogSubmit) => {
      await setRule({
        data: {
          organizationId,
          inventoryItemId: input.inventoryItemId,
          locationId: state.locationId,
          minimumQuantity: input.minimumQuantity,
          targetQuantity: input.targetQuantity,
          expectedUpdatedAt: input.expectedUpdatedAt,
        },
      });
      await refresh();
    },
    toggle: async (row: ReplenishmentRow) => {
      try {
        await setEnabled({
          data: {
            organizationId,
            ruleId: row.ruleId,
            enabled: !row.enabled,
            expectedUpdatedAt: row.updatedAt,
          },
        });
      } finally {
        await refresh();
      }
    },
  };
}

export const editState = (row: ReplenishmentRow): RuleDialogState => ({
  mode: "edit",
  locationId: row.inventoryLocationId,
  locationName: row.locationName,
  item: { id: row.inventoryItemId, name: row.itemName, unit: row.itemUnit },
  minimum: row.minimumQuantity,
  target: row.targetQuantity,
  updatedAt: row.updatedAt,
});

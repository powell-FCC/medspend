import { useCallback, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { listLocationReplenishmentRulesFn } from "@/lib/inventory-replenishment.functions";
import { listWorkspaceItemsFn } from "@/lib/inventory-workspace.functions";
import { replenishmentQueryKey } from "@/inventory/replenishment";
import type { ReplenishmentRow } from "@/types/inventory-replenishment";
import type { WorkspaceLocation } from "@/types/inventory-workspace";
import { ReplenishmentRowCard, type ReplenishmentRowActions } from "./ReplenishmentRowCard";
import { ReplenishmentRuleDialog } from "./ReplenishmentRuleDialog";
import type { RuleDialogItem, RuleDialogState } from "@/types/inventory-replenishment";
import { editState, useReplenishmentRuleActions } from "./useReplenishmentRuleActions";

// Phase 7D: Minimum and Target for items at one storage location, on its Stock tab. Owners set,
// edit and turn rules off or on; admins read. An item needs no stock here to get a rule, and
// setting one never creates stock or a balance.
export function LocationReplenishmentRules({
  organizationId,
  location,
  canManage,
}: {
  organizationId: string;
  location: WorkspaceLocation;
  canManage: boolean;
}) {
  const [dialog, setDialog] = useState<RuleDialogState>();
  const [search, setSearch] = useState("");
  const [error, setError] = useState("");
  const listRules = useServerFn(listLocationReplenishmentRulesFn);
  const listItems = useServerFn(listWorkspaceItemsFn);
  const actions = useReplenishmentRuleActions(organizationId);
  const rules = useQuery({
    queryKey: [...replenishmentQueryKey(organizationId), "location", location.id],
    queryFn: () => listRules({ data: { organizationId, locationId: location.id } }),
  });
  const creating = dialog?.mode === "create";
  const items = useQuery({
    queryKey: [...replenishmentQueryKey(organizationId), "item-picker", search],
    queryFn: () =>
      listItems({ data: { organizationId, search, status: "active", cursor: null, limit: 50 } }),
    enabled: canManage && creating,
  });
  const onSearch = useCallback((value: string) => setSearch(value), []);

  if (rules.isLoading)
    return <p className="text-sm text-muted-foreground">Loading Minimum and Target…</p>;
  if (rules.isError || !rules.data)
    return (
      <Alert variant="destructive">
        <AlertTitle>Could not load replenishment rules</AlertTitle>
        <AlertDescription>
          {rules.error instanceof Error ? rules.error.message : "Try again."}
        </AlertDescription>
      </Alert>
    );

  const ruled = new Set(rules.data.rules.map((rule) => rule.inventoryItemId));
  const pickerItems: RuleDialogItem[] = (items.data?.rows ?? [])
    .filter((item) => !ruled.has(item.id))
    .map((item) => ({ id: item.id, name: item.name, unit: item.unit }));
  const createState: RuleDialogState | undefined =
    dialog?.mode === "create" ? { ...dialog, items: pickerItems } : dialog;

  return (
    <>
      <LocationReplenishmentRulesView
        location={location}
        rows={rules.data.rules}
        canManage={canManage}
        error={error}
        onAdd={
          canManage && location.active
            ? () =>
                setDialog({
                  mode: "create",
                  locationId: location.id,
                  locationName: location.name,
                  items: [],
                })
            : undefined
        }
        onEdit={canManage ? (row) => setDialog(editState(row)) : undefined}
        onToggleEnabled={
          canManage
            ? async (row) => {
                setError("");
                try {
                  await actions.toggle(row);
                } catch (cause) {
                  setError(cause instanceof Error ? cause.message : "Could not change the rule.");
                }
              }
            : undefined
        }
      />
      {canManage && (
        <ReplenishmentRuleDialog
          state={createState}
          onSearch={onSearch}
          onOpenChange={(open) => !open && setDialog(undefined)}
          onSubmit={async (input) => {
            if (!dialog) return;
            await actions.save(dialog, input);
            setDialog(undefined);
          }}
        />
      )}
    </>
  );
}

export function LocationReplenishmentRulesView({
  location,
  rows,
  canManage,
  error,
  onAdd,
  now,
  ...actions
}: {
  location: WorkspaceLocation;
  rows: ReplenishmentRow[];
  canManage: boolean;
  error?: string;
  onAdd?: () => void;
  now?: Date;
} & Pick<ReplenishmentRowActions, "onEdit" | "onToggleEnabled">) {
  return (
    <section
      className="space-y-2"
      aria-label="Minimum and Target"
      data-testid="location-replenishment"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-base font-semibold">Minimum and Target here</h2>
          <p className="text-xs text-muted-foreground">
            Replenishment flags an item at {location.name} when it is at or below its Minimum.
          </p>
        </div>
        {canManage && onAdd && (
          <Button size="sm" variant="outline" onClick={onAdd}>
            Set Minimum / Target
          </Button>
        )}
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      {rows.length ? (
        <ul className="divide-y rounded-xl border bg-card">
          {rows.map((row) => (
            <ReplenishmentRowCard
              key={row.ruleId}
              row={row}
              canManage={canManage}
              showLocation={false}
              now={now}
              {...actions}
            />
          ))}
        </ul>
      ) : (
        <p className="rounded-xl border border-dashed bg-card px-4 py-4 text-sm text-muted-foreground">
          No item has a Minimum and Target at {location.name} yet.
        </p>
      )}
    </section>
  );
}

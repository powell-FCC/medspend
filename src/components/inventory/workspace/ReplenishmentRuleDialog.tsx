import { useEffect, useState } from "react";
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
import { formatQuantity } from "@/inventory/locations";
import {
  ruleDialogDescription,
  ruleDialogTitle,
  validateRuleInput,
} from "@/inventory/replenishment";
import type { RuleDialogState, RuleDialogSubmit } from "@/types/inventory-replenishment";

// Set or edit the Minimum and Target for one item at one storage location (owners only).
export function ReplenishmentRuleDialog({
  state,
  onOpenChange,
  onSubmit,
  onSearch,
}: {
  state?: RuleDialogState;
  onOpenChange: (open: boolean) => void;
  onSubmit: (input: RuleDialogSubmit) => Promise<void>;
  onSearch?: (search: string) => void;
}) {
  return (
    <Dialog open={Boolean(state)} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[92dvh] overflow-y-auto sm:max-w-md">
        {state && (
          <DialogHeader>
            <DialogTitle className="break-words">{ruleDialogTitle(state)}</DialogTitle>
            <DialogDescription>{ruleDialogDescription(state)}</DialogDescription>
          </DialogHeader>
        )}
        {state && (
          <RuleForm key={formKey(state)} state={state} onSubmit={onSubmit} onSearch={onSearch} />
        )}
      </DialogContent>
    </Dialog>
  );
}

const formKey = (state: RuleDialogState) =>
  state.mode === "edit" ? `edit-${state.item.id}-${state.updatedAt}` : `create-${state.locationId}`;

export function RuleForm({
  state,
  onSubmit,
  onSearch,
}: {
  state: RuleDialogState;
  onSubmit: (input: RuleDialogSubmit) => Promise<void>;
  onSearch?: (search: string) => void;
}) {
  const [itemId, setItemId] = useState(state.mode === "edit" ? state.item.id : "");
  const [search, setSearch] = useState("");
  const [minimum, setMinimum] = useState(
    state.mode === "edit" ? formatQuantity(state.minimum) : "",
  );
  const [target, setTarget] = useState(state.mode === "edit" ? formatQuantity(state.target) : "");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    if (state.mode === "create") onSearch?.(search);
  }, [search, state.mode, onSearch]);

  const item =
    state.mode === "edit" ? state.item : state.items.find((candidate) => candidate.id === itemId);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (saving) return;
    if (!item) {
      setError("Choose an item.");
      return;
    }
    const problem = validateRuleInput(minimum, target);
    if (problem) {
      setError(problem);
      return;
    }
    setSaving(true);
    setError("");
    try {
      await onSubmit({
        inventoryItemId: item.id,
        minimumQuantity: Number(minimum),
        targetQuantity: Number(target),
        expectedUpdatedAt: state.mode === "edit" ? state.updatedAt : null,
      });
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not save the rule.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={submit} className="space-y-4" aria-label="Minimum and Target">
      {state.mode === "create" && (
        <div className="space-y-2">
          <Label htmlFor="rule-item-search">Item</Label>
          <Input
            id="rule-item-search"
            placeholder="Search active items"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
          <select
            aria-label="Item"
            className="h-10 w-full rounded-md border bg-background px-3 text-sm"
            value={itemId}
            onChange={(event) => setItemId(event.target.value)}
          >
            <option value="">Choose an item</option>
            {state.items.map((candidate) => (
              <option key={candidate.id} value={candidate.id}>
                {candidate.name} ({candidate.unit})
              </option>
            ))}
          </select>
          <p className="text-xs text-muted-foreground">The item does not need stock here yet.</p>
        </div>
      )}
      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <Label htmlFor="rule-minimum">Minimum{item ? ` (${item.unit})` : ""}</Label>
          <Input
            id="rule-minimum"
            inputMode="decimal"
            value={minimum}
            onChange={(event) => setMinimum(event.target.value)}
          />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="rule-target">Target{item ? ` (${item.unit})` : ""}</Label>
          <Input
            id="rule-target"
            inputMode="decimal"
            value={target}
            onChange={(event) => setTarget(event.target.value)}
          />
        </div>
      </div>
      <p className="text-xs text-muted-foreground">
        Minimum can be 0. Target must be greater than 0 and at least the Minimum.
      </p>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      <DialogFooter>
        <Button type="submit" disabled={saving}>
          {saving ? "Saving…" : "Save"}
        </Button>
      </DialogFooter>
    </form>
  );
}

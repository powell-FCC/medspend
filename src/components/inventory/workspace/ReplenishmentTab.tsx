import { useState } from "react";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { ChevronDown, ChevronRight } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import {
  getReplenishmentSummaryFn,
  listReplenishmentFn,
} from "@/lib/inventory-replenishment.functions";
import { coverageText, replenishmentQueryKey } from "@/inventory/replenishment";
import type {
  ReplenishmentCursor,
  ReplenishmentRow,
  ReplenishmentSummary,
  ReplenishmentView,
  RuleDialogState,
} from "@/types/inventory-replenishment";
import { ItemStockDialogs, type ItemStockAction } from "./ItemStockDialogs";
import { ReadOnlyBadge } from "./ReadOnlyBadge";
import { ReplenishmentRowCard, type ReplenishmentRowActions } from "./ReplenishmentRowCard";
import { ReplenishmentRuleDialog } from "./ReplenishmentRuleDialog";
import { editState, useReplenishmentRuleActions } from "./useReplenishmentRuleActions";

// Phase 7D Replenishment. Computed live from current balances and rules. Owners can open a
// prefilled Move Stock (they still confirm it) and manage rules; admins read. Nothing here
// creates a request or a purchase: needing purchasing is information only.
export function ReplenishmentTab({
  organizationId,
  canManage,
}: {
  organizationId: string;
  canManage: boolean;
}) {
  const [okOpen, setOkOpen] = useState(false);
  const [inactiveOpen, setInactiveOpen] = useState(false);
  const [stockAction, setStockAction] = useState<ItemStockAction>();
  const [dialog, setDialog] = useState<RuleDialogState>();
  const [error, setError] = useState("");
  const summaryFn = useServerFn(getReplenishmentSummaryFn);
  const summary = useQuery({
    queryKey: [...replenishmentQueryKey(organizationId), "summary"],
    queryFn: () => summaryFn({ data: { organizationId } }),
  });
  const attention = useReplenishmentList(organizationId, "attention", true);
  const ok = useReplenishmentList(organizationId, "ok", okOpen);
  const inactive = useReplenishmentList(organizationId, "inactive", inactiveOpen);
  const actions = useReplenishmentRuleActions(organizationId);

  if (summary.isLoading)
    return <p className="py-8 text-center text-sm text-muted-foreground">Loading replenishment…</p>;
  if (summary.isError || !summary.data)
    return (
      <Alert variant="destructive">
        <AlertTitle>Could not load replenishment</AlertTitle>
        <AlertDescription>
          {summary.error instanceof Error ? summary.error.message : "Try again."}
        </AlertDescription>
      </Alert>
    );

  const rowActions: ReplenishmentRowActions = canManage
    ? {
        onMove: (row, prefill) =>
          setStockAction({
            kind: "move",
            item: {
              id: row.inventoryItemId,
              name: row.itemName,
              unit: row.itemUnit,
              quantity: row.organizationQuantity,
            },
            prefill,
          }),
        onEdit: (row) => setDialog(editState(row)),
        onToggleEnabled: async (row) => {
          setError("");
          try {
            await actions.toggle(row);
          } catch (cause) {
            setError(cause instanceof Error ? cause.message : "Could not change the rule.");
          }
        },
      }
    : {};

  return (
    <>
      <ReplenishmentView
        summary={summary.data}
        canManage={canManage}
        attention={attention.rows}
        attentionMore={attention.more}
        ok={ok.rows}
        okMore={ok.more}
        okOpen={okOpen}
        onToggleOk={() => setOkOpen((open) => !open)}
        inactive={inactive.rows}
        inactiveMore={inactive.more}
        inactiveOpen={inactiveOpen}
        onToggleInactive={() => setInactiveOpen((open) => !open)}
        error={error}
        {...rowActions}
      />
      {canManage && (
        <>
          <ItemStockDialogs
            organizationId={organizationId}
            action={stockAction}
            onClose={() => setStockAction(undefined)}
          />
          <ReplenishmentRuleDialog
            state={dialog}
            onOpenChange={(open) => !open && setDialog(undefined)}
            onSubmit={async (input) => {
              if (!dialog) return;
              await actions.save(dialog, input);
              setDialog(undefined);
            }}
          />
        </>
      )}
    </>
  );
}

type ListState = { rows: ReplenishmentRow[]; more?: () => void };

function useReplenishmentList(
  organizationId: string,
  view: ReplenishmentView,
  enabled: boolean,
): ListState {
  const list = useServerFn(listReplenishmentFn);
  const query = useInfiniteQuery({
    queryKey: [...replenishmentQueryKey(organizationId), "list", view],
    queryFn: ({ pageParam }) =>
      list({ data: { organizationId, view, cursor: pageParam, limit: 100 } }),
    initialPageParam: null as ReplenishmentCursor | null,
    getNextPageParam: (page) => page.nextCursor,
    enabled,
  });
  return {
    rows: query.data?.pages.flatMap((page) => page.rows) ?? [],
    more:
      query.hasNextPage && !query.isFetchingNextPage ? () => void query.fetchNextPage() : undefined,
  };
}

const ATTENTION_GROUPS: { category: ReplenishmentRow["category"]; title: string }[] = [
  { category: "move_available", title: "Move available" },
  { category: "partly_covered", title: "Partly covered" },
  { category: "needs_purchasing", title: "Needs purchasing" },
];

export function ReplenishmentView({
  summary,
  canManage,
  attention,
  attentionMore,
  ok,
  okMore,
  okOpen,
  onToggleOk,
  inactive,
  inactiveMore,
  inactiveOpen,
  onToggleInactive,
  error,
  now,
  ...actions
}: {
  summary: ReplenishmentSummary;
  canManage: boolean;
  attention: ReplenishmentRow[];
  attentionMore?: () => void;
  ok: ReplenishmentRow[];
  okMore?: () => void;
  okOpen: boolean;
  onToggleOk: () => void;
  inactive: ReplenishmentRow[];
  inactiveMore?: () => void;
  inactiveOpen: boolean;
  onToggleInactive: () => void;
  error?: string;
  now?: Date;
} & ReplenishmentRowActions) {
  const attentionCount =
    summary.categories.moveAvailable +
    summary.categories.partlyCovered +
    summary.categories.needsPurchasing;
  return (
    <div className="space-y-6" data-testid="replenishment">
      <header className="space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="text-lg font-semibold">Replenishment</h2>
          {!canManage && <ReadOnlyBadge />}
        </div>
        <p className="text-sm text-muted-foreground" data-testid="replenishment-coverage">
          {coverageText(summary)}
        </p>
        <p className="text-xs text-muted-foreground">
          Each rule sets a Minimum and a Target for one item at one storage location. Moving stock
          you already have comes first; anything still short needs purchasing, which SportSpend only
          reports. Quantities are in each item&apos;s own unit, not vendor packs.
          {canManage
            ? " Set rules on a location's Stock tab."
            : " Only owners can change rules or move stock."}
        </p>
      </header>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      {summary.rules.total === 0 ? (
        <div
          className="rounded-xl border border-dashed bg-card px-6 py-12 text-center text-sm text-muted-foreground"
          data-testid="replenishment-empty"
        >
          No replenishment rules yet. Set a Minimum and Target on a storage location&apos;s Stock
          tab.
        </div>
      ) : (
        <section className="space-y-4" aria-label="Needs attention">
          <h3 className="text-base font-semibold">Needs attention ({attentionCount})</h3>
          {attentionCount === 0 && (
            <p className="text-sm text-muted-foreground">Every active rule is above its Minimum.</p>
          )}
          {ATTENTION_GROUPS.map((group) => {
            const rows = attention.filter((row) => row.category === group.category);
            if (!rows.length) return null;
            return (
              <div key={group.category} className="space-y-2" data-group={group.category}>
                <h4 className="text-sm font-medium text-muted-foreground">
                  {group.title} ({rows.length})
                </h4>
                <ul className="divide-y rounded-xl border bg-card">
                  {rows.map((row) => (
                    <ReplenishmentRowCard
                      key={row.ruleId}
                      row={row}
                      canManage={canManage}
                      now={now}
                      {...actions}
                    />
                  ))}
                </ul>
              </div>
            );
          })}
          {attentionMore && (
            <div className="text-center">
              <Button variant="outline" onClick={attentionMore}>
                Load more
              </Button>
            </div>
          )}
        </section>
      )}
      {summary.rules.total > 0 && (
        <>
          <CollapsibleGroup
            title={`OK (${summary.categories.ok})`}
            open={okOpen}
            onToggle={onToggleOk}
            rows={ok}
            more={okMore}
            canManage={canManage}
            now={now}
            actions={actions}
            testId="replenishment-ok"
          />
          <CollapsibleGroup
            title={`Inactive rules (${summary.categories.inactive})`}
            open={inactiveOpen}
            onToggle={onToggleInactive}
            rows={inactive}
            more={inactiveMore}
            canManage={canManage}
            now={now}
            actions={actions}
            testId="replenishment-inactive"
          />
        </>
      )}
    </div>
  );
}

function CollapsibleGroup({
  title,
  open,
  onToggle,
  rows,
  more,
  canManage,
  now,
  actions,
  testId,
}: {
  title: string;
  open: boolean;
  onToggle: () => void;
  rows: ReplenishmentRow[];
  more?: () => void;
  canManage: boolean;
  now?: Date;
  actions: ReplenishmentRowActions;
  testId: string;
}) {
  return (
    <section className="space-y-2" data-testid={testId} data-open={open}>
      <button
        type="button"
        className="flex items-center gap-1 text-base font-semibold"
        aria-expanded={open}
        onClick={onToggle}
      >
        {open ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
        {title}
      </button>
      {open && (
        <>
          {rows.length ? (
            <ul className="divide-y rounded-xl border bg-card">
              {rows.map((row) => (
                <ReplenishmentRowCard
                  key={row.ruleId}
                  row={row}
                  canManage={canManage}
                  now={now}
                  {...actions}
                />
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted-foreground">None.</p>
          )}
          {more && (
            <Button variant="outline" onClick={more}>
              Load more
            </Button>
          )}
        </>
      )}
    </section>
  );
}

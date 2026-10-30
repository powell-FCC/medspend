import { Link } from "@tanstack/react-router";
import { Badge } from "@/components/ui/badge";
import {
  formatActivityQuantity,
  formatAdjustmentAmount,
  transferRouteLabel,
} from "@/inventory/activity";
import { correctionCountLabel, formatCountDateTime } from "@/inventory/count-history";
import { formatQuantity } from "@/inventory/locations";
import {
  RECORDED_QUANTITY_NOTE,
  attentionSections,
  attentionTotal,
  moreRowsLabel,
  plural,
  recordedUnitsLabel,
} from "@/inventory/overview";
import type {
  AdjustmentHistoryRow,
  CountHistoryRow,
  InventoryOverview,
  OverviewSnapshot,
  TransferHistoryRow,
} from "@/types/inventory-workspace";

// Presentational Overview sections. Owners and admins see the same thing: nothing here
// changes inventory, and every row links to the workspace page that already shows it.

export function OverviewSnapshotCards({ snapshot }: { snapshot: OverviewSnapshot }) {
  return (
    <dl className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4" data-testid="overview-snapshot">
      <Stat label="Active items" value={snapshot.activeItemCount}>
        {plural(snapshot.itemsInStockCount, "item")} with stock
      </Stat>
      <Stat label="Recorded quantity" value={formatQuantity(snapshot.recordedQuantity)}>
        {recordedUnitsLabel(snapshot)}. {RECORDED_QUANTITY_NOTE}
      </Stat>
      <Stat label="Storage locations" value={snapshot.activeStorageLocationCount}>
        Active · {snapshot.archivedStorageLocationCount} archived
      </Stat>
      <Stat label="Stock in Unassigned" value={plural(snapshot.unassignedItemCount, "item")}>
        {formatQuantity(snapshot.unassignedQuantity)} recorded
      </Stat>
    </dl>
  );
}

function Stat({
  label,
  value,
  children,
}: {
  label: string;
  value: number | string;
  children: React.ReactNode;
}) {
  return (
    <div className="min-w-0 rounded-xl border bg-card p-4">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words text-2xl font-semibold tabular-nums">{value}</dd>
      <dd className="mt-1 text-xs text-muted-foreground">{children}</dd>
    </div>
  );
}

export function NeedsAttention({ overview }: { overview: InventoryOverview }) {
  const total = attentionTotal(overview);
  const unassignedId = overview.snapshot.unassignedLocationId;
  return (
    <section className="space-y-3" data-testid="overview-attention" aria-label="Needs attention">
      <div className="flex flex-wrap items-baseline gap-2">
        <h2 className="text-lg font-semibold">Needs attention</h2>
        <span className="text-sm text-muted-foreground">
          {total ? plural(total, "item") : "Nothing needs attention"}
        </span>
      </div>
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {attentionSections.map((section) => {
          const list = overview.attention[section.key];
          return (
            <div
              key={section.key}
              className="min-w-0 rounded-xl border bg-card p-4"
              data-testid={`attention-${section.key}`}
            >
              <div className="flex items-start justify-between gap-3">
                <h3 className="font-medium">{section.title}</h3>
                <Badge variant={list.total ? "secondary" : "outline"} className="tabular-nums">
                  {list.total}
                </Badge>
              </div>
              <p className="mt-1 text-xs text-muted-foreground">{section.description}</p>
              {list.total === 0 ? (
                <p className="mt-3 text-sm text-muted-foreground">None</p>
              ) : (
                <ul className="mt-3 space-y-1.5 text-sm">
                  {section.key === "unassignedStock" &&
                    overview.attention.unassignedStock.rows.map((row) => (
                      <li key={row.inventoryItemId} className="flex justify-between gap-3">
                        <span className="min-w-0 break-words">
                          {unassignedId ? (
                            <Link
                              to="/inventory/locations/$locationId"
                              params={{ locationId: unassignedId }}
                              className="hover:underline"
                            >
                              {row.name}
                            </Link>
                          ) : (
                            row.name
                          )}
                          {!row.itemActive && (
                            <span className="text-muted-foreground"> (archived)</span>
                          )}
                        </span>
                        <span className="whitespace-nowrap tabular-nums">
                          {formatActivityQuantity(row.quantity, row.unit)}
                        </span>
                      </li>
                    ))}
                  {section.key === "neverCountedLocations" &&
                    overview.attention.neverCountedLocations.rows.map((row) => (
                      <li key={row.locationId} className="flex justify-between gap-3">
                        <LocationLink id={row.locationId} name={row.name} />
                        <span className="whitespace-nowrap text-muted-foreground">
                          {plural(row.countableItemCount, "item")}
                        </span>
                      </li>
                    ))}
                  {section.key === "neverCountedItems" &&
                    overview.attention.neverCountedItems.rows.map((row) => (
                      <li key={row.inventoryItemId} className="flex justify-between gap-3">
                        <span className="min-w-0 break-words">
                          {row.name}
                          {row.sku && <span className="text-muted-foreground"> · {row.sku}</span>}
                        </span>
                        <span className="whitespace-nowrap text-muted-foreground">
                          {plural(row.locationCount, "location")}
                        </span>
                      </li>
                    ))}
                  {section.key === "noActiveLabel" &&
                    overview.attention.noActiveLabel.rows.map((row) => (
                      <li key={row.locationId}>
                        <LocationLink id={row.locationId} name={row.name} tab="labels" />
                      </li>
                    ))}
                  {section.key === "archivedWithActiveLabel" &&
                    overview.attention.archivedWithActiveLabel.rows.map((row) => (
                      <li key={row.locationId} className="flex justify-between gap-3">
                        <LocationLink id={row.locationId} name={row.name} tab="labels" />
                        <span className="whitespace-nowrap text-muted-foreground">
                          {plural(row.activeLabelCount, "active label")}
                        </span>
                      </li>
                    ))}
                  {moreRowsLabel(list.total, list.rows.length) && (
                    <li className="text-xs text-muted-foreground">
                      {moreRowsLabel(list.total, list.rows.length)}
                    </li>
                  )}
                </ul>
              )}
            </div>
          );
        })}
      </div>
    </section>
  );
}

function LocationLink({ id, name, tab }: { id: string; name: string; tab?: "labels" }) {
  return (
    <Link
      to="/inventory/locations/$locationId"
      params={{ locationId: id }}
      search={tab ? { tab } : undefined}
      className="min-w-0 break-words hover:underline"
    >
      {name}
    </Link>
  );
}

// Recent inventory activity: the newest few of each kind, linking to the full histories.
export function RecentActivityLists({
  counts,
  transfers,
  adjustments,
}: {
  counts: CountHistoryRow[] | null;
  transfers: TransferHistoryRow[] | null;
  adjustments: AdjustmentHistoryRow[] | null;
}) {
  return (
    <section
      className="space-y-3"
      data-testid="overview-recent"
      aria-label="Recent inventory activity"
    >
      <h2 className="text-lg font-semibold">Recent inventory activity</h2>
      <div className="grid gap-3 lg:grid-cols-3">
        <RecentCard
          title="Physical counts"
          rows={counts}
          empty="No physical counts yet."
          all={{ tab: "counts", label: "All counts" }}
        >
          {(row: CountHistoryRow) => (
            <li key={row.sessionId} className="space-y-0.5">
              <Link
                to="/inventory/counts/$sessionId"
                params={{ sessionId: row.sessionId }}
                className="font-medium hover:underline"
              >
                {row.locationName}
              </Link>
              <p className="text-xs text-muted-foreground">
                {formatCountDateTime(row.submittedAt)} · {row.countedByName} ·{" "}
                {correctionCountLabel(row.changedCount)}
              </p>
            </li>
          )}
        </RecentCard>
        <RecentCard
          title="Transfers"
          rows={transfers}
          empty="No transfers yet."
          all={{ tab: "activity", label: "All activity" }}
        >
          {(row: TransferHistoryRow) => (
            <li key={row.transferId} className="space-y-0.5">
              <p className="flex justify-between gap-3">
                <span className="min-w-0 break-words font-medium">{row.itemName}</span>
                <span className="whitespace-nowrap tabular-nums">
                  {formatActivityQuantity(row.quantity, row.itemUnit)}
                </span>
              </p>
              <p className="break-words text-xs text-muted-foreground">
                {transferRouteLabel(row)} · {formatCountDateTime(row.createdAt)} ·{" "}
                {row.createdByName}
              </p>
            </li>
          )}
        </RecentCard>
        <RecentCard
          title="Manual adjustments"
          rows={adjustments}
          empty="No manual adjustments yet."
          all={{ tab: "activity", label: "All activity" }}
        >
          {(row: AdjustmentHistoryRow) => (
            <li key={row.adjustmentId} className="space-y-0.5">
              <p className="flex justify-between gap-3">
                <span className="min-w-0 break-words font-medium">{row.itemName}</span>
                <span className="whitespace-nowrap tabular-nums">
                  {formatAdjustmentAmount(row.adjustmentAmount)} {row.itemUnit}
                </span>
              </p>
              <p className="break-words text-xs text-muted-foreground">
                {row.reason} · {formatCountDateTime(row.createdAt)} · {row.createdByName}
              </p>
            </li>
          )}
        </RecentCard>
      </div>
    </section>
  );
}

function RecentCard<T>({
  title,
  rows,
  empty,
  all,
  children,
}: {
  title: string;
  rows: T[] | null;
  empty: string;
  all: { tab: "counts" | "activity"; label: string };
  children: (row: T) => React.ReactNode;
}) {
  return (
    <div className="min-w-0 rounded-xl border bg-card p-4">
      <div className="flex items-baseline justify-between gap-3">
        <h3 className="font-medium">{title}</h3>
        <Link
          to="/inventory"
          search={{ tab: all.tab }}
          className="text-xs text-primary hover:underline"
        >
          {all.label}
        </Link>
      </div>
      {rows === null ? (
        <p className="mt-3 text-sm text-muted-foreground">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="mt-3 text-sm text-muted-foreground">{empty}</p>
      ) : (
        <ul className="mt-3 space-y-3 text-sm">{rows.map(children)}</ul>
      )}
    </div>
  );
}

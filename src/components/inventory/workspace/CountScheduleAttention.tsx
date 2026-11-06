import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { Badge } from "@/components/ui/badge";
import { getCountFreshnessFn } from "@/lib/inventory-workspace.functions";
import {
  cadenceLabel,
  formatCadenceDate,
  freshnessStateLabel,
  freshnessStateTone,
} from "@/inventory/count-cadence";
import { workspaceQueryKey } from "@/inventory/workspace";
import type { CountFreshness } from "@/types/inventory-workspace";

// Phase 7B.5 on the Overview: which counted locations are due or overdue under the
// organization's count cadence. Only shown while cadence is on. Locations never counted stay
// in Needs attention above, so no location appears twice.
export function CountScheduleAttention({ organizationId }: { organizationId: string }) {
  const getFreshness = useServerFn(getCountFreshnessFn);
  const freshness = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "count-freshness"],
    queryFn: () => getFreshness({ data: { organizationId } }),
  });
  if (!freshness.data) return null;
  return <CountScheduleSection freshness={freshness.data} />;
}

export function CountScheduleSection({ freshness }: { freshness: CountFreshness }) {
  if (!freshness.policy.enabled) return null;
  const { summary, attention } = freshness;
  return (
    <section
      className="space-y-3"
      data-testid="overview-count-schedule"
      aria-label="Count schedule"
    >
      <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <h2 className="text-lg font-semibold">Count schedule</h2>
        <span className="text-sm text-muted-foreground">{cadenceLabel(freshness.policy)}</span>
      </div>
      <div className="min-w-0 rounded-xl border bg-card p-4">
        <dl className="flex flex-wrap gap-x-6 gap-y-2 text-sm" data-testid="count-schedule-summary">
          {(
            [
              ["overdue", summary.overdue],
              ["due", summary.due],
              ["current", summary.current],
            ] as const
          ).map(([state, count]) => (
            <div key={state} className="flex items-center gap-2">
              <dt>
                <Badge className={freshnessStateTone[state]}>{freshnessStateLabel[state]}</Badge>
              </dt>
              <dd className="font-medium tabular-nums">{count}</dd>
            </div>
          ))}
        </dl>
        {attention.total === 0 ? (
          <p className="mt-3 text-sm text-muted-foreground" data-testid="count-schedule-clear">
            No counted location is due.
            {freshness.nextDue &&
              ` Next count due ${formatCadenceDate(freshness.nextDue.nextDueAt)} at ${freshness.nextDue.name}.`}
          </p>
        ) : (
          <ul className="mt-3 divide-y text-sm" data-testid="count-schedule-rows">
            {attention.rows.map((row) => (
              <li
                key={row.locationId}
                className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 py-2"
              >
                <span className="flex min-w-0 flex-wrap items-center gap-2">
                  <Badge className={freshnessStateTone[row.state]}>
                    {freshnessStateLabel[row.state]}
                  </Badge>
                  <Link
                    to="/inventory/locations/$locationId"
                    params={{ locationId: row.locationId }}
                    className="break-words font-medium hover:underline"
                  >
                    {row.name}
                  </Link>
                </span>
                <span className="text-xs text-muted-foreground">
                  Due {formatCadenceDate(row.nextDueAt)} · Last counted{" "}
                  {formatCadenceDate(row.lastCountedAt)}
                </span>
              </li>
            ))}
            {attention.total > attention.rows.length && (
              <li className="py-2 text-xs text-muted-foreground">
                and {attention.total - attention.rows.length} more
              </li>
            )}
          </ul>
        )}
        {summary.neverCounted > 0 && (
          <p className="mt-3 text-xs text-muted-foreground">
            {summary.neverCounted} location{summary.neverCounted === 1 ? " has" : "s have"} never
            been counted (listed under Needs attention).
          </p>
        )}
      </div>
    </section>
  );
}

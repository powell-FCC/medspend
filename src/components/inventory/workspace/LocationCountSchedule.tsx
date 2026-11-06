import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Badge } from "@/components/ui/badge";
import { getCountFreshnessFn } from "@/lib/inventory-workspace.functions";
import {
  cadenceLabel,
  formatCadenceDate,
  freshnessStateLabel,
  freshnessStateTone,
  locationScheduleLine,
} from "@/inventory/count-cadence";
import { workspaceQueryKey } from "@/inventory/workspace";
import type { CountFreshness } from "@/types/inventory-workspace";

// Phase 7B.5 on a storage location: its count schedule under the organization's cadence.
// Rendered for active storage locations only; Unassigned is never scheduled, and nothing is
// shown while cadence is off (the header already says when it was last counted).
export function LocationCountSchedule({
  organizationId,
  locationId,
}: {
  organizationId: string;
  locationId: string;
}) {
  const getFreshness = useServerFn(getCountFreshnessFn);
  const freshness = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "count-freshness", locationId],
    queryFn: () => getFreshness({ data: { organizationId, locationId, limit: 1 } }),
  });
  if (!freshness.data) return null;
  return <LocationCountScheduleView freshness={freshness.data} />;
}

export function LocationCountScheduleView({ freshness }: { freshness: CountFreshness }) {
  const location = freshness.location;
  if (!freshness.policy.enabled || !location) return null;
  const line = locationScheduleLine(location);
  if (!line) return null;
  return (
    <div
      className="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 rounded-xl border bg-card px-4 py-3 text-sm"
      data-testid="location-count-schedule"
    >
      <Badge className={freshnessStateTone[location.state]}>
        {freshnessStateLabel[location.state]}
      </Badge>
      <span className="font-medium">{line}</span>
      <span className="text-muted-foreground">
        Count cadence: {cadenceLabel(freshness.policy).toLowerCase()}
        {location.lastCountedAt
          ? ` · Last counted ${formatCadenceDate(location.lastCountedAt)}`
          : ""}
      </span>
    </div>
  );
}

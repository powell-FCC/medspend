import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { useActiveOrg } from "@/hooks/use-active-org";
import { countErrorKind } from "@/inventory/count";
import { getCountLocationFn, submitCountFn } from "@/lib/inventory-count.functions";
import { InventoryCountForm } from "@/components/count/InventoryCountForm";
import { CountUnavailable } from "@/components/count/CountUnavailable";
import { StaffErrorState, StaffListSkeleton } from "@/components/staff/StaffStates";

// Loads one location's count page for the active organization and runs the form. Reloading
// after a stale rejection fetches fresh quantities and versions and starts a new form.
export function CountLocationView({
  organizationId,
  locationId,
}: {
  organizationId: string;
  locationId: string;
}) {
  const navigate = useNavigate();
  const { active } = useActiveOrg();
  const getPage = useServerFn(getCountLocationFn);
  const submit = useServerFn(submitCountFn);
  const query = useQuery({
    queryKey: ["count-location", organizationId, locationId],
    queryFn: () => getPage({ data: { organizationId, locationId } }),
    staleTime: 0,
    gcTime: 0,
    refetchOnWindowFocus: false,
    retry: false,
  });
  const isStaff = active?.role === "staff";
  const home = isStaff ? "/staff" : "/dashboard";

  if (query.isLoading) return <StaffListSkeleton label="Loading this location's items" rows={4} />;
  if (query.error) {
    const message =
      query.error instanceof Error ? query.error.message : "Could not load this location.";
    if (countErrorKind(message) === "unavailable" || countErrorKind(message) === "forbidden") {
      return (
        <CountUnavailable
          message="This inventory location isn't available for counting."
          onBack={() => navigate({ to: home })}
        />
      );
    }
    return <StaffErrorState message={message} onRetry={() => void query.refetch()} />;
  }
  if (!query.data) return null;

  return (
    <InventoryCountForm
      key={query.dataUpdatedAt}
      page={query.data}
      onSubmit={(lines, requestKey) =>
        submit({ data: { organizationId, locationId, lines, requestKey } })
      }
      onReload={() => void query.refetch()}
      onDone={() => navigate({ to: "/count" })}
      onBack={() => navigate({ to: home })}
      backLabel={isStaff ? "Back to Staff Workspace" : "Back to dashboard"}
    />
  );
}

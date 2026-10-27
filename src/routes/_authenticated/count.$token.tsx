import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useEffect } from "react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { availableLabel, labelUnavailableMessage } from "@/inventory/count";
import { resolveCountLabelFn } from "@/lib/inventory-count.functions";
import { CountLocationView } from "@/components/count/CountLocationView";
import { CountUnavailable } from "@/components/count/CountUnavailable";
import { StaffListSkeleton } from "@/components/staff/StaffStates";

export const Route = createFileRoute("/_authenticated/count/$token")({
  head: () => ({
    meta: [{ title: "Inventory count — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: CountLabel,
});

// A scanned QR label. The server resolves the token only for active members of its
// organization; this page then makes that organization active (the person is a member of
// it) and opens the count. Everyone else sees the same generic message.
function CountLabel() {
  const { token } = Route.useParams();
  const navigate = useNavigate();
  const { active, memberships, setActiveOrgId } = useActiveOrg();
  const resolve = useServerFn(resolveCountLabelFn);
  const resolution = useQuery({
    queryKey: ["count-label", token],
    queryFn: () => resolve({ data: { token } }),
    staleTime: 0,
    gcTime: 0,
    retry: false,
  });
  const resolved = availableLabel(resolution.data);
  const member = resolved && memberships.some((m) => m.organizationId === resolved.organizationId);

  useEffect(() => {
    if (resolved && member && active?.organizationId !== resolved.organizationId) {
      setActiveOrgId(resolved.organizationId);
    }
  }, [resolved, member, active?.organizationId, setActiveOrgId]);

  const back = () =>
    navigate({ to: active?.role === "staff" || !active ? "/staff" : "/dashboard" });

  if (resolution.isLoading)
    return <StaffListSkeleton label="Opening this inventory location" rows={3} />;
  if (resolution.error) {
    return (
      <CountUnavailable
        message="We couldn't open this label. Check your connection and scan it again."
        onBack={back}
      />
    );
  }
  if (!resolution.data) return null;
  if (resolution.data.status !== "available" || !member) {
    const status = resolution.data.status === "available" ? "unavailable" : resolution.data.status;
    return <CountUnavailable message={labelUnavailableMessage(status)} onBack={back} />;
  }
  if (!resolved || active?.organizationId !== resolved.organizationId) {
    return <StaffListSkeleton label="Opening this inventory location" rows={3} />;
  }
  return (
    <CountLocationView organizationId={resolved.organizationId} locationId={resolved.locationId} />
  );
}

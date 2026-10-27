import { createFileRoute } from "@tanstack/react-router";
import { useActiveOrg } from "@/hooks/use-active-org";
import { CountLocationView } from "@/components/count/CountLocationView";

export const Route = createFileRoute("/_authenticated/count/location/$locationId")({
  head: () => ({
    meta: [{ title: "Inventory count — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: CountChosenLocation,
});

// A location chosen from the list on /count, in the active organization.
function CountChosenLocation() {
  const { locationId } = Route.useParams();
  const { active } = useActiveOrg();
  if (!active) return null;
  return <CountLocationView organizationId={active.organizationId} locationId={locationId} />;
}

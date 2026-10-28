import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { z } from "zod";
import { LocationDetailPage } from "@/components/inventory/workspace/LocationDetailPage";

const locationSearchSchema = z.object({
  tab: z.enum(["stock", "labels"]).catch("stock").default("stock"),
});

export const Route = createFileRoute("/_authenticated/inventory/locations/$locationId")({
  head: () => ({
    meta: [{ title: "Inventory location — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  validateSearch: locationSearchSchema,
  component: LocationRoute,
});

function LocationRoute() {
  const { locationId } = Route.useParams();
  const { tab } = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });
  return (
    <LocationDetailPage
      key={locationId}
      locationId={locationId}
      tab={tab}
      onTabChange={(next) => navigate({ search: { tab: next } })}
    />
  );
}

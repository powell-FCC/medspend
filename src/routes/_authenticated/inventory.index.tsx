import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { z } from "zod";
import { InventoryWorkspacePage } from "@/components/inventory/workspace/InventoryWorkspacePage";

// Tabs live in the query string so they can be linked. Overview and Activity join later.
const inventorySearchSchema = z.object({
  tab: z.enum(["items", "locations"]).catch("items").default("items"),
});

export const Route = createFileRoute("/_authenticated/inventory/")({
  validateSearch: inventorySearchSchema,
  component: InventoryRoute,
});

function InventoryRoute() {
  const { tab } = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });
  return (
    <InventoryWorkspacePage tab={tab} onTabChange={(next) => navigate({ search: { tab: next } })} />
  );
}

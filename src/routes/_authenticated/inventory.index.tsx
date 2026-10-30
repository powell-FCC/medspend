import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { z } from "zod";
import { InventoryWorkspacePage } from "@/components/inventory/workspace/InventoryWorkspacePage";

// Tabs live in the query string so they can be linked. /inventory opens on Overview; older
// links that name a tab keep working, and an unknown tab falls back to Overview.
const inventorySearchSchema = z.object({
  tab: z
    .enum(["overview", "items", "locations", "counts", "activity"])
    .catch("overview")
    .default("overview"),
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

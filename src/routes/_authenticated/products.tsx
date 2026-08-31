import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { z } from "zod";
import { CatalogAdminPage } from "@/components/catalog/CatalogAdminPage";

const catalogSearchSchema = z.object({
  q: z.string().default(""),
  vendorId: z.string().uuid().nullable().default(null),
  lifecycle: z.enum(["active", "discontinued", "all"]).default("active"),
  packageStatus: z.enum(["verified", "source_only", "unknown", "all"]).default("all"),
  adoption: z.enum(["adopted", "not_adopted", "all"]).default("all"),
  page: z.coerce.number().int().min(1).max(400).default(1),
});

export const Route = createFileRoute("/_authenticated/products")({
  head: () => ({ meta: [{ title: "Catalog — MedSpend" }, { name: "robots", content: "noindex" }] }),
  validateSearch: catalogSearchSchema,
  component: ProductsPage,
});

function ProductsPage() {
  const search = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });

  return (
    <CatalogAdminPage
      search={search}
      onSearchChange={(patch) =>
        navigate({
          search: (current) => ({ ...current, ...patch }),
        })
      }
    />
  );
}

import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { z } from "zod";
import { CatalogVendorManagementPage } from "@/components/catalog/CatalogVendorManagementPage";

const catalogVendorSearchSchema = z.object({
  vendorId: z.string().uuid().nullable().default(null).catch(null),
  coverage: z.enum(["not_cataloged", "all"]).default("not_cataloged").catch("not_cataloged"),
});

export const Route = createFileRoute("/_authenticated/catalog-vendors")({
  head: () => ({
    meta: [{ title: "Catalog vendors — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  validateSearch: catalogVendorSearchSchema,
  component: CatalogVendorsPage,
});

function CatalogVendorsPage() {
  const search = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });

  return (
    <CatalogVendorManagementPage
      search={search}
      onSearchChange={(patch) =>
        navigate({
          search: (current) => ({ ...current, ...patch }),
        })
      }
    />
  );
}

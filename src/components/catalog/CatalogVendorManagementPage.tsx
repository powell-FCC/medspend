import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { useEffect, useState } from "react";
import {
  CatalogCoverageSection,
  CoverageReviewSheet,
  LinkCatalogVendorDialog,
  VendorLinkTable,
} from "@/components/catalog/CatalogVendorSections";
import { useActiveOrg } from "@/hooks/use-active-org";
import {
  getVendorCatalogCoverageFn,
  linkOrganizationVendorFn,
  listOrganizationVendorLinksFn,
  searchLinkableCatalogVendorsFn,
} from "@/lib/catalog-vendor-management.functions";
import { isCatalogAdminRole } from "@/catalog-admin/catalog-admin";
import type {
  CatalogCoverageRow,
  CoverageFilter,
  LinkableCatalogVendor,
  OrganizationVendorLink,
} from "@/catalog-admin/vendor-management";

export type CatalogVendorSearchParams = {
  vendorId: string | null;
  coverage: CoverageFilter;
};

const errorText = (error: unknown, fallback: string) =>
  error instanceof Error ? error.message : fallback;

export function CatalogVendorManagementPage({
  search,
  onSearchChange,
}: {
  search: CatalogVendorSearchParams;
  onSearchChange: (patch: Partial<CatalogVendorSearchParams>) => void;
}) {
  const { active } = useActiveOrg();
  const queryClient = useQueryClient();
  const listFn = useServerFn(listOrganizationVendorLinksFn);
  const catalogVendorsFn = useServerFn(searchLinkableCatalogVendorsFn);
  const linkFn = useServerFn(linkOrganizationVendorFn);
  const coverageFn = useServerFn(getVendorCatalogCoverageFn);
  const [linkingVendor, setLinkingVendor] = useState<OrganizationVendorLink | null>(null);
  const [catalogQuery, setCatalogQuery] = useState("");
  const [debouncedCatalogQuery, setDebouncedCatalogQuery] = useState("");
  const [linkError, setLinkError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [reviewRow, setReviewRow] = useState<CatalogCoverageRow | null>(null);

  const organizationId = active?.organizationId;
  const allowed = Boolean(organizationId && isCatalogAdminRole(active?.role));

  useEffect(() => {
    setLinkingVendor(null);
    setReviewRow(null);
    setNotice(null);
  }, [organizationId]);
  useEffect(() => {
    const timer = setTimeout(() => setDebouncedCatalogQuery(catalogQuery), 250);
    return () => clearTimeout(timer);
  }, [catalogQuery]);

  const vendorsQuery = useQuery({
    queryKey: ["catalog-vendors", organizationId, "links"],
    queryFn: () => listFn({ data: { organizationId: organizationId! } }),
    enabled: allowed,
  });
  const catalogVendorsQuery = useQuery({
    queryKey: ["catalog-vendors", organizationId, "linkable", debouncedCatalogQuery],
    queryFn: () =>
      catalogVendorsFn({ data: { organizationId: organizationId!, q: debouncedCatalogQuery } }),
    enabled: allowed && Boolean(linkingVendor),
    placeholderData: (previous) => previous,
  });

  const vendors = vendorsQuery.data ?? [];
  const selectedVendor =
    vendors.find((vendor) => vendor.vendorId === search.vendorId && vendor.catalogVendorId) ?? null;

  const coverageQuery = useQuery({
    queryKey: ["catalog-vendors", organizationId, "coverage", selectedVendor?.vendorId],
    queryFn: () =>
      coverageFn({ data: { organizationId: organizationId!, vendorId: selectedVendor!.vendorId } }),
    enabled: allowed && Boolean(selectedVendor),
  });

  const link = useMutation({
    mutationFn: ({
      vendor,
      catalogVendor,
    }: {
      vendor: OrganizationVendorLink;
      catalogVendor: LinkableCatalogVendor;
    }) =>
      linkFn({
        data: {
          organizationId: organizationId!,
          vendorId: vendor.vendorId,
          catalogVendorId: catalogVendor.id,
          expectedUpdatedAt: vendor.updatedAt,
        },
      }),
    onMutate: () => setLinkError(null),
    onSuccess: async (result, { vendor }) => {
      setLinkingVendor(null);
      setNotice(
        result.alreadyLinked
          ? `${vendor.vendorName} was already linked to ${result.catalogVendorName}.`
          : `${vendor.vendorName} is now linked to ${result.catalogVendorName}.`,
      );
      onSearchChange({ vendorId: vendor.vendorId });
      await queryClient.invalidateQueries({ queryKey: ["catalog-vendors", organizationId] });
      await queryClient.invalidateQueries({ queryKey: ["catalog-admin", organizationId] });
    },
    onError: async (error) => {
      setLinkError(errorText(error, "Unable to link this vendor to the catalog."));
      // A stale or conflicting link means the list is out of date.
      await queryClient.invalidateQueries({
        queryKey: ["catalog-vendors", organizationId, "links"],
      });
    },
  });

  if (!active || !isCatalogAdminRole(active.role)) return null;

  return (
    <div className="min-h-full bg-muted/20" data-page="catalog-vendors">
      <div className="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
        <header className="mb-6">
          <p className="text-xs font-semibold uppercase tracking-[0.18em] text-primary">
            Global catalog
          </p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">
            Catalog vendors
          </h1>
          <p className="mt-2 max-w-2xl text-sm text-muted-foreground">
            Link {active.organizationName}'s vendors to global catalog vendors and see which of your
            saved vendor SKUs the catalog already lists. Your SKU mappings stay private to your
            organization.{" "}
            <Link to="/products" className="text-primary hover:underline">
              Search the catalog
            </Link>
          </p>
        </header>

        {notice && (
          <div
            className="mb-4 rounded-lg border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-900"
            role="status"
          >
            {notice}
          </div>
        )}

        <section aria-labelledby="vendor-links-heading">
          <h2 id="vendor-links-heading" className="mb-3 text-base font-semibold">
            Vendors
          </h2>
          {vendorsQuery.isLoading ? (
            <div className="rounded-xl border bg-card p-6 text-sm text-muted-foreground">
              Loading vendors…
            </div>
          ) : vendorsQuery.error ? (
            <div
              className="rounded-xl border border-destructive/40 bg-destructive/5 p-4 text-sm text-destructive"
              role="alert"
            >
              {errorText(vendorsQuery.error, "Unable to load organization vendors.")}
            </div>
          ) : (
            <VendorLinkTable
              vendors={vendors}
              selectedVendorId={selectedVendor?.vendorId ?? null}
              onLink={(vendor) => {
                setNotice(null);
                setLinkError(null);
                setCatalogQuery("");
                setLinkingVendor(vendor);
              }}
              onSelectCoverage={(vendor) => {
                setReviewRow(null);
                onSearchChange({ vendorId: vendor.vendorId });
              }}
            />
          )}
        </section>

        <section className="mt-8" aria-labelledby="catalog-coverage-heading">
          <h2 id="catalog-coverage-heading" className="mb-3 text-base font-semibold">
            Catalog coverage
          </h2>
          <CatalogCoverageSection
            vendorName={selectedVendor?.vendorName ?? null}
            coverage={coverageQuery.data}
            loading={coverageQuery.isLoading}
            error={
              coverageQuery.error
                ? errorText(coverageQuery.error, "Unable to load catalog coverage.")
                : null
            }
            filter={search.coverage}
            onFilterChange={(coverage) => onSearchChange({ coverage })}
            onReview={setReviewRow}
          />
        </section>
      </div>

      <LinkCatalogVendorDialog
        vendor={linkingVendor}
        catalogVendors={catalogVendorsQuery.data ?? []}
        catalogVendorsLoading={catalogVendorsQuery.isLoading}
        catalogVendorsError={
          catalogVendorsQuery.error
            ? errorText(catalogVendorsQuery.error, "Unable to search catalog vendors.")
            : null
        }
        query={catalogQuery}
        onQueryChange={setCatalogQuery}
        linking={link.isPending}
        linkError={linkError}
        onConfirm={(catalogVendor) => {
          if (linkingVendor) link.mutate({ vendor: linkingVendor, catalogVendor });
        }}
        onOpenChange={(open) => {
          if (!open && !link.isPending) setLinkingVendor(null);
        }}
      />
      <CoverageReviewSheet
        row={reviewRow}
        organizationVendorName={selectedVendor?.vendorName ?? ""}
        catalogVendorName={coverageQuery.data?.catalogVendor?.name ?? "Linked"}
        onOpenChange={(open) => {
          if (!open) setReviewRow(null);
        }}
      />
    </div>
  );
}

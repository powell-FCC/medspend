import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { ChevronLeft, ChevronRight, ExternalLink, Loader2, Search } from "lucide-react";
import { useEffect, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  CatalogStockDialog,
  type CatalogStockSubmission,
} from "@/components/catalog/CatalogStockDialog";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { useActiveOrg } from "@/hooks/use-active-org";
import {
  adoptCatalogVendorProductFn,
  getCatalogAdminDetailFn,
  listCatalogAdminVendorsFn,
  searchCatalogAdminFn,
  stockCatalogVendorProductFn,
} from "@/lib/catalog.functions";
import {
  canStockCatalogResult,
  catalogPackagePresentation,
  isCatalogAdminRole,
  type CatalogAdminDetail,
  type CatalogAdminResult,
} from "@/catalog-admin/catalog-admin";

export type CatalogAdminSearchParams = {
  q: string;
  vendorId: string | null;
  lifecycle: "active" | "discontinued" | "all";
  packageStatus: "verified" | "source_only" | "unknown" | "all";
  adoption: "adopted" | "not_adopted" | "all";
  page: number;
};

type SearchPatch = Partial<CatalogAdminSearchParams>;

export function CatalogAdminPage({
  search,
  onSearchChange,
}: {
  search: CatalogAdminSearchParams;
  onSearchChange: (patch: SearchPatch) => void;
}) {
  const { active } = useActiveOrg();
  const queryClient = useQueryClient();
  const searchFn = useServerFn(searchCatalogAdminFn);
  const vendorsFn = useServerFn(listCatalogAdminVendorsFn);
  const adoptFn = useServerFn(adoptCatalogVendorProductFn);
  const stockFn = useServerFn(stockCatalogVendorProductFn);
  const [draftQuery, setDraftQuery] = useState(search.q);
  const [selected, setSelected] = useState<CatalogAdminResult | null>(null);
  const [notice, setNotice] = useState<{ tone: "success" | "error"; message: string } | null>(null);
  const [adoptingId, setAdoptingId] = useState<string | null>(null);
  const [stockingRow, setStockingRow] = useState<CatalogAdminResult | null>(null);

  useEffect(() => setDraftQuery(search.q), [search.q]);
  useEffect(() => {
    setSelected(null);
    setStockingRow(null);
  }, [active?.organizationId]);

  const organizationId = active?.organizationId;
  const queryKey = ["catalog-admin", organizationId, search] as const;
  const vendorsQuery = useQuery({
    queryKey: ["catalog-admin", organizationId, "vendors"],
    queryFn: () => vendorsFn({ data: { organizationId: organizationId! } }),
    enabled: Boolean(organizationId && isCatalogAdminRole(active?.role)),
    staleTime: 5 * 60_000,
  });
  const catalogQuery = useQuery({
    queryKey,
    queryFn: () => searchFn({ data: { organizationId: organizationId!, ...search } }),
    enabled: Boolean(organizationId && isCatalogAdminRole(active?.role)),
    placeholderData: (previous) => previous,
  });
  const adoption = useMutation({
    mutationFn: (catalogVendorProductId: string) =>
      adoptFn({ data: { organizationId: organizationId!, catalogVendorProductId } }),
    onMutate: (catalogVendorProductId) => {
      setAdoptingId(catalogVendorProductId);
      setNotice(null);
    },
    onSuccess: async (result) => {
      setNotice({
        tone: "success",
        message: result.alreadyAdopted
          ? "This item is already in the organization catalog."
          : "Added to the organization catalog.",
      });
      await queryClient.invalidateQueries({ queryKey: ["catalog-admin", organizationId] });
    },
    onError: (error) => {
      setNotice({
        tone: "error",
        message: error instanceof Error ? error.message : "Unable to add this item.",
      });
    },
    onSettled: () => setAdoptingId(null),
  });
  const stocking = useMutation({
    mutationFn: (input: CatalogStockSubmission) =>
      stockFn({ data: { organizationId: organizationId!, ...input } }),
    onMutate: () => setNotice(null),
    onSuccess: async (result) => {
      setNotice({
        tone: "success",
        message: result.alreadyStocked
          ? "This catalog item is already in inventory."
          : "Added to inventory with an initial quantity of zero.",
      });
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["catalog-admin", organizationId] }),
        queryClient.invalidateQueries({ queryKey: ["inventory", organizationId] }),
      ]);
    },
  });

  function updateSearch(patch: SearchPatch) {
    setNotice(null);
    onSearchChange({ ...patch, ...(patch.q === undefined ? {} : { page: 1 }) });
  }

  function submitSearch(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    updateSearch({ q: draftQuery.trim(), page: 1 });
  }

  function runAdoption(row: CatalogAdminResult) {
    if (row.adoptionState !== "not_adopted" || adoptingId) return;
    adoption.mutate(row.catalogVendorProductId);
  }

  if (!active || !isCatalogAdminRole(active.role)) return null;

  return (
    <div className="min-h-full bg-muted/20" data-page="catalog-admin">
      <div className="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
        <header className="mb-6">
          <p className="text-xs font-semibold uppercase tracking-[0.18em] text-primary">
            Global catalog
          </p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">
            Catalog administration
          </h1>
          <p className="mt-2 max-w-2xl text-sm text-muted-foreground">
            Find a verified global identity, review its source trail, adopt it for{" "}
            {active.organizationName}, and add adopted products to inventory when needed.
          </p>
        </header>

        <form
          onSubmit={submitSearch}
          className="rounded-xl border bg-card p-3 shadow-sm sm:p-4"
          role="search"
        >
          <label htmlFor="catalog-search" className="sr-only">
            Search the global catalog
          </label>
          <div className="flex flex-col gap-3 sm:flex-row">
            <div className="relative min-w-0 flex-1">
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
              <input
                id="catalog-search"
                className="h-11 w-full rounded-md border border-input bg-background pl-10 pr-3 text-sm outline-none transition focus:ring-2 focus:ring-ring"
                placeholder="Search product, SKU, manufacturer, or description"
                value={draftQuery}
                onChange={(event) => setDraftQuery(event.target.value)}
              />
            </div>
            <Button type="submit" size="lg" className="min-h-11">
              Search catalog
            </Button>
          </div>
          <div
            className="mt-3 grid gap-2 sm:grid-cols-2 2xl:grid-cols-4"
            data-section="catalog-filters"
          >
            <FilterSelect
              label="Vendor"
              value={search.vendorId ?? "all"}
              onChange={(value) =>
                updateSearch({ vendorId: value === "all" ? null : value, page: 1 })
              }
            >
              <option value="all">All vendors</option>
              {(vendorsQuery.data ?? []).map((vendor: { id: string; name: string }) => (
                <option key={vendor.id} value={vendor.id}>
                  {vendor.name}
                </option>
              ))}
            </FilterSelect>
            <FilterSelect
              label="Lifecycle"
              value={search.lifecycle}
              onChange={(value) =>
                updateSearch({ lifecycle: value as CatalogAdminSearchParams["lifecycle"], page: 1 })
              }
            >
              <option value="active">Active</option>
              <option value="discontinued">Discontinued</option>
              <option value="all">All lifecycle states</option>
            </FilterSelect>
            <FilterSelect
              label="Package status"
              value={search.packageStatus}
              onChange={(value) =>
                updateSearch({
                  packageStatus: value as CatalogAdminSearchParams["packageStatus"],
                  page: 1,
                })
              }
            >
              <option value="all">All package statuses</option>
              <option value="verified">Verified</option>
              <option value="source_only">Source only</option>
              <option value="unknown">Unknown</option>
            </FilterSelect>
            <FilterSelect
              label="Organization adoption"
              value={search.adoption}
              onChange={(value) =>
                updateSearch({ adoption: value as CatalogAdminSearchParams["adoption"], page: 1 })
              }
            >
              <option value="all">All adoption states</option>
              <option value="adopted">Adopted</option>
              <option value="not_adopted">Not adopted</option>
            </FilterSelect>
          </div>
        </form>

        {notice && (
          <div
            className={`mt-4 rounded-lg border px-4 py-3 text-sm ${notice.tone === "error" ? "border-destructive/40 bg-destructive/5 text-destructive" : "border-emerald-200 bg-emerald-50 text-emerald-900"}`}
            role="status"
          >
            {notice.message}
          </div>
        )}
        {catalogQuery.error && (
          <div
            className="mt-4 rounded-lg border border-destructive/40 bg-destructive/5 px-4 py-3 text-sm text-destructive"
            role="alert"
          >
            {catalogQuery.error instanceof Error
              ? catalogQuery.error.message
              : "Unable to load the global catalog."}
          </div>
        )}

        <div className="mt-6 flex items-center justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold">Catalog identities</h2>
            <p className="mt-1 text-xs text-muted-foreground">
              {catalogQuery.isLoading
                ? "Searching…"
                : `${catalogQuery.data?.totalCount ?? 0} result${catalogQuery.data?.totalCount === 1 ? "" : "s"}`}
              {search.q ? ` for “${search.q}”` : ""}
            </p>
          </div>
          {catalogQuery.isFetching && !catalogQuery.isLoading && (
            <Loader2
              className="h-4 w-4 animate-spin text-muted-foreground"
              aria-label="Refreshing results"
            />
          )}
        </div>

        <div className="mt-3 space-y-3" aria-live="polite">
          {catalogQuery.isLoading && <CatalogLoadingState />}
          {!catalogQuery.isLoading && !catalogQuery.data?.rows.length && (
            <EmptyState hasSearch={Boolean(search.q)} />
          )}
          {catalogQuery.data?.rows.map((row) => (
            <CatalogResultCard
              key={row.catalogVendorProductId}
              row={row}
              adopting={adoptingId === row.catalogVendorProductId}
              canOpenInventory={active.role === "owner"}
              onDetail={() => setSelected(row)}
              onAdopt={() => runAdoption(row)}
              onStock={() => setStockingRow(row)}
            />
          ))}
        </div>

        {catalogQuery.data && catalogQuery.data.totalPages > 0 && (
          <div
            className="mt-6 flex items-center justify-between rounded-lg border bg-card px-3 py-2 sm:px-4"
            aria-label="Catalog pagination"
          >
            <Button
              variant="outline"
              size="sm"
              disabled={search.page <= 1 || catalogQuery.isFetching}
              onClick={() => onSearchChange({ page: Math.max(1, search.page - 1) })}
            >
              <ChevronLeft /> <span className="hidden sm:inline">Previous</span>
            </Button>
            <span className="text-xs text-muted-foreground">
              Page {search.page} of {catalogQuery.data.totalPages}
            </span>
            <Button
              variant="outline"
              size="sm"
              disabled={search.page >= catalogQuery.data.totalPages || catalogQuery.isFetching}
              onClick={() => onSearchChange({ page: search.page + 1 })}
            >
              <span className="hidden sm:inline">Next</span> <ChevronRight />
            </Button>
          </div>
        )}
      </div>

      <CatalogDetailSheet
        organizationId={active.organizationId}
        row={selected}
        open={Boolean(selected)}
        onOpenChange={(open) => {
          if (!open) setSelected(null);
        }}
      />
      <CatalogStockDialog
        row={stockingRow}
        onOpenChange={(open) => {
          if (!open) setStockingRow(null);
        }}
        onStock={async (input) => {
          await stocking.mutateAsync(input);
        }}
      />
    </div>
  );
}

function FilterSelect({
  label,
  value,
  onChange,
  children,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  children: React.ReactNode;
}) {
  return (
    <label className="min-w-0 text-xs font-medium text-muted-foreground">
      <span className="mb-1 block">{label}</span>
      <select
        className="h-10 w-full rounded-md border border-input bg-background px-3 text-sm font-normal text-foreground outline-none focus:ring-2 focus:ring-ring"
        value={value}
        onChange={(event) => onChange(event.target.value)}
      >
        {children}
      </select>
    </label>
  );
}

function CatalogLoadingState() {
  return (
    <div className="rounded-xl border bg-card p-6 text-sm text-muted-foreground">
      Loading catalog identities…
    </div>
  );
}

function EmptyState({ hasSearch }: { hasSearch: boolean }) {
  return (
    <div className="rounded-xl border border-dashed bg-card p-8 text-center">
      <p className="font-medium">No catalog identities found</p>
      <p className="mt-1 text-sm text-muted-foreground">
        {hasSearch
          ? "Try a different SKU, product name, or filter."
          : "Try changing the lifecycle or package filters."}
      </p>
    </div>
  );
}

function CatalogResultCard({
  row,
  adopting,
  canOpenInventory,
  onDetail,
  onAdopt,
  onStock,
}: {
  row: CatalogAdminResult;
  adopting: boolean;
  canOpenInventory: boolean;
  onDetail: () => void;
  onAdopt: () => void;
  onStock: () => void;
}) {
  const packageInfo = catalogPackagePresentation(row);
  const needsReview = row.adoptionState === "attention" || row.inventoryState === "attention";
  const canStock = canStockCatalogResult(row);
  return (
    <article
      className="rounded-xl border bg-card p-4 shadow-sm sm:p-5"
      data-catalog-id={row.catalogVendorProductId}
    >
      <div className="grid gap-4 md:grid-cols-2 md:items-start 2xl:grid-cols-[minmax(0,2fr)_minmax(12rem,1fr)_minmax(12rem,1fr)_auto] 2xl:items-center">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="truncate text-base font-semibold">{row.productName}</h3>
            {row.discontinued ? (
              <Badge variant="destructive">Discontinued</Badge>
            ) : row.active ? (
              <Badge variant="secondary">Active</Badge>
            ) : (
              <Badge variant="outline">Inactive</Badge>
            )}
          </div>
          <p className="mt-1 text-sm text-muted-foreground">{row.vendorName}</p>
          <p className="mt-2 text-xs text-muted-foreground">
            SKU <span className="font-mono text-foreground">{row.vendorSku}</span>
            {row.manufacturer ? ` · ${row.manufacturer}` : ""}
          </p>
        </div>
        <InfoBlock label="Package">
          <Badge variant={packageInfo.verified ? "secondary" : "outline"}>
            {packageInfo.label}
          </Badge>
          <span className="mt-1 block text-xs text-muted-foreground">{packageInfo.detail}</span>
        </InfoBlock>
        <InfoBlock label="Organization state">
          {needsReview ? (
            <>
              <Badge variant="destructive">Review link</Badge>
              <span className="mt-1 block text-xs text-muted-foreground">{row.adoptionIssue}</span>
            </>
          ) : row.adoptionState === "adopted" ? (
            <>
              <div className="flex flex-wrap gap-1.5">
                <Badge variant="secondary">Adopted</Badge>
                {row.inventoryState === "stocked" ? (
                  <Badge variant="secondary">In inventory</Badge>
                ) : canStock ? (
                  <Badge variant="outline">Not stocked</Badge>
                ) : (
                  <Badge variant="outline">Not stockable</Badge>
                )}
              </div>
              {row.inventoryState === "stocked" && row.inventoryActive === false && (
                <span className="mt-1 block text-xs text-muted-foreground">
                  The existing inventory record is archived.
                </span>
              )}
              {row.inventoryState === "stocked" && !canOpenInventory && (
                <span className="mt-1 block text-xs text-muted-foreground">
                  Inventory management remains available to organization owners.
                </span>
              )}
              {row.inventoryState === "not_stocked" && !canStock && (
                <span className="mt-1 block text-xs text-muted-foreground">
                  Inactive or discontinued catalog items cannot create inventory.
                </span>
              )}
            </>
          ) : (
            <Badge variant="outline">Not adopted</Badge>
          )}
        </InfoBlock>
        <div className="flex flex-wrap gap-2 md:justify-end">
          <Button variant="outline" size="sm" className="min-h-10" onClick={onDetail}>
            {needsReview ? "Review details" : "View details"}
          </Button>
          {row.adoptionState === "not_adopted" && (
            <Button size="sm" className="min-h-10" disabled={adopting} onClick={onAdopt}>
              {adopting && <Loader2 className="animate-spin" />}{" "}
              {adopting ? "Adding…" : "Add to organization catalog"}
            </Button>
          )}
          {canStock && (
            <Button size="sm" className="min-h-10" onClick={onStock}>
              Add to inventory
            </Button>
          )}
          {row.inventoryState === "stocked" && row.inventoryActive && canOpenInventory && (
            <Button asChild variant="outline" size="sm" className="min-h-10">
              <Link to="/inventory">Open inventory</Link>
            </Button>
          )}
        </div>
      </div>
    </article>
  );
}

function InfoBlock({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="min-w-0">
      <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
        {label}
      </p>
      <div className="mt-1">{children}</div>
    </div>
  );
}

function CatalogDetailSheet({
  organizationId,
  row,
  open,
  onOpenChange,
}: {
  organizationId: string;
  row: CatalogAdminResult | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const detailFn = useServerFn(getCatalogAdminDetailFn);
  const detailQuery = useQuery({
    queryKey: ["catalog-admin-detail", organizationId, row?.catalogVendorProductId],
    queryFn: () =>
      detailFn({ data: { organizationId, catalogVendorProductId: row!.catalogVendorProductId } }),
    enabled: open && Boolean(row),
  });
  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-2xl">
        <SheetHeader className="pr-8 text-left">
          <SheetTitle>{row?.productName ?? "Catalog identity"}</SheetTitle>
          <SheetDescription>
            {row ? `${row.vendorName} · SKU ${row.vendorSku}` : "Review catalog identity details."}
          </SheetDescription>
        </SheetHeader>
        {detailQuery.isLoading && (
          <div className="mt-8 flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 className="animate-spin" /> Loading sanitized detail…
          </div>
        )}
        {detailQuery.error && (
          <p className="mt-8 text-sm text-destructive" role="alert">
            {detailQuery.error instanceof Error
              ? detailQuery.error.message
              : "Unable to load catalog detail."}
          </p>
        )}
        {detailQuery.data && <CatalogDetail detail={detailQuery.data} />}
      </SheetContent>
    </Sheet>
  );
}

function CatalogDetail({ detail }: { detail: CatalogAdminDetail }) {
  const packageInfo = catalogPackagePresentation({
    packageStatus: detail.package.status,
    packageDescription: detail.package.rawDescription,
    packageQuantity: detail.package.verifiedQuantity,
    packageUnit: detail.package.verifiedUnit,
  });
  return (
    <div className="mt-6 space-y-7 pb-8" data-section="catalog-detail">
      <DetailSection title="Identity">
        <DetailGrid
          entries={[
            ["Product", detail.product.name],
            ["Manufacturer", detail.product.manufacturer],
            ["Description", detail.product.description],
            ["Verification", detail.product.verificationStatus],
            ["Product state", detail.product.active ? "Active" : "Inactive"],
          ]}
        />
      </DetailSection>
      <DetailSection title="Vendor identity">
        <DetailGrid
          entries={[
            ["Vendor", detail.vendor.name],
            ["Raw vendor SKU", detail.vendor.vendorSku],
            ["Normalized SKU", detail.vendor.normalizedVendorSku],
            ["Manufacturer SKU", detail.vendor.manufacturerSku],
            ["Vendor state", detail.vendor.active ? "Active" : "Inactive"],
          ]}
        />
        {detail.vendor.website && (
          <a
            className="mt-3 inline-flex items-center gap-1 text-sm text-primary hover:underline"
            href={detail.vendor.website}
            target="_blank"
            rel="noreferrer"
          >
            Vendor website <ExternalLink className="h-3.5 w-3.5" />
          </a>
        )}
      </DetailSection>
      <DetailSection title="Package">
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={packageInfo.verified ? "secondary" : "outline"}>
            {packageInfo.label}
          </Badge>
          <span className="text-sm">{packageInfo.detail}</span>
        </div>
        {detail.package.status !== "verified" && (
          <p className="mt-2 text-xs text-muted-foreground">
            Normalized quantity and unit are intentionally not shown for source-only or unknown
            packages.
          </p>
        )}
      </DetailSection>
      <DetailSection title="Lifecycle">
        <DetailGrid
          entries={[
            [
              "Listing",
              detail.lifecycle.discontinued
                ? "Discontinued"
                : detail.lifecycle.active
                  ? "Active"
                  : "Inactive",
            ],
            ["Verification", detail.lifecycle.verificationStatus],
          ]}
        />
      </DetailSection>
      <DetailSection
        title="Source provenance"
        description="Sanitized source fields tied to this catalog identity."
      >
        {detail.provenance.length ? (
          <div className="space-y-3">
            {detail.provenance.map((source, index) => (
              <div
                key={`${source.sourceName}-${source.sourceVersion}-${index}`}
                className="rounded-lg border p-3"
              >
                <DetailGrid
                  entries={[
                    ["Source", source.sourceName],
                    ["Version", source.sourceVersion],
                    ["Page", source.sourcePage],
                    ["Raw SKU", source.rawVendorSku],
                    ["Raw product", source.rawProductName],
                    ["Raw variant", source.rawVariant],
                    ["Raw package", source.rawPackage],
                  ]}
                />
              </div>
            ))}
          </div>
        ) : (
          <p className="text-sm text-muted-foreground">
            No source provenance is available for this identity.
          </p>
        )}
      </DetailSection>
      <DetailSection
        title="Active verification decisions"
        description="Only active, currently effective decisions are shown."
      >
        {detail.verificationOverrides.length ? (
          <div className="space-y-3">
            {detail.verificationOverrides.map((decision, index) => (
              <div
                key={`${decision.overrideType}-${decision.effectiveFrom}-${index}`}
                className="rounded-lg border p-3"
              >
                <DetailGrid
                  entries={[
                    ["Decision", decision.overrideType],
                    ["Evidence", decision.evidenceStatus],
                    ["Production rule", decision.productionRule],
                    ["Source SKU", decision.sourceVendorSku],
                    ["Verified SKU", decision.verifiedVendorSku],
                    ["Effective from", formatDate(decision.effectiveFrom)],
                    [
                      "Source",
                      [decision.sourceName, decision.sourceVersion].filter(Boolean).join(" · ") ||
                        null,
                    ],
                  ]}
                />
              </div>
            ))}
          </div>
        ) : (
          <p className="text-sm text-muted-foreground">
            No active verification decisions are attached.
          </p>
        )}
      </DetailSection>
    </div>
  );
}

function DetailSection({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: React.ReactNode;
}) {
  return (
    <section>
      <h2 className="text-sm font-semibold">{title}</h2>
      {description && <p className="mt-1 text-xs text-muted-foreground">{description}</p>}
      <div className="mt-3">{children}</div>
    </section>
  );
}

function DetailGrid({ entries }: { entries: Array<[string, string | null | undefined]> }) {
  return (
    <dl className="grid gap-3 sm:grid-cols-2">
      {entries.map(([label, value]) =>
        value ? (
          <div key={label}>
            <dt className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
              {label}
            </dt>
            <dd className="mt-1 break-words text-sm">{value}</dd>
          </div>
        ) : null,
      )}
    </dl>
  );
}

function formatDate(value: string): string {
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? value : parsed.toLocaleDateString();
}

import { Loader2, Search } from "lucide-react";
import { useEffect, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import {
  COVERAGE_STATUS_LABELS,
  GLOBAL_CATALOG_PROMOTION_UNAVAILABLE_REASON,
  canLinkOrganizationVendor,
  catalogListingStateLabel,
  catalogVendorLinkBlockReason,
  coverageStatusDetail,
  filterCoverageRows,
  filterLinkableCatalogVendors,
  vendorLinkPresentation,
  type CatalogCoverage,
  type CatalogCoverageRow,
  type CoverageFilter,
  type LinkableCatalogVendor,
  type OrganizationVendorLink,
} from "@/catalog-admin/vendor-management";

export function VendorLinkTable({
  vendors,
  selectedVendorId,
  onLink,
  onSelectCoverage,
}: {
  vendors: OrganizationVendorLink[];
  selectedVendorId: string | null;
  onLink: (vendor: OrganizationVendorLink) => void;
  onSelectCoverage: (vendor: OrganizationVendorLink) => void;
}) {
  if (!vendors.length) {
    return (
      <div className="rounded-xl border border-dashed bg-card p-6 text-sm text-muted-foreground">
        This organization has no vendors yet. Vendors are added from invoices or the catalog.
      </div>
    );
  }
  return (
    <div className="overflow-x-auto rounded-xl border bg-card" data-section="vendor-links">
      <table className="w-full min-w-[40rem] text-sm">
        <thead className="border-b bg-muted/40 text-left text-[11px] uppercase tracking-wide text-muted-foreground">
          <tr>
            <th className="px-4 py-2 font-semibold">Vendor</th>
            <th className="px-4 py-2 font-semibold">Catalog link</th>
            <th className="px-4 py-2 font-semibold">Status</th>
            <th className="px-4 py-2 text-right font-semibold">Action</th>
          </tr>
        </thead>
        <tbody>
          {vendors.map((vendor) => {
            const link = vendorLinkPresentation(vendor);
            const selected = vendor.vendorId === selectedVendorId;
            return (
              <tr
                key={vendor.vendorId}
                className={`border-b last:border-0 ${selected ? "bg-primary/5" : ""}`}
                data-vendor-id={vendor.vendorId}
                data-link-state={link.state}
              >
                <td className="px-4 py-2.5">
                  <span className="font-medium">{vendor.vendorName}</span>
                  {!vendor.vendorActive && (
                    <Badge variant="outline" className="ml-2">
                      Archived
                    </Badge>
                  )}
                </td>
                <td className="px-4 py-2.5">
                  {vendor.catalogVendorName ? (
                    <span>→ {vendor.catalogVendorName}</span>
                  ) : (
                    <span className="text-muted-foreground">—</span>
                  )}
                </td>
                <td className="px-4 py-2.5">
                  <Badge
                    variant={
                      link.state === "linked"
                        ? "secondary"
                        : link.state === "unlinked"
                          ? "outline"
                          : "destructive"
                    }
                    title={link.detail}
                  >
                    {link.label}
                  </Badge>
                </td>
                <td className="px-4 py-2.5 text-right">
                  {canLinkOrganizationVendor(vendor) ? (
                    <Button size="sm" variant="outline" onClick={() => onLink(vendor)}>
                      Link catalog vendor
                    </Button>
                  ) : (
                    <Button
                      size="sm"
                      variant={selected ? "secondary" : "ghost"}
                      onClick={() => onSelectCoverage(vendor)}
                    >
                      {selected ? "Showing coverage" : "View coverage"}
                    </Button>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export function LinkCatalogVendorDialog({
  vendor,
  catalogVendors,
  catalogVendorsLoading,
  catalogVendorsError,
  query,
  onQueryChange,
  linking,
  linkError,
  onConfirm,
  onOpenChange,
}: {
  vendor: OrganizationVendorLink | null;
  catalogVendors: LinkableCatalogVendor[];
  catalogVendorsLoading: boolean;
  catalogVendorsError: string | null;
  query: string;
  onQueryChange: (query: string) => void;
  linking: boolean;
  linkError: string | null;
  onConfirm: (catalogVendor: LinkableCatalogVendor) => void;
  onOpenChange: (open: boolean) => void;
}) {
  const [chosenId, setChosenId] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  // A new vendor starts from an empty choice; nothing is preselected or prefilled.
  useEffect(() => {
    setChosenId(null);
    setConfirming(false);
  }, [vendor?.vendorId]);

  const visible = filterLinkableCatalogVendors(catalogVendors, query);
  const chosen = catalogVendors.find((candidate) => candidate.id === chosenId) ?? null;

  return (
    <Dialog open={Boolean(vendor)} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg" data-dialog="link-catalog-vendor">
        <DialogHeader>
          <DialogTitle>{confirming ? "Confirm catalog link" : "Link catalog vendor"}</DialogTitle>
          <DialogDescription>
            {confirming
              ? "Review the link before saving. It cannot be changed from this screen afterwards."
              : "Choose the global catalog vendor that this organization vendor is. Nothing is linked until you confirm."}
          </DialogDescription>
        </DialogHeader>

        {confirming && chosen && vendor ? (
          <div className="space-y-3 text-sm" data-step="confirm">
            <dl className="grid gap-3 rounded-lg border p-3">
              <div>
                <dt className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
                  Organization vendor
                </dt>
                <dd className="mt-0.5 font-medium">{vendor.vendorName}</dd>
              </div>
              <div>
                <dt className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
                  Will link to catalog vendor
                </dt>
                <dd className="mt-0.5 font-medium">{chosen.name}</dd>
              </div>
            </dl>
            <p className="text-muted-foreground">
              Future {vendor.vendorName} invoices can then match verified {chosen.name} catalog SKUs
              automatically. Existing invoices, products, SKU mappings, inventory, and price history
              are not changed.
            </p>
          </div>
        ) : (
          <div className="space-y-3" data-step="choose">
            <div className="relative">
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                aria-label="Search catalog vendors by name"
                className="pl-9"
                placeholder="Search catalog vendors by name"
                value={query}
                onChange={(event) => onQueryChange(event.target.value)}
              />
            </div>
            {catalogVendorsLoading ? (
              <p className="flex items-center gap-2 py-2 text-sm text-muted-foreground">
                <Loader2 className="h-4 w-4 animate-spin" /> Loading catalog vendors…
              </p>
            ) : catalogVendorsError ? (
              <p role="alert" className="py-2 text-sm text-destructive">
                {catalogVendorsError}
              </p>
            ) : !visible.length ? (
              <p className="py-2 text-sm text-muted-foreground">
                No catalog vendors match. Catalog vendors are not created from here.
              </p>
            ) : (
              <div
                className="max-h-64 space-y-1.5 overflow-y-auto pr-1"
                role="radiogroup"
                aria-label="Catalog vendors"
              >
                {visible.map((candidate) => {
                  const blocked = catalogVendorLinkBlockReason(candidate);
                  const isChosen = candidate.id === chosenId;
                  return (
                    <button
                      key={candidate.id}
                      type="button"
                      role="radio"
                      aria-checked={isChosen}
                      disabled={Boolean(blocked)}
                      onClick={() => setChosenId(candidate.id)}
                      className={`flex w-full items-center justify-between gap-3 rounded-md border px-3 py-2 text-left text-sm disabled:cursor-not-allowed disabled:opacity-60 ${isChosen ? "border-primary bg-primary/5" : "hover:bg-muted/50"}`}
                    >
                      <span className="font-medium">{candidate.name}</span>
                      {blocked && <span className="text-xs text-muted-foreground">{blocked}</span>}
                    </button>
                  );
                })}
              </div>
            )}
          </div>
        )}

        {linkError && (
          <p role="alert" className="text-sm text-destructive">
            {linkError}
          </p>
        )}

        <DialogFooter>
          {confirming ? (
            <>
              <Button variant="outline" disabled={linking} onClick={() => setConfirming(false)}>
                Back
              </Button>
              <Button disabled={linking || !chosen} onClick={() => chosen && onConfirm(chosen)}>
                {linking && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}Confirm link
              </Button>
            </>
          ) : (
            <>
              <Button variant="outline" onClick={() => onOpenChange(false)}>
                Cancel
              </Button>
              <Button disabled={!chosen} onClick={() => setConfirming(true)}>
                Review link
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function CatalogCoverageSection({
  vendorName,
  coverage,
  loading,
  error,
  filter,
  onFilterChange,
  onReview,
}: {
  vendorName: string | null;
  coverage: CatalogCoverage | undefined;
  loading: boolean;
  error: string | null;
  filter: CoverageFilter;
  onFilterChange: (filter: CoverageFilter) => void;
  onReview: (row: CatalogCoverageRow) => void;
}) {
  if (!vendorName) {
    return (
      <div className="rounded-xl border border-dashed bg-card p-6 text-sm text-muted-foreground">
        Choose a linked vendor above to see which of its SKUs the global catalog already lists.
      </div>
    );
  }
  if (loading) {
    return (
      <div className="flex items-center gap-2 rounded-xl border bg-card p-6 text-sm text-muted-foreground">
        <Loader2 className="h-4 w-4 animate-spin" /> Loading catalog coverage…
      </div>
    );
  }
  if (error) {
    return (
      <div
        className="rounded-xl border border-destructive/40 bg-destructive/5 p-4 text-sm text-destructive"
        role="alert"
      >
        {error}
      </div>
    );
  }
  if (!coverage) return null;
  if (!coverage.linked || !coverage.summary || !coverage.catalogVendor) {
    return (
      <div className="rounded-xl border border-dashed bg-card p-6 text-sm text-muted-foreground">
        {coverage.vendorName} is not linked to a catalog vendor, so there is no catalog to compare.
      </div>
    );
  }
  const rows = filterCoverageRows(coverage.rows, filter);
  const { summary } = coverage;
  return (
    <div className="rounded-xl border bg-card" data-section="catalog-coverage">
      <div className="flex flex-wrap items-end justify-between gap-3 border-b px-4 py-3">
        <div>
          <p className="text-sm font-semibold">
            {coverage.vendorName}
            <span className="font-normal text-muted-foreground">
              {" "}
              → {coverage.catalogVendor.name}
            </span>
          </p>
          <p className="mt-1 text-xs text-muted-foreground" data-coverage-summary>
            {summary.mapped} mapped SKU{summary.mapped === 1 ? "" : "s"} · {summary.represented} in
            catalog · {summary.notRepresented} organization-only
            {summary.inactiveMappings ? ` · ${summary.inactiveMappings} inactive` : ""}
          </p>
        </div>
        <label className="text-xs font-medium text-muted-foreground">
          <span className="sr-only">Coverage filter</span>
          <select
            className="h-9 rounded-md border border-input bg-background px-2 text-sm font-normal text-foreground"
            value={filter}
            onChange={(event) => onFilterChange(event.target.value as CoverageFilter)}
          >
            <option value="not_cataloged">Not in catalog</option>
            <option value="all">All mapped SKUs</option>
          </select>
        </label>
      </div>
      {!rows.length ? (
        <p className="p-6 text-sm text-muted-foreground">
          {filter === "not_cataloged"
            ? `Every mapped ${coverage.vendorName} SKU is already in the ${coverage.catalogVendor.name} catalog.`
            : `No ${coverage.vendorName} SKUs are mapped for this organization yet.`}
        </p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[44rem] text-sm">
            <thead className="border-b bg-muted/40 text-left text-[11px] uppercase tracking-wide text-muted-foreground">
              <tr>
                <th className="px-4 py-2 font-semibold">Vendor SKU</th>
                <th className="px-4 py-2 font-semibold">Organization product</th>
                <th className="px-4 py-2 font-semibold">Manufacturer</th>
                <th className="px-4 py-2 font-semibold">Package / UOM</th>
                <th className="px-4 py-2 font-semibold">Catalog status</th>
                <th className="px-4 py-2 text-right font-semibold">Action</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr
                  key={row.vendorProductId}
                  className="border-b last:border-0"
                  data-coverage-status={row.status}
                >
                  <td className="px-4 py-2 font-mono text-xs">{row.vendorSku}</td>
                  <td className="px-4 py-2">
                    {row.productName}
                    {!row.mappingActive && (
                      <Badge variant="outline" className="ml-2">
                        Inactive mapping
                      </Badge>
                    )}
                  </td>
                  <td className="px-4 py-2 text-muted-foreground">{row.manufacturer || "—"}</td>
                  <td className="px-4 py-2 text-muted-foreground">
                    {[row.packageSize, row.unitOfMeasure].filter(Boolean).join(" · ") || "—"}
                  </td>
                  <td className="px-4 py-2">
                    <Badge variant={row.status === "not_cataloged" ? "outline" : "secondary"}>
                      {COVERAGE_STATUS_LABELS[row.status]}
                    </Badge>
                  </td>
                  <td className="px-4 py-2 text-right">
                    <Button size="sm" variant="ghost" onClick={() => onReview(row)}>
                      Review
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {coverage.truncated && (
        <p className="border-t px-4 py-2 text-xs text-muted-foreground">
          Showing the first 1,000 mappings. Counts above include every mapping.
        </p>
      )}
    </div>
  );
}

export function CoverageReviewSheet({
  row,
  organizationVendorName,
  catalogVendorName,
  onOpenChange,
}: {
  row: CatalogCoverageRow | null;
  organizationVendorName: string;
  catalogVendorName: string;
  onOpenChange: (open: boolean) => void;
}) {
  return (
    <Sheet open={Boolean(row)} onOpenChange={onOpenChange}>
      <SheetContent className="w-full overflow-y-auto sm:max-w-lg" data-sheet="coverage-review">
        <SheetHeader className="pr-8 text-left">
          <SheetTitle>{row?.productName ?? "Organization mapping"}</SheetTitle>
          <SheetDescription>
            {row ? `${organizationVendorName} · SKU ${row.vendorSku}` : "Review this mapping."}
          </SheetDescription>
        </SheetHeader>
        {row && (
          <div className="mt-6 space-y-6 pb-8 text-sm">
            <section>
              <h2 className="text-sm font-semibold">Organization mapping</h2>
              <p className="mt-1 text-xs text-muted-foreground">
                Private to this organization. Never shared with other organizations.
              </p>
              <dl className="mt-3 grid gap-3 sm:grid-cols-2">
                <ReviewEntry label="Vendor SKU" value={row.vendorSku} mono />
                <ReviewEntry label="Organization product" value={row.productName} />
                <ReviewEntry label="Manufacturer" value={row.manufacturer} />
                <ReviewEntry label="Manufacturer SKU" value={row.manufacturerSku} mono />
                <ReviewEntry label="Package" value={row.packageSize} />
                <ReviewEntry label="Unit of measure" value={row.unitOfMeasure} />
                <ReviewEntry
                  label="Mapping"
                  value={row.mappingActive ? "Active" : "Inactive (not used for matching)"}
                />
                <ReviewEntry label="First saved" value={formatDate(row.mappingCreatedAt)} />
              </dl>
            </section>
            <section>
              <h2 className="text-sm font-semibold">{catalogVendorName} catalog</h2>
              <div className="mt-2 flex flex-wrap items-center gap-2">
                <Badge variant={row.status === "not_cataloged" ? "outline" : "secondary"}>
                  {COVERAGE_STATUS_LABELS[row.status]}
                </Badge>
                {row.listing && (
                  <Badge variant="outline">{catalogListingStateLabel(row.listing)}</Badge>
                )}
              </div>
              <p className="mt-2 text-muted-foreground">{coverageStatusDetail(row)}</p>
              {row.listing && (
                <dl className="mt-3 grid gap-3 sm:grid-cols-2">
                  <ReviewEntry label="Catalog SKU" value={row.listing.vendorSku} mono />
                  <ReviewEntry label="Catalog product" value={row.listing.productName} />
                </dl>
              )}
            </section>
            {row.status === "not_cataloged" && (
              <section
                className="rounded-lg border border-dashed bg-muted/30 p-3"
                data-section="promotion-unavailable"
              >
                <h2 className="text-sm font-semibold">Shared catalog</h2>
                <p className="mt-1 text-muted-foreground">
                  {GLOBAL_CATALOG_PROMOTION_UNAVAILABLE_REASON}
                </p>
              </section>
            )}
          </div>
        )}
      </SheetContent>
    </Sheet>
  );
}

function ReviewEntry({
  label,
  value,
  mono,
}: {
  label: string;
  value: string | null | undefined;
  mono?: boolean;
}) {
  return (
    <div>
      <dt className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
        {label}
      </dt>
      <dd className={`mt-1 break-words ${mono ? "font-mono text-xs" : ""}`}>{value || "—"}</dd>
    </div>
  );
}

function formatDate(value: string): string {
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? value : parsed.toLocaleDateString();
}

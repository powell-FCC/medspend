import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { AlertCircle, Loader2 } from "lucide-react";
import { getProductPriceIntelligenceFn } from "@/lib/price-intelligence.functions";
import {
  formatPrice,
  formatPriceChange,
  formatPurchaseDate,
  type ProductPriceIntelligence as PriceIntelligence,
} from "@/price-intelligence/price-intelligence";

export function ProductPriceIntelligence({
  organizationId,
  productId,
}: {
  organizationId: string;
  productId: string | null;
}) {
  const fetchPriceIntelligence = useServerFn(getProductPriceIntelligenceFn);
  const query = useQuery({
    queryKey: ["product-price-intelligence", organizationId, productId],
    queryFn: () => fetchPriceIntelligence({ data: { organizationId, productId: productId! } }),
    enabled: Boolean(productId),
  });

  if (!productId) {
    return (
      <section data-section="price-intelligence">
        <h2 className="text-sm font-semibold">Price history</h2>
        <p className="mt-2 text-sm text-muted-foreground">
          Adopt this catalog identity before organization purchase history can be shown.
        </p>
      </section>
    );
  }
  if (query.isLoading) {
    return (
      <section data-section="price-intelligence">
        <h2 className="text-sm font-semibold">Price history</h2>
        <p className="mt-3 flex items-center gap-2 text-sm text-muted-foreground" role="status">
          <Loader2 className="h-4 w-4 animate-spin" /> Loading posted purchase history…
        </p>
      </section>
    );
  }
  if (query.error || !query.data) {
    return (
      <section data-section="price-intelligence">
        <h2 className="text-sm font-semibold">Price history</h2>
        <p className="mt-3 flex items-center gap-2 text-sm text-destructive" role="alert">
          <AlertCircle className="h-4 w-4" /> Price history is temporarily unavailable.
        </p>
      </section>
    );
  }
  return <PriceIntelligenceDetail intelligence={query.data} />;
}

function PriceIntelligenceDetail({ intelligence }: { intelligence: PriceIntelligence }) {
  const { summary, coverage } = intelligence;
  const excluded =
    coverage.excludedUnknownCurrencyCount +
    coverage.excludedNonUsdCount +
    coverage.excludedMissingPriceCount;

  return (
    <section data-section="price-intelligence" aria-labelledby="price-intelligence-heading">
      <h2 id="price-intelligence-heading" className="text-sm font-semibold">
        Price history
      </h2>
      <p className="mt-1 text-xs text-muted-foreground">
        Posted invoice purchases in USD for this exact organization product.
      </p>

      {summary.observationCount === 0 ? (
        <div className="mt-3 rounded-lg border border-dashed p-4">
          <p className="text-sm font-medium">No comparable USD purchase history</p>
          <p className="mt-1 text-xs leading-5 text-muted-foreground">
            No posted observation has both an explicit USD currency and a usable purchase price.
          </p>
        </div>
      ) : (
        <>
          <dl className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-3">
            <PriceMetric label="Latest paid" value={formatPrice(summary.latestPrice)} />
            <PriceMetric label="Previous" value={formatPrice(summary.previousPrice)} />
            <PriceMetric label="Change" value={formatPriceChange(summary)} />
            <PriceMetric
              label="Historical range"
              value={`${formatPrice(summary.historicalLow)} – ${formatPrice(summary.historicalHigh)}`}
            />
            <PriceMetric
              label="Purchases"
              value={`${summary.observationCount} observation${summary.observationCount === 1 ? "" : "s"}`}
            />
            <PriceMetric
              label="Latest purchase"
              value={formatPurchaseDate(summary.latestPriceDate)}
            />
          </dl>

          <h3 className="mt-6 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            Recent purchases
          </h3>
          <div className="mt-2 overflow-x-auto rounded-lg border">
            <table className="w-full min-w-[620px] text-left text-xs">
              <thead className="bg-muted/60 text-muted-foreground">
                <tr>
                  <th className="px-3 py-2 font-medium">Date</th>
                  <th className="px-3 py-2 font-medium">Vendor</th>
                  <th className="px-3 py-2 font-medium">Price</th>
                  <th className="px-3 py-2 font-medium">Package evidence</th>
                  <th className="px-3 py-2 font-medium">Source</th>
                </tr>
              </thead>
              <tbody className="divide-y">
                {intelligence.recentPurchases.map((purchase) => (
                  <tr key={purchase.observationId}>
                    <td className="whitespace-nowrap px-3 py-2.5">
                      {formatPurchaseDate(purchase.purchaseDate)}
                    </td>
                    <td className="px-3 py-2.5">
                      <span className="font-medium">{purchase.vendorName}</span>
                      {purchase.vendorSku && (
                        <span className="mt-0.5 block font-mono text-muted-foreground">
                          {purchase.vendorSku}
                        </span>
                      )}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2.5 font-medium tabular-nums">
                      {formatPrice(purchase.purchasePrice)}
                    </td>
                    <td className="px-3 py-2.5 text-muted-foreground">
                      {[purchase.packageDescription, purchase.unitOfMeasure]
                        .filter(Boolean)
                        .join(" · ") || "Not recorded"}
                      <span className="mt-0.5 block">Unverified</span>
                    </td>
                    <td className="px-3 py-2.5 text-muted-foreground">
                      Posted invoice {purchase.invoiceNumber || purchase.invoiceId.slice(0, 8)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <h3 className="mt-6 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            Vendor history
          </h3>
          <div className="mt-2 grid gap-2 sm:grid-cols-2">
            {intelligence.vendorHistory.map((vendor) => (
              <div key={vendor.vendorId} className="rounded-lg border p-3">
                <p className="text-sm font-medium">{vendor.vendorName}</p>
                <dl className="mt-2 grid grid-cols-2 gap-2 text-xs">
                  <VendorMetric label="Latest" value={formatPrice(vendor.latestPrice)} />
                  <VendorMetric label="Previous" value={formatPrice(vendor.previousPrice)} />
                  <VendorMetric
                    label="Range"
                    value={`${formatPrice(vendor.historicalLow)} – ${formatPrice(vendor.historicalHigh)}`}
                  />
                  <VendorMetric label="Observations" value={String(vendor.observationCount)} />
                </dl>
              </div>
            ))}
          </div>
        </>
      )}

      <div className="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs leading-5 text-amber-950">
        <span className="font-semibold">Vendor price comparison unavailable.</span>{" "}
        {intelligence.packageComparability.reason} Raw purchase evidence is shown without a
        cheaper-vendor conclusion.
      </div>
      {excluded > 0 && (
        <p className="mt-2 text-xs leading-5 text-muted-foreground">
          {excluded} posted observation{excluded === 1 ? " was" : "s were"} excluded from USD
          metrics: {coverage.excludedUnknownCurrencyCount} unknown currency,{" "}
          {coverage.excludedNonUsdCount} non-USD, and {coverage.excludedMissingPriceCount} without a
          usable price.
        </p>
      )}
    </section>
  );
}

function PriceMetric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border bg-muted/20 p-3">
      <dt className="text-[11px] font-medium text-muted-foreground">{label}</dt>
      <dd className="mt-1 text-sm font-semibold tabular-nums">{value}</dd>
    </div>
  );
}

function VendorMetric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="mt-0.5 font-medium tabular-nums">{value}</dd>
    </div>
  );
}

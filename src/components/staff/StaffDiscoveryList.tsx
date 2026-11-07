import { Bookmark, BookmarkCheck, Plus, Repeat2, ShoppingBag } from "lucide-react";
import { useState } from "react";
import {
  STAFF_DISCOVERY_SECTIONS,
  STAFF_DISCOVERY_VISIBLE_ROWS,
  describeProductVariant,
  productBadges,
  type StaffDiscoveryProduct,
} from "@/supply-requests/product-discovery";
import {
  findCartLineForSelection,
  type StaffProductSelection,
  type StaffRequestCartItem,
} from "@/supply-requests/staff-request-cart";
import { QuantityStepper } from "@/components/staff/QuantityStepper";
import { StaffErrorState, StaffListSkeleton } from "@/components/staff/StaffStates";
import type {
  StaffDiscoveryState,
  StaffSavedControls,
} from "@/components/staff/useStaffProductSearch";

export type StaffCartControls = {
  cartItems: StaffRequestCartItem[];
  cartFull: boolean;
  onAddProduct: (selection: StaffProductSelection) => void;
  onChangeQuantity: (key: string, delta: number) => void;
  onRemove: (key: string) => void;
};

// Phase 5A.10 product row: name, the attributes that tell this variant apart, at most two
// quiet organization-history badges, a Saved toggle and one-tap Add.
export function StaffDiscoveryRow({
  product,
  listed,
  saved,
  cartItems,
  cartFull,
  onAddProduct,
  onChangeQuantity,
  onRemove,
}: StaffCartControls & {
  product: StaffDiscoveryProduct;
  listed: ReadonlyArray<StaffDiscoveryProduct>;
  saved?: StaffSavedControls;
}) {
  const line = findCartLineForSelection(cartItems, product);
  const variant = describeProductVariant(product, listed);
  const badges = productBadges(product);
  const isSaved = saved?.isSaved(product) ?? false;
  return (
    <li className="flex items-start gap-2 px-4 py-3">
      <div className="min-w-0 flex-1 pt-0.5">
        <span className="block font-medium leading-6 text-[#071d38] [overflow-wrap:anywhere]">
          {product.productName}
        </span>
        {variant.primary && (
          <span className="block text-sm font-medium leading-5 text-[#344256] [overflow-wrap:anywhere]">
            {variant.primary}
          </span>
        )}
        {variant.secondary && (
          <span className="block text-xs leading-5 text-[#697687] [overflow-wrap:anywhere]">
            {variant.secondary}
          </span>
        )}
        {badges.length > 0 && (
          <span className="mt-1 flex flex-wrap gap-1">
            {badges.map((badge) => (
              <span
                key={badge.kind}
                data-badge={badge.kind}
                className="inline-flex max-w-full items-center rounded-full bg-[#eef3f8] px-2 py-0.5 text-[0.7rem] font-medium leading-4 text-[#3d4b5c] [overflow-wrap:anywhere]"
              >
                {badge.label}
              </span>
            ))}
          </span>
        )}
      </div>
      <div className="flex shrink-0 items-center gap-1">
        {saved && (
          <button
            type="button"
            onClick={() => saved.toggle(product)}
            disabled={saved.isPending(product)}
            aria-pressed={isSaved}
            aria-label={
              isSaved
                ? `Remove ${product.productName} from saved items`
                : `Save ${product.productName}`
            }
            className={`flex size-11 items-center justify-center rounded-full transition active:bg-[#eef1f4] disabled:opacity-60 ${
              isSaved ? "text-[#d95700]" : "text-[#7b8693]"
            }`}
          >
            {isSaved ? (
              <BookmarkCheck className="size-5" aria-hidden="true" />
            ) : (
              <Bookmark className="size-5" aria-hidden="true" />
            )}
          </button>
        )}
        {line ? (
          <QuantityStepper
            name={product.productName}
            quantity={line.quantity}
            onDecrease={() => onChangeQuantity(line.key, -1)}
            onIncrease={() => onChangeQuantity(line.key, 1)}
            onRemove={() => onRemove(line.key)}
          />
        ) : (
          <button
            type="button"
            onClick={() => onAddProduct(product)}
            disabled={cartFull}
            aria-label={`Add ${product.productName}`}
            className="inline-flex min-h-11 shrink-0 items-center gap-1.5 rounded-xl bg-[#071d38] px-3.5 text-sm font-semibold text-white transition active:scale-[0.97] active:bg-[#0d2a4d] disabled:bg-[#9aa3ad]"
          >
            <Plus className="size-4" aria-hidden="true" />
            Add
          </button>
        )}
      </div>
    </li>
  );
}

export function StaffDiscoveryRows({
  label,
  products,
  saved,
  controls,
}: {
  label: string;
  products: ReadonlyArray<StaffDiscoveryProduct>;
  saved?: StaffSavedControls;
  controls: StaffCartControls;
}) {
  return (
    <ul
      aria-label={label}
      className="divide-y divide-[#edf0f3] overflow-hidden rounded-2xl border border-[#e1e6ec] bg-white shadow-[0_4px_18px_rgba(7,29,56,0.04)]"
    >
      {products.map((product) => (
        <StaffDiscoveryRow
          key={product.resultId}
          product={product}
          listed={products}
          saved={saved}
          {...controls}
        />
      ))}
    </ul>
  );
}

const sectionIcons = {
  saved: <BookmarkCheck className="size-3.5" aria-hidden="true" />,
  frequent: <Repeat2 className="size-3.5" aria-hidden="true" />,
  purchased: <ShoppingBag className="size-3.5" aria-hidden="true" />,
};

// Request Supplies start: Saved items first, then what the organization requests and buys.
// Compact: a section shows a few rows and expands in place.
export function StaffDiscoverySections({
  state,
  saved,
  controls,
}: {
  state: StaffDiscoveryState;
  saved?: StaffSavedControls;
  controls: StaffCartControls;
}) {
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());
  if (state.status === "loading") return <StaffListSkeleton label="Loading your items" />;
  if (state.status === "error")
    return <StaffErrorState message="We couldn't load your saved items." onRetry={state.retry} />;
  const visibleSections = STAFF_DISCOVERY_SECTIONS.filter(
    (section) => state.sections[section.id].length > 0,
  );
  if (visibleSections.length === 0)
    return (
      <p className="rounded-2xl bg-white/70 px-4 py-3 text-sm leading-6 text-[#697687]">
        Tap the bookmark on any item to save it here, so you can add it again in one tap.
      </p>
    );
  return (
    <div className="space-y-5">
      {visibleSections.map((section) => {
        const products = state.sections[section.id];
        const isExpanded = expanded.has(section.id);
        const shown = isExpanded ? products : products.slice(0, STAFF_DISCOVERY_VISIBLE_ROWS);
        const hidden = products.length - shown.length;
        const headingId = `discovery-${section.id}`;
        return (
          <section key={section.id} aria-labelledby={headingId}>
            <h3
              id={headingId}
              className="mb-2 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-[0.12em] text-[#5c6878]"
            >
              {sectionIcons[section.id]}
              {section.title}
              {section.id === "saved" && (
                <span className="font-normal normal-case tracking-normal text-[#7b8693]">
                  · {products.length}
                </span>
              )}
            </h3>
            <StaffDiscoveryRows
              label={section.title}
              products={shown}
              saved={saved}
              controls={controls}
            />
            {(hidden > 0 || isExpanded) && products.length > STAFF_DISCOVERY_VISIBLE_ROWS && (
              <button
                type="button"
                aria-expanded={isExpanded}
                onClick={() =>
                  setExpanded((current) => {
                    const next = new Set(current);
                    if (next.has(section.id)) next.delete(section.id);
                    else next.add(section.id);
                    return next;
                  })
                }
                className="mt-1 min-h-11 px-1 text-sm font-semibold text-[#566477]"
              >
                {isExpanded ? "Show fewer" : `Show all ${products.length}`}
              </button>
            )}
          </section>
        );
      })}
    </div>
  );
}

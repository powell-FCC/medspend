import { Clock3, PackagePlus, Plus, Repeat2, Search, X } from "lucide-react";
import { useState } from "react";
import type { UnifiedSupplyRequestSearchResult } from "@/lib/supply-requests.functions";
import {
  findCartLineForSelection,
  getStaffRequestProductDisplayLines,
  type StaffProductSelection,
  type StaffRequestCartItem,
} from "@/supply-requests/staff-request-cart";
import type { StaffQuickPick } from "@/supply-requests/staff-workspace";
import { QuantityStepper } from "@/components/staff/QuantityStepper";
import { StaffErrorState, StaffListSkeleton } from "@/components/staff/StaffStates";
import type {
  StaffQuickPicksState,
  StaffSearchState,
} from "@/components/staff/useStaffProductSearch";

const shortDate = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });

export function ProductDetails({
  product,
}: {
  product: Pick<
    UnifiedSupplyRequestSearchResult,
    "manufacturer" | "vendorName" | "vendorSku" | "packageDisplay" | "specification"
  >;
}) {
  const lines = getStaffRequestProductDisplayLines(product);
  if (lines.length === 0) return null;

  return (
    <span className="mt-0.5 block [overflow-wrap:anywhere]">
      {lines.map((line) => (
        <span
          key={line.kind}
          className={
            line.kind === "specification"
              ? "block text-sm font-medium leading-5 text-[#344256]"
              : "block text-xs leading-5 text-[#697687]"
          }
        >
          {line.text}
        </span>
      ))}
    </span>
  );
}

type CartControls = {
  cartItems: StaffRequestCartItem[];
  cartFull: boolean;
  onAddProduct: (selection: StaffProductSelection) => void;
  onChangeQuantity: (key: string, delta: number) => void;
  onRemove: (key: string) => void;
};

export function StaffProductRow({
  product,
  meta,
  cartItems,
  cartFull,
  onAddProduct,
  onChangeQuantity,
  onRemove,
}: CartControls & { product: StaffProductSelection; meta?: string }) {
  const line = findCartLineForSelection(cartItems, product);
  return (
    <li className="flex items-center gap-3 px-4 py-3">
      <div className="min-w-0 flex-1">
        <span className="block font-medium leading-6 text-[#071d38] [overflow-wrap:anywhere]">
          {product.productName}
        </span>
        <ProductDetails product={product} />
        {meta && <span className="mt-0.5 block text-xs text-[#7a8491]">{meta}</span>}
      </div>
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
    </li>
  );
}

function ProductList({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <ul
      aria-label={label}
      className="divide-y divide-[#edf0f3] overflow-hidden rounded-2xl border border-[#e1e6ec] bg-white shadow-[0_4px_18px_rgba(7,29,56,0.04)]"
    >
      {children}
    </ul>
  );
}

function QuickPickSection({
  id,
  title,
  icon,
  picks,
  describe,
  controls,
}: {
  id: string;
  title: string;
  icon: React.ReactNode;
  picks: StaffQuickPick[];
  describe: (pick: StaffQuickPick) => string;
  controls: CartControls;
}) {
  if (picks.length === 0) return null;
  return (
    <section aria-labelledby={id}>
      <h3
        id={id}
        className="mb-2 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-[0.12em] text-[#5c6878]"
      >
        {icon}
        {title}
      </h3>
      <ProductList label={title}>
        {picks.map((pick) => (
          <StaffProductRow key={pick.key} product={pick} meta={describe(pick)} {...controls} />
        ))}
      </ProductList>
    </section>
  );
}

export function StaffQuickPicks({
  state,
  controls,
}: {
  state: StaffQuickPicksState;
  controls: CartControls;
}) {
  if (state.status === "loading") return <StaffListSkeleton label="Loading your items" />;
  if (state.status === "error")
    return <StaffErrorState message="We couldn't load your usual items." onRetry={state.retry} />;
  const { frequent, recent } = state.picks;
  if (frequent.length === 0 && recent.length === 0)
    return (
      <p className="rounded-2xl bg-white/70 px-4 py-3 text-sm leading-6 text-[#697687]">
        Items you request will show up here, so you can add them again in one tap.
      </p>
    );
  return (
    <div className="space-y-5">
      <QuickPickSection
        id="quick-picks-frequent"
        title="Frequent"
        icon={<Repeat2 className="size-3.5" aria-hidden="true" />}
        picks={frequent}
        describe={(pick) => `Requested ${pick.requestCount} times`}
        controls={controls}
      />
      <QuickPickSection
        id="quick-picks-recent"
        title="Recent"
        icon={<Clock3 className="size-3.5" aria-hidden="true" />}
        picks={recent}
        describe={(pick) => `Last requested ${shortDate.format(new Date(pick.lastRequestedAt))}`}
        controls={controls}
      />
    </div>
  );
}

// Search (canonical staff search), quick picks and the custom-item fallback. Adding is
// one tap; quantities are adjusted in place. Nothing here submits.
export function StaffProductPicker({
  inputId,
  label,
  query,
  onQueryChange,
  search,
  quickPicks,
  onAddCustom,
  autoFocus,
  ...controls
}: CartControls & {
  inputId: string;
  label: string;
  query: string;
  onQueryChange: (query: string) => void;
  search: StaffSearchState;
  quickPicks?: StaffQuickPicksState;
  onAddCustom: (name: string) => void;
  autoFocus?: boolean;
}) {
  const [customItem, setCustomItem] = useState("");
  const [customOpen, setCustomOpen] = useState(false);

  function addItem() {
    const name = customItem.trim();
    if (!name || controls.cartFull) return;
    onAddCustom(name);
    setCustomItem("");
  }

  return (
    <div>
      <label htmlFor={inputId} className="sr-only">
        {label}
      </label>
      <div className="relative">
        <Search
          className="pointer-events-none absolute left-4 top-1/2 size-5 -translate-y-1/2 text-[#7b8693]"
          aria-hidden="true"
        />
        <input
          id={inputId}
          type="search"
          enterKeyHint="search"
          value={query}
          onChange={(event) => onQueryChange(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") event.preventDefault();
          }}
          placeholder="Search products or supplies…"
          maxLength={120}
          autoComplete="off"
          autoFocus={autoFocus}
          className="min-h-14 w-full rounded-2xl border border-[#dce2e8] bg-white pl-12 pr-12 text-base text-[#071d38] shadow-sm outline-none placeholder:text-[#8f99a5] focus:border-[#f56600] focus:ring-4 focus:ring-[#f56600]/10 [&::-webkit-search-cancel-button]:hidden"
        />
        {query && (
          <button
            type="button"
            onClick={() => onQueryChange("")}
            aria-label="Clear search"
            className="absolute right-1.5 top-1/2 flex size-11 -translate-y-1/2 items-center justify-center rounded-full text-[#637080] active:bg-[#eef1f4]"
          >
            <X className="size-5" aria-hidden="true" />
          </button>
        )}
      </div>

      <div className="mt-3" aria-live="polite">
        {search.status === "idle" && (
          <>
            <p className="px-1 pb-3 text-sm text-[#697687]">
              Search by product name, size, manufacturer, vendor, or SKU.
            </p>
            {quickPicks && <StaffQuickPicks state={quickPicks} controls={controls} />}
          </>
        )}
        {(search.status === "short" || search.status === "typing") && (
          <p className="px-1 py-2 text-sm text-[#697687]">
            {search.status === "short"
              ? "Enter at least 2 characters to search."
              : "Searching after you pause…"}
          </p>
        )}
        {search.status === "loading" && <StaffListSkeleton label="Searching supplies" />}
        {search.status === "error" && (
          <StaffErrorState
            message="We couldn't search supplies. Check your connection and try again."
            onRetry={search.retry}
          />
        )}
        {search.status === "empty" && (
          <div className="rounded-2xl border border-dashed border-[#cfd6de] bg-white/70 p-4 text-sm text-[#697687]">
            <p className="font-medium text-[#3d4b5c]">No matching supplies found.</p>
            <p className="mt-1">Try another word, or request it as a custom item.</p>
            <button
              type="button"
              disabled={controls.cartFull}
              onClick={() => {
                onAddCustom(query.trim());
                onQueryChange("");
              }}
              className="mt-3 inline-flex min-h-11 max-w-full items-center gap-2 rounded-xl border border-[#f56600] px-3.5 text-left font-semibold text-[#d95700] active:bg-[#fff3ea] disabled:opacity-50"
            >
              <PackagePlus className="size-4 shrink-0" aria-hidden="true" />
              <span className="min-w-0 [overflow-wrap:anywhere]">
                Request “{query.trim()}” as a custom item
              </span>
            </button>
          </div>
        )}
        {search.status === "results" && (
          <ProductList label="Search results">
            {search.results.map((product) => (
              <StaffProductRow key={product.resultId} product={product} {...controls} />
            ))}
          </ProductList>
        )}
      </div>

      {controls.cartFull && (
        <p role="status" className="mt-3 rounded-xl bg-[#f4f6f8] p-3 text-sm text-[#526174]">
          A request can hold up to 50 items. Submit this one and start another for the rest.
        </p>
      )}

      <div className="mt-4">
        <button
          type="button"
          aria-expanded={customOpen}
          aria-controls={`${inputId}-custom`}
          onClick={() => setCustomOpen((open) => !open)}
          className="min-h-11 py-2 text-sm font-semibold text-[#566477]"
        >
          Can't find the item?
        </button>
        {customOpen && (
          <div id={`${inputId}-custom`} className="mt-1 flex gap-2">
            <label htmlFor={`${inputId}-custom-name`} className="sr-only">
              Item name
            </label>
            <input
              id={`${inputId}-custom-name`}
              value={customItem}
              onChange={(event) => setCustomItem(event.target.value)}
              onKeyDown={(event) => {
                if (event.key !== "Enter") return;
                event.preventDefault();
                addItem();
              }}
              enterKeyHint="done"
              placeholder="Describe the item"
              maxLength={200}
              className="min-h-12 min-w-0 flex-1 rounded-xl border border-[#dce2e8] bg-white px-4 text-base outline-none focus:border-[#f56600] focus:ring-4 focus:ring-[#f56600]/10"
            />
            <button
              type="button"
              onClick={addItem}
              disabled={!customItem.trim() || controls.cartFull}
              className="min-h-12 shrink-0 rounded-xl border border-[#f56600] px-4 text-sm font-semibold text-[#d95700] active:bg-[#fff3ea] disabled:border-[#dce2e8] disabled:text-[#9aa3ad]"
            >
              Add to Request
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

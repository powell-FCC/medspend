import { createFileRoute, Link, useSearch } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Check, Minus, Plus, Search, X } from "lucide-react";
import { useEffect, useState } from "react";
import { z } from "zod";
import { useActiveOrg } from "@/hooks/use-active-org";
import { listOrgStructureFn } from "@/lib/org-structure.functions";
import {
  searchSupplyRequestProductsFn,
  submitSupplyRequestFn,
  type UnifiedSupplyRequestSearchResult,
} from "@/lib/supply-requests.functions";
import {
  cartContainsCustomItem,
  changeCartItemQuantity,
  createCustomCartItem,
  createStructuredCartItem,
  getStaffRequestProductDisplayLines,
  removeCartItem,
  resolveRequestContextId,
  toSubmissionItem,
  type StaffRequestCartItem,
} from "@/supply-requests/staff-request-cart";

const search = z.object({
  type: z.enum(["reorder", "low_stock", "out_of_stock", "new_item"]).optional(),
});

export const Route = createFileRoute("/_authenticated/staff/request")({
  validateSearch: (value) => search.parse(value),
  head: () => ({
    meta: [{ title: "Request supplies — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: RequestPage,
});

function useDebouncedValue<T>(value: T, delay: number) {
  const [debouncedValue, setDebouncedValue] = useState(value);

  useEffect(() => {
    const timeout = setTimeout(() => setDebouncedValue(value), delay);
    return () => clearTimeout(timeout);
  }, [delay, value]);

  return debouncedValue;
}

function ProductDetails({
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
    <span className="mt-1 block [overflow-wrap:anywhere]">
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

function RequestPage() {
  const { active } = useActiveOrg();
  const routeSearch = useSearch({ from: "/_authenticated/staff/request" });
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim();
  const debouncedQuery = useDebouncedValue(normalizedQuery, 300);
  const isDebouncedQueryReady = normalizedQuery.length >= 2 && normalizedQuery === debouncedQuery;
  const [selected, setSelected] = useState<UnifiedSupplyRequestSearchResult | null>(null);
  const [customItem, setCustomItem] = useState("");
  const [quantity, setQuantity] = useState(1);
  const [items, setItems] = useState<StaffRequestCartItem[]>([]);
  const [notes, setNotes] = useState("");
  const [teamId, setTeamId] = useState("");
  const [locationId, setLocationId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(false);
  const searchFn = useServerFn(searchSupplyRequestProductsFn);
  const submitFn = useServerFn(submitSupplyRequestFn);
  const listStructure = useServerFn(listOrgStructureFn);
  const queryClient = useQueryClient();
  const products = useQuery({
    queryKey: ["supply-request-products", active?.organizationId, debouncedQuery],
    queryFn: () =>
      searchFn({
        data: {
          organizationId: active!.organizationId,
          q: debouncedQuery,
          limit: 20,
        },
      }),
    enabled: !!active && isDebouncedQueryReady && !selected && !customItem.trim(),
  });
  const structure = useQuery({
    queryKey: ["org", active?.organizationId, "request-context"],
    queryFn: () =>
      listStructure({ data: { organizationId: active!.organizationId, includeArchived: false } }),
    enabled: !!active,
  });
  const teams = structure.data?.teams ?? [];
  const locations = structure.data?.locations ?? [];
  const hasActiveDefaultTeam =
    !!active?.defaultTeamId && teams.some((team) => team.id === active.defaultTeamId);
  const hasActiveDefaultLocation =
    !!active?.defaultLocationId &&
    locations.some((location) => location.id === active.defaultLocationId);
  const resolvedTeamId = resolveRequestContextId(active?.defaultTeamId, teamId, teams);
  const resolvedLocationId = resolveRequestContextId(
    active?.defaultLocationId,
    locationId,
    locations,
  );
  const showTeamSelector = !hasActiveDefaultTeam && teams.length > 1;
  const showLocationSelector = !hasActiveDefaultLocation && locations.length > 1;

  function addItem() {
    if (!Number.isInteger(quantity) || quantity <= 0) return;
    const item = selected
      ? createStructuredCartItem(crypto.randomUUID(), selected, quantity)
      : customItem.trim()
        ? createCustomCartItem(crypto.randomUUID(), customItem, quantity)
        : null;
    if (!item) return;
    setItems((current) => [...current, item]);
    setSelected(null);
    setCustomItem("");
    setQuery("");
    setQuantity(1);
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    if (!resolvedTeamId || !resolvedLocationId) {
      setError("A valid team and location are required. Ask an administrator to configure them.");
      return;
    }
    setBusy(true);
    try {
      await submitFn({
        data: {
          organizationId: active!.organizationId,
          requestType: routeSearch.type ?? (cartContainsCustomItem(items) ? "new_item" : "reorder"),
          items: items.map(toSubmissionItem),
          teamId: resolvedTeamId,
          locationId: resolvedLocationId,
          notes: notes.trim() || null,
        },
      });
      await queryClient.invalidateQueries({ queryKey: ["me", active?.organizationId, "requests"] });
      setSubmitted(true);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "We couldn't submit your request.");
    } finally {
      setBusy(false);
    }
  }

  if (submitted)
    return (
      <div className="flex min-h-[65dvh] flex-col items-center justify-center text-center">
        <span className="flex size-16 items-center justify-center rounded-full bg-[#edf7f1] text-[#286443]">
          <Check className="size-8" />
        </span>
        <h1 className="mt-6 text-2xl font-semibold tracking-tight">Request Submitted</h1>
        <p className="mt-2 max-w-xs text-sm leading-6 text-[#667384]">
          We'll update you when it is ready.
        </p>
        <Link
          to="/staff/requests"
          className="mt-8 flex min-h-12 w-full items-center justify-center rounded-xl bg-[#071d38] px-5 font-semibold text-white"
        >
          View My Requests
        </Link>
        <button
          type="button"
          onClick={() => {
            setSubmitted(false);
            setSelected(null);
            setItems([]);
            setCustomItem("");
            setQuery("");
            setQuantity(1);
            setNotes("");
          }}
          className="mt-3 min-h-12 w-full text-sm font-semibold text-[#d95700]"
        >
          Request another item
        </button>
      </div>
    );

  const hasItem = !!selected || !!customItem.trim();
  const isTypingSearch = normalizedQuery.length > 0 && !isDebouncedQueryReady;
  return (
    <div>
      <header>
        <p className="text-xs font-semibold uppercase tracking-[0.16em] text-[#697687]">
          New Request
        </p>
        <h1 className="mt-1 text-[1.7rem] font-semibold tracking-tight">What do you need?</h1>
      </header>
      <form onSubmit={submit} className="mt-7 space-y-7">
        {(showTeamSelector || showLocationSelector) && (
          <section className="grid gap-4">
            {showTeamSelector && (
              <label className="text-sm font-semibold">
                Team
                <select
                  aria-label="Team"
                  required
                  value={teamId}
                  onChange={(event) => setTeamId(event.target.value)}
                  className="mt-2 min-h-12 w-full rounded-xl border border-[#dce2e8] bg-white px-3 font-normal"
                >
                  <option value="">Select team</option>
                  {teams.map((team) => (
                    <option key={team.id} value={team.id}>
                      {team.name}
                    </option>
                  ))}
                </select>
              </label>
            )}
            {showLocationSelector && (
              <label className="text-sm font-semibold">
                Location
                <select
                  aria-label="Location"
                  required
                  value={locationId}
                  onChange={(event) => setLocationId(event.target.value)}
                  className="mt-2 min-h-12 w-full rounded-xl border border-[#dce2e8] bg-white px-3 font-normal"
                >
                  <option value="">Select location</option>
                  {locations.map((location) => (
                    <option key={location.id} value={location.id}>
                      {location.name}
                    </option>
                  ))}
                </select>
              </label>
            )}
          </section>
        )}
        <section>
          <label htmlFor="supply-search" className="text-sm font-semibold">
            Search supplies
          </label>
          {!selected ? (
            <>
              <div className="relative mt-2">
                <Search
                  className="absolute left-4 top-1/2 size-5 -translate-y-1/2 text-[#7b8693]"
                  aria-hidden="true"
                />
                <input
                  id="supply-search"
                  value={query}
                  onChange={(event) => {
                    setQuery(event.target.value);
                    setCustomItem("");
                  }}
                  placeholder="Tape, gloves, gauze…"
                  maxLength={120}
                  autoComplete="off"
                  className="min-h-14 w-full rounded-2xl border border-[#dce2e8] bg-white pl-12 pr-4 text-base shadow-sm outline-none placeholder:text-[#9aa3ad] focus:border-[#f56600] focus:ring-4 focus:ring-[#f56600]/10"
                />
              </div>
              {!customItem.trim() && (
                <div className="mt-2" aria-live="polite">
                  {!normalizedQuery && (
                    <p className="px-1 py-2 text-sm text-[#697687]">
                      Search by product name, size, manufacturer, vendor, or SKU.
                    </p>
                  )}
                  {isTypingSearch && (
                    <p className="px-1 py-2 text-sm text-[#697687]">
                      {normalizedQuery.length < 2
                        ? "Enter at least 2 characters to search."
                        : "Searching after you pause…"}
                    </p>
                  )}
                  {isDebouncedQueryReady && products.isFetching && (
                    <div role="status" className="space-y-2 py-1" aria-label="Searching supplies">
                      {[0, 1, 2].map((row) => (
                        <div
                          key={row}
                          className="h-16 animate-pulse rounded-2xl border border-[#e5e9ed] bg-white"
                        />
                      ))}
                    </div>
                  )}
                  {isDebouncedQueryReady && products.isError && !products.isFetching && (
                    <div
                      role="alert"
                      className="rounded-2xl border border-[#f1c8cc] bg-[#fff5f5] p-4 text-sm text-[#8d2d39]"
                    >
                      <p>We couldn't search supplies. Check your connection and try again.</p>
                      <button
                        type="button"
                        onClick={() => void products.refetch()}
                        className="mt-2 min-h-11 font-semibold text-[#a83340]"
                      >
                        Try search again
                      </button>
                    </div>
                  )}
                  {isDebouncedQueryReady &&
                    products.isSuccess &&
                    !products.isFetching &&
                    products.data.length === 0 && (
                      <div className="rounded-2xl border border-dashed border-[#cfd6de] bg-white/70 p-4 text-sm text-[#697687]">
                        <p className="font-medium text-[#3d4b5c]">No matching supplies found.</p>
                        <p className="mt-1">You can add a custom item below.</p>
                      </div>
                    )}
                  {isDebouncedQueryReady &&
                    products.isSuccess &&
                    !products.isFetching &&
                    products.data.length > 0 && (
                      <div
                        aria-label="Search results"
                        className="overflow-hidden rounded-2xl border border-[#dfe5eb] bg-white shadow-lg"
                      >
                        {products.data.map((product) => (
                          <button
                            key={product.resultId}
                            type="button"
                            onClick={() => {
                              setSelected(product);
                              setQuery("");
                            }}
                            className="block min-h-16 w-full border-b border-[#edf0f3] px-4 py-3 text-left last:border-0 hover:bg-[#f7f8fa] focus-visible:bg-[#f7f8fa] focus-visible:outline-none"
                          >
                            <span className="block font-medium text-[#071d38] [overflow-wrap:anywhere]">
                              {product.productName}
                            </span>
                            <ProductDetails product={product} />
                          </button>
                        ))}
                      </div>
                    )}
                </div>
              )}
              <details className="mt-4 group">
                <summary className="min-h-11 cursor-pointer list-none py-3 text-sm font-semibold text-[#566477]">
                  Can't find the item?
                </summary>
                <label htmlFor="custom-item" className="sr-only">
                  Item name
                </label>
                <input
                  id="custom-item"
                  value={customItem}
                  onChange={(event) => {
                    setCustomItem(event.target.value);
                    setQuery("");
                  }}
                  placeholder="Enter the item name"
                  maxLength={200}
                  className="min-h-14 w-full rounded-2xl border border-[#dce2e8] bg-white px-4 text-base outline-none focus:border-[#f56600] focus:ring-4 focus:ring-[#f56600]/10"
                />
              </details>
            </>
          ) : (
            <div className="mt-2 flex min-h-20 items-center justify-between rounded-2xl border border-[#dce2e8] bg-white p-4 shadow-sm">
              <div className="min-w-0">
                <div className="font-semibold [overflow-wrap:anywhere]">{selected.productName}</div>
                <ProductDetails product={selected} />
              </div>
              <button
                type="button"
                onClick={() => setSelected(null)}
                className="flex size-11 shrink-0 items-center justify-center rounded-full text-[#637080] hover:bg-[#f0f2f5]"
                aria-label="Change selected item"
              >
                <X className="size-5" />
              </button>
            </div>
          )}
        </section>

        {hasItem && (
          <>
            <section>
              <div className="text-sm font-semibold">Quantity</div>
              <div className="mt-2 flex items-center justify-between rounded-2xl border border-[#dce2e8] bg-white p-2 shadow-sm">
                <button
                  type="button"
                  onClick={() => setQuantity((value) => Math.max(1, value - 1))}
                  className="flex size-12 items-center justify-center rounded-xl bg-[#eef1f4]"
                  aria-label="Decrease quantity"
                >
                  <Minus className="size-5" />
                </button>
                <span className="text-xl font-semibold tabular-nums" aria-live="polite">
                  {quantity}
                </span>
                <button
                  type="button"
                  onClick={() => setQuantity((value) => value + 1)}
                  className="flex size-12 items-center justify-center rounded-xl bg-[#071d38] text-white"
                  aria-label="Increase quantity"
                >
                  <Plus className="size-5" />
                </button>
              </div>
            </section>
            <button
              type="button"
              onClick={addItem}
              className="min-h-12 w-full rounded-xl border border-[#f56600] font-semibold text-[#d95700]"
            >
              Add to Request
            </button>
          </>
        )}

        {items.length > 0 && (
          <>
            <section className="rounded-2xl border border-[#dce2e8] bg-white p-4">
              <h2 className="font-semibold text-[#071d38]">Your Request</h2>
              <div className="mt-3 divide-y divide-[#edf0f3]">
                {items.map((item) => (
                  <div key={item.key} className="flex flex-wrap items-center justify-end gap-3 py-3">
                    <div className="min-w-0 basis-full sm:flex-1 sm:basis-auto">
                      <div className="font-medium [overflow-wrap:anywhere]">{item.name}</div>
                      <div className="mt-1 text-sm text-[#697687]">Quantity {item.quantity}</div>
                      {item.kind === "structured" && <ProductDetails product={item} />}
                      {item.kind === "custom" && (
                        <div className="text-xs text-[#7b8693]">Custom item</div>
                      )}
                    </div>
                    <button
                      type="button"
                      onClick={() =>
                        setItems((current) => changeCartItemQuantity(current, item.key, -1))
                      }
                      aria-label={`Decrease ${item.name}`}
                      className="flex size-11 shrink-0 items-center justify-center rounded-lg bg-[#eef1f4]"
                    >
                      <Minus className="size-4" />
                    </button>
                    <button
                      type="button"
                      onClick={() =>
                        setItems((current) => changeCartItemQuantity(current, item.key, 1))
                      }
                      aria-label={`Increase ${item.name}`}
                      className="flex size-11 shrink-0 items-center justify-center rounded-lg bg-[#071d38] text-white"
                    >
                      <Plus className="size-4" />
                    </button>
                    <button
                      type="button"
                      onClick={() => setItems((current) => removeCartItem(current, item.key))}
                      aria-label={`Remove ${item.name}`}
                      className="flex size-11 shrink-0 items-center justify-center rounded-lg text-[#a83340]"
                    >
                      <X className="size-4" />
                    </button>
                  </div>
                ))}
              </div>
            </section>
            <section>
              <label htmlFor="request-note" className="text-sm font-semibold">
                Add a note <span className="font-normal text-[#7b8693]">(optional)</span>
              </label>
              <textarea
                id="request-note"
                rows={3}
                maxLength={5000}
                value={notes}
                onChange={(event) => setNotes(event.target.value)}
                placeholder="Size, location, or anything helpful"
                className="mt-2 w-full resize-none rounded-2xl border border-[#dce2e8] bg-white p-4 text-base outline-none placeholder:text-[#9aa3ad] focus:border-[#f56600] focus:ring-4 focus:ring-[#f56600]/10"
              />
            </section>
            {error && (
              <p role="alert" className="rounded-xl bg-[#fff0f1] p-3 text-sm text-[#a83340]">
                {error}
              </p>
            )}
            <button
              type="submit"
              disabled={busy}
              className="min-h-14 w-full rounded-2xl bg-[#f56600] px-5 text-base font-semibold text-white shadow-[0_10px_25px_rgba(245,102,0,0.22)] disabled:opacity-60"
            >
              {busy ? "Submitting…" : "Submit Request"}
            </button>
          </>
        )}
      </form>
    </div>
  );
}

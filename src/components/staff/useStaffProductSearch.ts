import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  getStaffProductDiscoveryFn,
  searchStaffProductsFn,
  setStaffProductSavedFn,
} from "@/lib/product-discovery.functions";
import { getStaffQuickPicksFn } from "@/lib/staff-workspace.functions";
import {
  effectiveSaved,
  savedIdentityFor,
  type StaffDiscoveryProduct,
  type StaffDiscoverySections,
} from "@/supply-requests/product-discovery";
import type { StaffQuickPicks } from "@/supply-requests/staff-workspace";

export function useDebouncedValue<T>(value: T, delay: number) {
  const [debouncedValue, setDebouncedValue] = useState(value);

  useEffect(() => {
    const timeout = setTimeout(() => setDebouncedValue(value), delay);
    return () => clearTimeout(timeout);
  }, [delay, value]);

  return debouncedValue;
}

export type StaffSearchState =
  | { status: "idle" }
  | { status: "short" }
  | { status: "typing" }
  | { status: "loading" }
  | { status: "error"; retry: () => void }
  | { status: "empty" }
  | { status: "results"; results: StaffDiscoveryProduct[] };

// The canonical staff search path (Phase 5A.10: search_supply_request_products_with_signals,
// the same ranking as search_supply_request_products plus Saved and organization history),
// debounced and bounded to 20 results. Nothing is fetched until two characters are typed.
export function useStaffProductSearch(
  organizationId: string | undefined,
  query: string,
): StaffSearchState {
  const searchFn = useServerFn(searchStaffProductsFn);
  const normalizedQuery = query.trim();
  const debouncedQuery = useDebouncedValue(normalizedQuery, 300);
  const isDebouncedQueryReady = normalizedQuery.length >= 2 && normalizedQuery === debouncedQuery;
  const products = useQuery({
    queryKey: ["supply-request-products", organizationId, debouncedQuery],
    queryFn: () =>
      searchFn({ data: { organizationId: organizationId!, q: debouncedQuery, limit: 20 } }),
    enabled: !!organizationId && isDebouncedQueryReady,
  });

  if (!normalizedQuery) return { status: "idle" };
  if (normalizedQuery.length < 2) return { status: "short" };
  if (!isDebouncedQueryReady) return { status: "typing" };
  if (products.isFetching) return { status: "loading" };
  if (products.isError) return { status: "error", retry: () => void products.refetch() };
  if (!products.data || products.data.length === 0) return { status: "empty" };
  return { status: "results", results: products.data };
}

export type StaffQuickPicksState =
  | { status: "loading" }
  | { status: "error"; retry: () => void }
  | { status: "ready"; picks: StaffQuickPicks };

export function useStaffQuickPicks(organizationId: string | undefined): StaffQuickPicksState {
  const fetchQuickPicks = useServerFn(getStaffQuickPicksFn);
  const quickPicks = useQuery({
    queryKey: ["me", organizationId, "quick-picks"],
    queryFn: () => fetchQuickPicks({ data: { organizationId: organizationId! } }),
    enabled: !!organizationId,
    staleTime: 60_000,
  });
  if (quickPicks.isError) return { status: "error", retry: () => void quickPicks.refetch() };
  if (!quickPicks.data) return { status: "loading" };
  return { status: "ready", picks: quickPicks.data };
}

export type StaffDiscoveryState =
  | { status: "loading" }
  | { status: "error"; retry: () => void }
  | { status: "ready"; sections: StaffDiscoverySections };

// Phase 5A.10 Request Supplies start: Saved items, Frequently requested, Purchased before.
export function useStaffProductDiscovery(organizationId: string | undefined): StaffDiscoveryState {
  const fetchDiscovery = useServerFn(getStaffProductDiscoveryFn);
  const discovery = useQuery({
    queryKey: ["me", organizationId, "product-discovery"],
    queryFn: () => fetchDiscovery({ data: { organizationId: organizationId! } }),
    enabled: !!organizationId,
    staleTime: 30_000,
  });
  if (discovery.isError) return { status: "error", retry: () => void discovery.refetch() };
  if (!discovery.data) return { status: "loading" };
  return { status: "ready", sections: discovery.data };
}

export type StaffSavedControls = {
  isSaved: (product: StaffDiscoveryProduct) => boolean;
  isPending: (product: StaffDiscoveryProduct) => boolean;
  toggle: (product: StaffDiscoveryProduct) => void;
  error: string | null;
};

// Save / remove from Saved Items. The new state shows at once and stays put: search results
// are never re-ordered under the person's thumb (the saved boost applies to the next search),
// and the start sections refresh in the background.
export function useStaffSavedProducts(organizationId: string | undefined): StaffSavedControls {
  const setSavedFn = useServerFn(setStaffProductSavedFn);
  const queryClient = useQueryClient();
  const [overrides, setOverrides] = useState<ReadonlyMap<string, boolean>>(new Map());
  const [pending, setPending] = useState<ReadonlySet<string>>(new Set());
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(new Set<string>());

  const toggle = useCallback(
    (product: StaffDiscoveryProduct) => {
      const identity = savedIdentityFor(product);
      if (!organizationId || !identity || inFlight.current.has(product.resultId)) return;
      const next = !effectiveSaved(product, overrides);
      inFlight.current.add(product.resultId);
      setError(null);
      setPending((current) => new Set(current).add(product.resultId));
      setOverrides((current) => new Map(current).set(product.resultId, next));
      void setSavedFn({ data: { organizationId, ...identity, saved: next } })
        .then(() =>
          queryClient.invalidateQueries({ queryKey: ["me", organizationId, "product-discovery"] }),
        )
        .catch((caught: unknown) => {
          setOverrides((current) => new Map(current).set(product.resultId, !next));
          setError(
            caught instanceof Error && caught.message
              ? caught.message
              : "We couldn't update your saved items.",
          );
        })
        .finally(() => {
          inFlight.current.delete(product.resultId);
          setPending((current) => {
            const copy = new Set(current);
            copy.delete(product.resultId);
            return copy;
          });
        });
    },
    [organizationId, overrides, queryClient, setSavedFn],
  );

  return {
    isSaved: (product) => effectiveSaved(product, overrides),
    isPending: (product) => pending.has(product.resultId),
    toggle,
    error,
  };
}

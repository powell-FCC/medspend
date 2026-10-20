import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useEffect, useState } from "react";
import {
  searchSupplyRequestProductsFn,
  type UnifiedSupplyRequestSearchResult,
} from "@/lib/supply-requests.functions";
import { getStaffQuickPicksFn } from "@/lib/staff-workspace.functions";
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
  | { status: "results"; results: UnifiedSupplyRequestSearchResult[] };

// The canonical staff search path (search_supply_request_products), debounced and
// bounded to 20 results. Nothing is fetched until two characters have been typed.
export function useStaffProductSearch(
  organizationId: string | undefined,
  query: string,
): StaffSearchState {
  const searchFn = useServerFn(searchSupplyRequestProductsFn);
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

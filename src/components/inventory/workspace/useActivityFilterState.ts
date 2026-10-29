import { useState } from "react";
import { activityDateRange, type AdjustmentHistoryReason } from "@/inventory/activity";
import type { ActivityFilters } from "@/types/inventory-workspace";

// Filter state for one Activity list. Each list (Transfers, Adjustments) keeps its own, so
// switching between them never resets or mixes their pages.
export function useActivityFilterState(locationId?: string) {
  const [location, setLocation] = useState("");
  const [item, setItem] = useState<{ id: string; name: string } | null>(null);
  const [person, setPerson] = useState("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [reason, setReason] = useState("");
  const range = activityDateRange(from, to);
  const filters: ActivityFilters = {
    locationId: locationId ?? (location || null),
    itemId: item?.id ?? null,
    createdBy: person || null,
    createdFrom: range.createdFrom,
    createdBefore: range.createdBefore,
  };
  return {
    values: { location, item, person, from, to, reason },
    set: { setLocation, setItem, setPerson, setFrom, setTo, setReason },
    filters,
    // The select only offers adjustmentHistoryReasons.
    reason: (reason || null) as AdjustmentHistoryReason | null,
    invalidRange: Boolean(from && to && from > to),
    filtered: Boolean((!locationId && location) || item || person || from || to || reason),
  };
}

export type ActivityFilterState = ReturnType<typeof useActivityFilterState>;

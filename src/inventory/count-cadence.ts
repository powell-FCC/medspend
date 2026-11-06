import type {
  CountFreshnessState,
  CountPolicy,
  LocationCountFreshness,
} from "@/types/inventory-workspace";

// Phase 7B.5 count cadence: what the screens say about it. Every state is decided once, in
// the database (inventory_location_count_freshness); nothing here recomputes it. Count age is
// operational freshness, not a judgement about whether stock is right.

export const COUNT_CADENCE_EXPLAINER =
  "Set how often physical storage locations should be counted. This does not track day-to-day consumption; it identifies when a new physical reconciliation is due.";

export const MIN_INTERVAL_DAYS = 1;
export const MAX_INTERVAL_DAYS = 365;
export const SUGGESTED_INTERVALS = [7, 14, 30, 60, 90] as const;

export const freshnessStateLabel: Record<CountFreshnessState, string> = {
  not_applicable: "Not scheduled",
  nothing_to_count: "Nothing to count",
  never_counted: "Never counted",
  counted: "Counted",
  current: "Current",
  due: "Due",
  overdue: "Overdue",
};

// Tones for the state badge. Neutral except the two cadence states that ask for a count.
export const freshnessStateTone: Record<CountFreshnessState, string> = {
  not_applicable: "border-transparent bg-muted text-muted-foreground",
  nothing_to_count: "border-transparent bg-muted text-muted-foreground",
  never_counted: "border-transparent bg-muted text-foreground",
  counted: "border-transparent bg-muted text-foreground",
  current: "border-transparent bg-emerald-100 text-emerald-900",
  due: "border-transparent bg-amber-100 text-amber-900",
  overdue: "border-transparent bg-orange-200 text-orange-950",
};

export function cadenceLabel(policy: Pick<CountPolicy, "enabled" | "intervalDays">): string {
  if (!policy.enabled || !policy.intervalDays) return "Off";
  return policy.intervalDays === 1 ? "Every day" : `Every ${policy.intervalDays} days`;
}

// The owner's typed interval: a whole number of days in range, or a reason it is not. Never
// rounded or clamped into range.
export function parseIntervalDays(
  input: string,
): { ok: true; value: number } | { ok: false; error: string } {
  const text = input.trim();
  if (!/^\d+$/.test(text))
    return { ok: false, error: "Enter a whole number of days between 1 and 365." };
  const value = Number(text);
  if (value < MIN_INTERVAL_DAYS || value > MAX_INTERVAL_DAYS)
    return { ok: false, error: "Count every 1 to 365 days." };
  return { ok: true, value };
}

export function formatCadenceDate(iso: string | null): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

// One factual line for a storage location's schedule; null where cadence says nothing.
export function locationScheduleLine(freshness: LocationCountFreshness): string | null {
  switch (freshness.state) {
    case "current":
      return `Next count due ${formatCadenceDate(freshness.nextDueAt)}`;
    case "due":
      return `Count due since ${formatCadenceDate(freshness.nextDueAt)}`;
    case "overdue":
      return `Count was due ${formatCadenceDate(freshness.nextDueAt)}`;
    case "never_counted":
      return "Not counted yet";
    default:
      return null;
  }
}

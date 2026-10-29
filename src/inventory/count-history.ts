import { formatQuantity } from "./locations.ts";
import type { CountCorrectionUnit, CountSessionLine } from "@/types/inventory-workspace";

// Phase 7B.2 count history rules shared by the UI and tests. A physical count replaces the
// recorded quantity with what is on hand; differences are count corrections, nothing more.

export const COUNT_HISTORY_EXPLAINER =
  "A physical count replaces SportSpend's recorded quantity with what is actually on hand. Differences are shown as count corrections and may reflect routine use that staff are not required to log.";

// Units are shown exactly as recorded at count time, as everywhere else in inventory. No
// plural forms, conversions or package equivalents are invented.
export function displayUnit(unit: string | null | undefined): string {
  const trimmed = (unit ?? "").trim();
  return trimmed || "units";
}

// "+3", "-2", "0", "-0.25". Exact to the six decimals counts accept.
export function formatSignedQuantity(value: number): string {
  const text = formatQuantity(value);
  if (text === "0" || text === "-0") return "0";
  return value > 0 ? `+${text}` : text;
}

function compareUnits(a: string, b: string) {
  return a < b ? -1 : a > b ? 1 : 0;
}

// One part per unit, never one total across units: "-4 each · +1 roll". A unit whose
// corrections cancel out says so: "net 0 each (+2 / -2)".
export function formatCorrectionSummary(units: CountCorrectionUnit[]): string {
  const parts = [...units]
    .filter((unit) => unit.changedLines > 0)
    .sort((a, b) => compareUnits(a.unit, b.unit))
    .map((unit) => {
      const name = displayUnit(unit.unit);
      if (formatSignedQuantity(unit.netDelta) !== "0")
        return `${formatSignedQuantity(unit.netDelta)} ${name}`;
      return `net 0 ${name} (${formatSignedQuantity(unit.increase)} / ${formatSignedQuantity(unit.decrease)})`;
    });
  return parts.length ? parts.join(" · ") : "No corrections";
}

export function correctionCountLabel(changedCount: number): string {
  if (changedCount === 0) return "No corrections";
  return `${changedCount} correction${changedCount === 1 ? "" : "s"}`;
}

export function countHistoryEmptyMessage({
  filtered,
  forLocation,
}: {
  filtered: boolean;
  forLocation: boolean;
}) {
  if (filtered) return "No counts match these filters.";
  return forLocation
    ? "No physical counts have been submitted for this location yet."
    : "No physical counts have been submitted yet.";
}

// Changed lines first, then lines that matched the recorded quantity. The server already
// orders them this way; this keeps the split explicit and stable.
export function splitCountLines(lines: CountSessionLine[]) {
  return {
    changed: lines.filter((line) => line.delta !== 0),
    unchanged: lines.filter((line) => line.delta === 0),
  };
}

// Date inputs (YYYY-MM-DD) to the server's half-open range in the viewer's time zone: from
// the start of the first day to the start of the day after the last.
export function countDateRange(from: string, to: string) {
  const start = (value: string, addDays = 0) => {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
    if (!match) return null;
    return new Date(
      Number(match[1]),
      Number(match[2]) - 1,
      Number(match[3]) + addDays,
    ).toISOString();
  };
  return { submittedFrom: start(from), submittedBefore: start(to, 1) };
}

export function formatCountDateTime(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

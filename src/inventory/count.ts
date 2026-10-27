// Physical count helpers. A count is a complete snapshot of one storage location: every item
// shown is confirmed, and the database records each one, unchanged ones included. Quantities
// stay decimal strings end to end so 2.75 never becomes 2.7499999.

export interface CountItem {
  inventoryItemId: string;
  name: string;
  sku: string | null;
  manufacturer: string | null;
  unit: string;
  quantity: string;
  version: number;
  archived: boolean;
}

export interface CountLocation {
  id: string;
  name: string;
  lastCountedAt: string | null;
}

export interface CountPage {
  location: CountLocation;
  items: CountItem[];
}

export interface CountSubmissionLine {
  inventoryItemId: string;
  observedVersion: number;
  countedQuantity: string;
}

export interface CountSummary {
  sessionId: string;
  locationId: string;
  locationName: string;
  submittedAt: string;
  lineCount: number;
  changedCount: number;
  replayed: boolean;
}

export type LabelResolution =
  | { status: "available"; organizationId: string; locationId: string; locationName: string }
  | { status: "unavailable" | "replaced" | "location_unavailable" };

export type AvailableLabel = Extract<LabelResolution, { status: "available" }>;

export function availableLabel(resolution: LabelResolution | undefined): AvailableLabel | null {
  return resolution?.status === "available" ? (resolution as AvailableLabel) : null;
}

export const MAX_COUNT_QUANTITY = 1_000_000_000;
export const MAX_COUNT_DECIMALS = 6;
export const COUNT_STALE_MESSAGE =
  "Inventory changed while you were counting. Reload this location and confirm the quantities again.";

// Canonical decimal text: no leading zeros, no trailing fractional zeros ("3.000" -> "3").
export function canonicalQuantity(value: string | number): string {
  const text = typeof value === "number" ? String(value) : value.trim();
  const [whole, fraction = ""] = text.split(".");
  const trimmedWhole = whole.replace(/^0+(?=\d)/, "") || "0";
  const trimmedFraction = fraction.replace(/0+$/, "");
  return trimmedFraction ? `${trimmedWhole}.${trimmedFraction}` : trimmedWhole;
}

export type ParsedQuantity = { ok: true; value: string } | { ok: false; error: string };

// What a person typed into a physical-quantity field. A decimal comma is accepted. A blank
// field is an error: it never means zero, unchanged or skipped.
export function parseCountQuantity(input: string): ParsedQuantity {
  let text = input.trim();
  if (!text) return { ok: false, error: "Enter a quantity (0 if there is none)." };
  if (/^\d+,\d+$/.test(text)) text = text.replace(",", ".");
  if (text.startsWith("-")) return { ok: false, error: "Quantities can't be negative." };
  if (!/^\d+(\.\d*)?$|^\.\d+$/.test(text)) return { ok: false, error: "Enter a number." };
  if (text.startsWith(".")) text = `0${text}`;
  if (text.endsWith(".")) text = text.slice(0, -1);
  const value = canonicalQuantity(text);
  const decimals = value.split(".")[1]?.length ?? 0;
  if (decimals > MAX_COUNT_DECIMALS) {
    return { ok: false, error: `Use at most ${MAX_COUNT_DECIMALS} decimal places.` };
  }
  if (value.split(".")[0].length > 10 || Number(value) > MAX_COUNT_QUANTITY) {
    return { ok: false, error: "That quantity is too large." };
  }
  return { ok: true, value };
}

// Exact decimal arithmetic on canonical strings, scaled to integers.
function toScaled(value: string): bigint {
  const [whole, fraction = ""] = canonicalQuantity(value).split(".");
  return BigInt(whole) * 10n ** 6n + BigInt(fraction.padEnd(6, "0").slice(0, 6) || "0");
}
function fromScaled(scaled: bigint): string {
  const negative = scaled < 0n;
  const absolute = negative ? -scaled : scaled;
  const whole = absolute / 10n ** 6n;
  const fraction = (absolute % 10n ** 6n).toString().padStart(6, "0").replace(/0+$/, "");
  return `${negative ? "-" : ""}${whole}${fraction ? `.${fraction}` : ""}`;
}

export function quantityDelta(from: string, to: string): string {
  return fromScaled(toScaled(to) - toScaled(from));
}

// One step of the +/- control. Never below zero; fractional values step by whole units.
export function stepCountQuantity(current: string, step: 1 | -1): string {
  const parsed = parseCountQuantity(current);
  const base = parsed.ok ? toScaled(parsed.value) : 0n;
  const next = base + BigInt(step) * 10n ** 6n;
  return fromScaled(next < 0n ? 0n : next);
}

export function formatSignedDelta(delta: string): string {
  return delta.startsWith("-") ? `−${delta.slice(1)}` : `+${delta}`;
}

export interface CountReview {
  changed: Array<{ item: CountItem; counted: string; delta: string }>;
  unchanged: number;
  errors: Record<string, string>;
  complete: boolean;
}

// Where the count stands: which lines differ from the system, and which fields are invalid.
// complete means every field holds a valid quantity, so the count can be saved.
export function reviewCount(items: CountItem[], entries: Record<string, string>): CountReview {
  const changed: CountReview["changed"] = [];
  const errors: Record<string, string> = {};
  let unchanged = 0;
  for (const item of items) {
    const parsed = parseCountQuantity(entries[item.inventoryItemId] ?? "");
    if (!parsed.ok) {
      errors[item.inventoryItemId] = parsed.error;
      continue;
    }
    const delta = quantityDelta(item.quantity, parsed.value);
    if (delta === "0") unchanged += 1;
    else changed.push({ item, counted: parsed.value, delta });
  }
  return {
    changed,
    unchanged,
    errors,
    complete: items.length > 0 && Object.keys(errors).length === 0,
  };
}

// Fields start at the system quantity: staff change only what doesn't match the shelf.
export function initialCountEntries(items: CountItem[]): Record<string, string> {
  return Object.fromEntries(
    items.map((item) => [item.inventoryItemId, canonicalQuantity(item.quantity)]),
  );
}

export function buildCountSubmission(
  items: CountItem[],
  entries: Record<string, string>,
): CountSubmissionLine[] {
  return items.map((item) => {
    const parsed = parseCountQuantity(entries[item.inventoryItemId] ?? "");
    if (!parsed.ok) throw new Error(parsed.error);
    return {
      inventoryItemId: item.inventoryItemId,
      observedVersion: item.version,
      countedQuantity: parsed.value,
    };
  });
}

// The page a count form was started from. A save is checked against the versions staff were
// shown, so a background refetch (an auth refresh invalidating every query, say) never swaps
// the form's items, entries or versions: only data loaded after an explicit reload does.
export interface PinnedCountPage {
  page: CountPage;
  loadedAt: number;
}

export function nextPinnedCountPage(
  pinned: PinnedCountPage | null,
  latest: { page: CountPage | undefined; loadedAt: number },
  reloadRequestedAt: number | null,
): PinnedCountPage | null {
  if (!latest.page) return pinned;
  if (!pinned) return { page: latest.page, loadedAt: latest.loadedAt };
  if (
    reloadRequestedAt !== null &&
    latest.loadedAt >= reloadRequestedAt &&
    latest.loadedAt !== pinned.loadedAt
  )
    return { page: latest.page, loadedAt: latest.loadedAt };
  return pinned;
}

export type CountErrorKind = "stale" | "unavailable" | "forbidden" | "other";

export function countErrorKind(message: string): CountErrorKind {
  if (message.includes("Inventory changed while you were counting")) return "stale";
  if (message.includes("not available for counting")) return "unavailable";
  if (message.includes("Forbidden")) return "forbidden";
  return "other";
}

const labelMessages: Record<Exclude<LabelResolution["status"], "available">, string> = {
  unavailable:
    "This inventory label isn't available. Check that you're signed in to the right account.",
  replaced: "This label has been replaced. Ask an owner for the location's current QR label.",
  location_unavailable: "This inventory location isn't open for counting right now.",
};

export function labelUnavailableMessage(
  status: Exclude<LabelResolution["status"], "available">,
): string {
  return labelMessages[status];
}

// A scanned code counts only when it is a count link (or a bare token). The scanner takes
// the token out and opens it inside this app; it never follows the scanned URL, so a label
// printed on either production host works and any other QR code is ignored.
export function countTokenFromScan(raw: string): string | null {
  const text = raw.trim();
  if (/^[A-Za-z0-9_-]{43}$/.test(text)) return text;
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  const match = /^\/count\/([A-Za-z0-9_-]{43})\/?$/.exec(url.pathname);
  return match ? match[1] : null;
}

export function countLabelUrl(origin: string, token: string): string {
  return `${origin}/count/${token}`;
}

export function newCountRequestKey(): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto
    ? `count-${crypto.randomUUID()}`
    : `count-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

import { AlertTriangle, Archive, CheckCircle2, Loader2, Minus, Plus, RotateCw } from "lucide-react";
import { useMemo, useRef, useState } from "react";
import {
  buildCountSubmission,
  COUNT_STALE_MESSAGE,
  countErrorKind,
  formatSignedDelta,
  initialCountEntries,
  newCountRequestKey,
  reviewCount,
  stepCountQuantity,
  type CountItem,
  type CountPage,
  type CountReview,
  type CountSubmissionLine,
  type CountSummary,
} from "@/inventory/count";

const dateTime = (iso: string) =>
  new Date(iso).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });

export function CountHeader({
  name,
  lastCountedAt,
}: {
  name: string;
  lastCountedAt: string | null;
}) {
  return (
    <header className="pr-16">
      <p className="text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-[#5c6878]">
        Physical inventory count
      </p>
      <h1 className="mt-1 break-words text-[1.6rem] font-semibold tracking-[-0.03em] text-[#071d38]">
        {name}
      </h1>
      <p className="mt-0.5 text-sm text-[#697687]">
        {lastCountedAt ? `Last counted ${dateTime(lastCountedAt)}` : "Not counted yet"}
      </p>
    </header>
  );
}

export function CountItemRow({
  item,
  value,
  error,
  onChange,
}: {
  item: CountItem;
  value: string;
  error?: string;
  onChange: (value: string) => void;
}) {
  const inputId = `count-${item.inventoryItemId}`;
  const errorId = `${inputId}-error`;
  return (
    <li
      className="rounded-2xl border border-[#e1e6ec] bg-white p-3.5"
      data-count-item={item.inventoryItemId}
    >
      <div className="flex min-w-0 items-start justify-between gap-3">
        <div className="min-w-0">
          <label
            htmlFor={inputId}
            className="block break-words font-semibold leading-snug text-[#071d38]"
          >
            {item.name}
          </label>
          <p className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-[#697687]">
            {item.sku && <span className="font-mono">{item.sku}</span>}
            <span>{item.unit}</span>
            {item.archived && (
              <span className="inline-flex items-center gap-1 rounded-full bg-[#f1f3f5] px-2 py-0.5 font-medium text-[#4d5b6c]">
                <Archive className="size-3" aria-hidden="true" />
                Archived
              </span>
            )}
          </p>
        </div>
        <p className="shrink-0 text-right text-xs text-[#697687]">
          System
          <span className="block text-base font-semibold tabular-nums text-[#344256]">
            {item.quantity}
          </span>
        </p>
      </div>
      <div className="mt-3 flex items-center gap-2">
        <span className="w-16 shrink-0 text-xs font-medium text-[#4d5b6c]">Physical</span>
        <div className="flex min-w-0 flex-1 items-center rounded-xl border border-[#dce2e8] bg-white focus-within:border-[#d95700] focus-within:ring-2 focus-within:ring-[#d95700]/20">
          <button
            type="button"
            onClick={() => onChange(stepCountQuantity(value, -1))}
            aria-label={`Decrease ${item.name}`}
            className="flex size-11 shrink-0 items-center justify-center rounded-l-xl text-[#344256] active:bg-[#eef1f4]"
          >
            <Minus className="size-4" aria-hidden="true" />
          </button>
          <input
            id={inputId}
            type="text"
            inputMode="decimal"
            autoComplete="off"
            enterKeyHint="next"
            value={value}
            onChange={(event) => onChange(event.target.value)}
            aria-invalid={error ? true : undefined}
            aria-describedby={error ? errorId : undefined}
            className="h-11 w-full min-w-0 bg-transparent text-center text-lg font-semibold tabular-nums text-[#071d38] outline-none"
          />
          <button
            type="button"
            onClick={() => onChange(stepCountQuantity(value, 1))}
            aria-label={`Increase ${item.name}`}
            className="flex size-11 shrink-0 items-center justify-center rounded-r-xl text-[#071d38] active:bg-[#eef1f4]"
          >
            <Plus className="size-4" aria-hidden="true" />
          </button>
        </div>
      </div>
      {error && (
        <p id={errorId} className="mt-1.5 text-sm text-[#a83340]">
          {error}
        </p>
      )}
    </li>
  );
}

export function CountConfirmation({
  review,
  total,
  saving,
  onConfirm,
  onCancel,
}: {
  review: CountReview;
  total: number;
  saving: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-labelledby="count-confirm-title"
      className="fixed inset-0 z-50 flex items-end justify-center bg-[#071d38]/40 sm:items-center sm:p-6"
    >
      <div className="max-h-[88dvh] w-full max-w-md overflow-y-auto rounded-t-3xl bg-white p-5 pb-[max(1.25rem,env(safe-area-inset-bottom))] shadow-xl sm:rounded-3xl">
        <h2 id="count-confirm-title" className="text-lg font-semibold text-[#071d38]">
          Save this count?
        </h2>
        <p className="mt-1 text-sm text-[#4d5b6c]">
          You checked all {total} item{total === 1 ? "" : "s"} here.{" "}
          {review.changed.length === 0
            ? "Every quantity matches the system."
            : `${review.changed.length} quantit${review.changed.length === 1 ? "y" : "ies"} will change; ${review.unchanged} stay the same.`}
        </p>
        {review.changed.length > 0 && (
          <ul
            className="mt-3 divide-y rounded-2xl border border-[#e1e6ec]"
            data-testid="changed-items"
          >
            {review.changed.map(({ item, counted, delta }) => (
              <li
                key={item.inventoryItemId}
                className="flex items-center justify-between gap-3 px-3.5 py-2.5 text-sm"
              >
                <span className="min-w-0 break-words text-[#071d38]">{item.name}</span>
                <span className="shrink-0 text-right tabular-nums text-[#4d5b6c]">
                  {item.quantity} → <span className="font-semibold text-[#071d38]">{counted}</span>{" "}
                  <span className={delta.startsWith("-") ? "text-[#a83340]" : "text-[#1d7a46]"}>
                    ({formatSignedDelta(delta)})
                  </span>
                </span>
              </li>
            ))}
          </ul>
        )}
        <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <button
            type="button"
            onClick={onCancel}
            disabled={saving}
            className="min-h-12 rounded-2xl border border-[#dce2e8] px-5 font-semibold text-[#344256] active:bg-[#f2f4f6]"
          >
            Keep counting
          </button>
          <button
            type="button"
            onClick={onConfirm}
            disabled={saving}
            className="inline-flex min-h-12 items-center justify-center gap-2 rounded-2xl bg-[#d95700] px-5 font-semibold text-white active:bg-[#bf4c00] disabled:opacity-70"
          >
            {saving && <Loader2 className="size-4 animate-spin" aria-hidden="true" />}
            {saving ? "Saving…" : "Save count"}
          </button>
        </div>
      </div>
    </div>
  );
}

export function CountStale({ onReload }: { onReload: () => void }) {
  return (
    <div
      role="alert"
      className="rounded-2xl border border-[#f1d3bf] bg-[#fff8f2] p-4"
      data-count-state="stale"
    >
      <p className="flex items-center gap-2 font-semibold text-[#8a3b00]">
        <AlertTriangle className="size-4 shrink-0" aria-hidden="true" />
        Inventory changed
      </p>
      <p className="mt-1 text-sm text-[#6b4a33]">{COUNT_STALE_MESSAGE}</p>
      <button
        type="button"
        onClick={onReload}
        className="mt-3 inline-flex min-h-11 items-center gap-2 rounded-xl bg-[#8a3b00] px-4 text-sm font-semibold text-white active:bg-[#733100]"
      >
        <RotateCw className="size-4" aria-hidden="true" />
        Reload this location
      </button>
    </div>
  );
}

export function CountSuccess({
  summary,
  onDone,
  onBack,
  backLabel = "Back to Staff Workspace",
}: {
  summary: CountSummary;
  onDone: () => void;
  onBack: () => void;
  backLabel?: string;
}) {
  return (
    <section className="space-y-5" aria-labelledby="count-saved-title" data-count-state="saved">
      <p className="pr-16 text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-[#5c6878]">
        Physical inventory count
      </p>
      <div className="rounded-3xl border border-[#cfe6d8] bg-[#f3fbf6] p-5 text-center">
        <CheckCircle2 className="mx-auto size-10 text-[#1d7a46]" aria-hidden="true" />
        <h1 id="count-saved-title" className="mt-2 text-xl font-semibold text-[#071d38]">
          Inventory count saved
        </h1>
        <p className="mt-1 break-words text-sm text-[#4d5b6c]">{summary.locationName}</p>
      </div>
      <dl className="grid grid-cols-2 gap-3 text-sm">
        <div className="rounded-2xl border border-[#e1e6ec] bg-white p-3.5">
          <dt className="text-[#697687]">Items counted</dt>
          <dd className="mt-0.5 text-xl font-semibold tabular-nums text-[#071d38]">
            {summary.lineCount}
          </dd>
        </div>
        <div className="rounded-2xl border border-[#e1e6ec] bg-white p-3.5">
          <dt className="text-[#697687]">Adjusted</dt>
          <dd className="mt-0.5 text-xl font-semibold tabular-nums text-[#071d38]">
            {summary.changedCount}
          </dd>
        </div>
        <div className="col-span-2 rounded-2xl border border-[#e1e6ec] bg-white p-3.5">
          <dt className="text-[#697687]">Saved</dt>
          <dd className="mt-0.5 font-semibold text-[#071d38]">{dateTime(summary.submittedAt)}</dd>
        </div>
      </dl>
      <div className="flex flex-col gap-2">
        <button
          type="button"
          onClick={onDone}
          className="min-h-12 rounded-2xl bg-[#071d38] px-5 font-semibold text-white active:bg-[#0d2a4d]"
        >
          Done
        </button>
        <button
          type="button"
          onClick={onBack}
          className="min-h-12 rounded-2xl border border-[#dce2e8] bg-white px-5 font-semibold text-[#344256] active:bg-[#f2f4f6]"
        >
          {backLabel}
        </button>
      </div>
    </section>
  );
}

// The whole count: every item starts at its system quantity; staff change what doesn't
// match the shelf, review the changes, and save once. One request key per page load makes a
// retried save replay instead of counting twice.
export function InventoryCountForm({
  page,
  onSubmit,
  onReload,
  onDone,
  onBack,
  backLabel = "Back to Staff Workspace",
  initialPhase = "editing",
  initialEntries,
}: {
  page: CountPage;
  onSubmit: (lines: CountSubmissionLine[], requestKey: string) => Promise<CountSummary>;
  onReload: () => void;
  onDone: () => void;
  onBack: () => void;
  backLabel?: string;
  initialPhase?: "editing" | "confirming" | "stale";
  initialEntries?: Record<string, string>;
}) {
  const [entries, setEntries] = useState<Record<string, string>>(
    () => initialEntries ?? initialCountEntries(page.items),
  );
  const [phase, setPhase] = useState<"editing" | "confirming" | "stale">(initialPhase);
  const [showErrors, setShowErrors] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [summary, setSummary] = useState<CountSummary | null>(null);
  const requestKey = useRef(newCountRequestKey());
  // Guards a second tap that lands before React re-renders the disabled button.
  const submitting = useRef(false);
  const review = useMemo(() => reviewCount(page.items, entries), [page.items, entries]);

  if (summary)
    return <CountSuccess summary={summary} onDone={onDone} onBack={onBack} backLabel={backLabel} />;

  if (page.items.length === 0) {
    return (
      <div className="space-y-5">
        <CountHeader name={page.location.name} lastCountedAt={page.location.lastCountedAt} />
        <div
          className="rounded-2xl border border-dashed border-[#cfd6de] bg-white p-6 text-center"
          data-count-state="empty"
        >
          <p className="font-semibold text-[#071d38]">Nothing is stocked here</p>
          <p className="mt-1 text-sm text-[#697687]">
            No items are recorded at this location, so there's nothing to count. If you see stock
            here, let an owner know so it can be placed.
          </p>
        </div>
        <button
          type="button"
          onClick={onBack}
          className="min-h-12 w-full rounded-2xl border border-[#dce2e8] bg-white px-5 font-semibold text-[#344256]"
        >
          {backLabel}
        </button>
      </div>
    );
  }

  const submit = async () => {
    if (submitting.current) return;
    submitting.current = true;
    setSaving(true);
    setError(null);
    try {
      setSummary(await onSubmit(buildCountSubmission(page.items, entries), requestKey.current));
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : "Could not save the count.";
      if (countErrorKind(message) === "stale") setPhase("stale");
      else {
        setError(message);
        setPhase("editing");
      }
    } finally {
      submitting.current = false;
      setSaving(false);
    }
  };

  return (
    <div className="space-y-5 pb-28">
      <CountHeader name={page.location.name} lastCountedAt={page.location.lastCountedAt} />
      {phase === "stale" ? (
        <CountStale onReload={onReload} />
      ) : (
        <p className="rounded-2xl bg-[#eef3f8] px-4 py-3 text-sm text-[#344256]">
          Check every item on the shelf. Each one starts at the system quantity: change anything
          that doesn't match. Saving confirms you counted all {page.items.length}.
        </p>
      )}
      {error && (
        <p
          role="alert"
          className="rounded-2xl border border-[#f1c8cc] bg-[#fff5f5] px-4 py-3 text-sm text-[#8d2d39]"
        >
          {error}
        </p>
      )}
      <ul className="space-y-2.5" aria-label={`Items at ${page.location.name}`}>
        {page.items.map((item) => (
          <CountItemRow
            key={item.inventoryItemId}
            item={item}
            value={entries[item.inventoryItemId] ?? ""}
            error={showErrors ? review.errors[item.inventoryItemId] : undefined}
            onChange={(value) =>
              setEntries((current) => ({ ...current, [item.inventoryItemId]: value }))
            }
          />
        ))}
      </ul>
      {phase !== "stale" && (
        <div className="fixed inset-x-0 bottom-[calc(4.75rem+env(safe-area-inset-bottom))] z-30 px-4">
          <div className="mx-auto flex max-w-2xl items-center justify-between gap-3 rounded-2xl border border-[#e1e6ec] bg-white/95 p-3 shadow-[0_8px_28px_rgba(7,29,56,0.12)] backdrop-blur">
            <p
              className="min-w-0 text-sm text-[#344256]"
              aria-live="polite"
              data-testid="count-summary"
            >
              <span className="font-semibold tabular-nums">{review.changed.length}</span> changed ·{" "}
              <span className="font-semibold tabular-nums">{review.unchanged}</span> unchanged
            </p>
            <button
              type="button"
              disabled={saving}
              onClick={() => {
                if (!review.complete) {
                  setShowErrors(true);
                  // Take the person to the first field that needs a quantity.
                  const first = page.items.find((item) => review.errors[item.inventoryItemId]);
                  if (first) document.getElementById(`count-${first.inventoryItemId}`)?.focus();
                  return;
                }
                setPhase("confirming");
              }}
              className="min-h-12 shrink-0 rounded-2xl bg-[#d95700] px-5 font-semibold text-white active:bg-[#bf4c00] disabled:opacity-70"
            >
              Review & save
            </button>
          </div>
        </div>
      )}
      {phase === "confirming" && (
        <CountConfirmation
          review={review}
          total={page.items.length}
          saving={saving}
          onConfirm={submit}
          onCancel={() => setPhase("editing")}
        />
      )}
    </div>
  );
}

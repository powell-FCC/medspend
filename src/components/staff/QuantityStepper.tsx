import { Minus, Plus, Trash2 } from "lucide-react";

// One-handed quantity control with 44px targets. At quantity 1 the minus button becomes
// "remove" when the caller allows it, so a line can be dropped without hunting for an X.
export function QuantityStepper({
  name,
  quantity,
  onDecrease,
  onIncrease,
  onRemove,
}: {
  name: string;
  quantity: number;
  onDecrease: () => void;
  onIncrease: () => void;
  onRemove?: () => void;
}) {
  const removes = quantity <= 1 && !!onRemove;
  return (
    <div className="flex shrink-0 items-center rounded-xl border border-[#dce2e8] bg-white">
      <button
        type="button"
        onClick={removes ? onRemove : onDecrease}
        disabled={!removes && quantity <= 1}
        aria-label={removes ? `Remove ${name}` : `Decrease ${name}`}
        className="flex size-11 items-center justify-center rounded-l-xl text-[#344256] transition active:bg-[#eef1f4] disabled:text-[#c3cad2]"
      >
        {removes ? (
          <Trash2 className="size-4 text-[#a83340]" aria-hidden="true" />
        ) : (
          <Minus className="size-4" aria-hidden="true" />
        )}
      </button>
      <span
        className="min-w-8 text-center text-base font-semibold tabular-nums text-[#071d38]"
        aria-live="polite"
        aria-label={`${name} quantity ${quantity}`}
      >
        {quantity}
      </span>
      <button
        type="button"
        onClick={onIncrease}
        aria-label={`Increase ${name}`}
        className="flex size-11 items-center justify-center rounded-r-xl text-[#071d38] transition active:bg-[#eef1f4]"
      >
        <Plus className="size-4" aria-hidden="true" />
      </button>
    </div>
  );
}

import { Link } from "@tanstack/react-router";
import { ArrowRight, ShoppingBasket } from "lucide-react";
import { describeCartCount, type StaffRequestCartItem } from "@/supply-requests/staff-request-cart";
import { ProductDetails } from "@/components/staff/StaffProductPicker";
import { QuantityStepper } from "@/components/staff/QuantityStepper";

export function StaffCartList({
  items,
  onChangeQuantity,
  onRemove,
}: {
  items: StaffRequestCartItem[];
  onChangeQuantity: (key: string, delta: number) => void;
  onRemove: (key: string) => void;
}) {
  return (
    <ul
      aria-label="Items in this request"
      className="divide-y divide-[#edf0f3] overflow-hidden rounded-2xl border border-[#e1e6ec] bg-white shadow-[0_4px_18px_rgba(7,29,56,0.04)]"
    >
      {items.map((item) => (
        <li key={item.key} className="px-4 py-3.5">
          <div className="min-w-0">
            <div className="font-medium leading-6 text-[#071d38] [overflow-wrap:anywhere]">
              {item.name}
            </div>
            {item.kind === "structured" && <ProductDetails product={item} />}
            {item.kind === "custom" && (
              <div className="mt-0.5 text-xs text-[#7b8693]">Custom item</div>
            )}
          </div>
          <div className="mt-2.5 flex items-center justify-between gap-3">
            <button
              type="button"
              onClick={() => onRemove(item.key)}
              aria-label={`Remove ${item.name}`}
              className="-ml-2 min-h-11 rounded-lg px-2 text-sm font-medium text-[#a83340] active:bg-[#fff0f1]"
            >
              Remove
            </button>
            <QuantityStepper
              name={item.name}
              quantity={item.quantity}
              onDecrease={() => onChangeQuantity(item.key, -1)}
              onIncrease={() => onChangeQuantity(item.key, 1)}
            />
          </div>
        </li>
      ))}
    </ul>
  );
}

// Persistent "N items · Review request" action, docked above the bottom navigation.
export function StaffCartBar({ items }: { items: StaffRequestCartItem[] }) {
  if (items.length === 0) return null;
  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-[calc(4rem+env(safe-area-inset-bottom))] z-30 px-4 pb-3">
      <Link
        to="/staff/request"
        search={{}}
        className="pointer-events-auto mx-auto flex min-h-14 max-w-2xl items-center justify-between gap-3 rounded-2xl bg-[#f56600] px-5 text-white shadow-[0_12px_30px_rgba(245,102,0,0.32)] transition active:scale-[0.99] active:bg-[#dc5c00] focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-[#f56600]/30"
      >
        <span className="flex items-center gap-2.5 font-semibold">
          <ShoppingBasket className="size-5" aria-hidden="true" />
          {describeCartCount(items)}
        </span>
        <span className="flex items-center gap-1.5 font-semibold">
          Review request
          <ArrowRight className="size-4" aria-hidden="true" />
        </span>
      </Link>
    </div>
  );
}

import type { ButtonHTMLAttributes } from "react";
import { cn } from "@/lib/utils";

export function AdminActionButton({
  children,
  variant = "primary",
  className,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "secondary" | "danger" }) {
  return (
    <button
      type="button"
      className={cn(
        "inline-flex min-h-11 items-center justify-center gap-2 rounded-lg px-4 text-sm font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f56600] disabled:cursor-not-allowed disabled:opacity-50",
        variant === "primary" && "bg-[#102a49] text-white hover:bg-[#193b61]",
        variant === "secondary" && "border border-[#d7dee6] bg-white text-[#273a51] hover:bg-[#f5f7f9]",
        variant === "danger" && "border border-[#efc8cd] bg-white text-[#a83340] hover:bg-[#fff3f4]",
        className,
      )}
      {...props}
    >
      {children}
    </button>
  );
}

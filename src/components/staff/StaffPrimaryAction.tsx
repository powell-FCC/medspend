import { Link } from "@tanstack/react-router";
import { ArrowRight, Plus } from "lucide-react";

export function StaffPrimaryAction() {
  return (
    <Link
      to="/staff/request"
      search={{}}
      className="group flex min-h-24 items-center justify-between rounded-[1.4rem] bg-[#f56600] px-5 py-4 text-white shadow-[0_12px_32px_rgba(245,102,0,0.24)] transition hover:bg-[#dc5c00] focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-[#f56600]/30"
    >
      <span className="flex items-center gap-4">
        <span className="flex size-11 items-center justify-center rounded-full bg-white/18" aria-hidden="true">
          <Plus className="size-6" strokeWidth={2.5} />
        </span>
        <span>
          <span className="block text-lg font-semibold">Request Supplies</span>
          <span className="mt-0.5 block text-sm text-white/80">Find what your team needs</span>
        </span>
      </span>
      <ArrowRight className="size-5 transition group-hover:translate-x-0.5" aria-hidden="true" />
    </Link>
  );
}

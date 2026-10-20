import { useRouter, useRouterState } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { supabase } from "@/integrations/supabase/client";
import { useActiveOrg } from "@/hooks/use-active-org";
import { StaffBottomNav } from "@/components/staff/StaffBottomNav";
import { StaffCartBar } from "@/components/staff/StaffCartList";
import { StaffCartProvider, useStaffCart } from "@/components/staff/StaffCartProvider";

// The cart belongs to one organization: switching organizations starts a fresh cart.
export function StaffAppShell({ children }: { children: ReactNode }) {
  const { active } = useActiveOrg();
  return (
    <StaffCartProvider key={active?.organizationId ?? "none"}>
      <StaffShellLayout>{children}</StaffShellLayout>
    </StaffCartProvider>
  );
}

function StaffShellLayout({ children }: { children: ReactNode }) {
  const router = useRouter();
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const { items } = useStaffCart();
  // The request page carries its own review/submit action.
  const showCartBar = items.length > 0 && pathname !== "/staff/request";
  return (
    <div
      className={`relative min-h-dvh bg-[#f5f7f9] text-[#071d38] ${showCartBar ? "pb-[calc(9.5rem+env(safe-area-inset-bottom))]" : "pb-[calc(5rem+env(safe-area-inset-bottom))]"}`}
      data-shell="staff"
    >
      <main className="mx-auto max-w-2xl px-4 pb-8 pt-[max(1.25rem,env(safe-area-inset-top))] sm:px-6">
        {children}
      </main>
      {showCartBar && <StaffCartBar items={items} />}
      <StaffBottomNav cartCount={items.length} />
      <button
        onClick={async () => {
          await supabase.auth.signOut();
          router.navigate({ to: "/auth", replace: true });
        }}
        className="absolute right-4 top-[max(1.25rem,env(safe-area-inset-top))] z-30 min-h-11 px-2 text-xs font-medium text-[#667384] hover:text-[#071d38]"
      >
        Sign out
      </button>
    </div>
  );
}

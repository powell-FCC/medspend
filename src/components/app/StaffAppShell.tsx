import { useRouter } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { supabase } from "@/integrations/supabase/client";
import { StaffBottomNav } from "@/components/staff/StaffBottomNav";

export function StaffAppShell({ children }: { children: ReactNode }) {
  const router = useRouter();
  return (
    <div className="min-h-dvh bg-[#f5f7f9] pb-[calc(5rem+env(safe-area-inset-bottom))] text-[#071d38]" data-shell="staff">
      <main className="mx-auto max-w-2xl px-4 pb-8 pt-[max(1.25rem,env(safe-area-inset-top))] sm:px-6">{children}</main>
      <StaffBottomNav />
      <button
        onClick={async () => {
          await supabase.auth.signOut();
          router.navigate({ to: "/auth", replace: true });
        }}
        className="fixed right-4 top-[max(1.25rem,env(safe-area-inset-top))] z-30 min-h-11 px-2 text-xs font-medium text-[#667384] hover:text-[#071d38]"
      >
        Sign out
      </button>
    </div>
  );
}

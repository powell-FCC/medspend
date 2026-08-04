import { Link, useRouter, useRouterState } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { Home, PackagePlus, ClipboardList, User } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";

const tabs = [
  { to: "/staff", label: "Home", icon: Home, exact: true },
  { to: "/staff/request", label: "Request", icon: PackagePlus, exact: false },
  { to: "/staff/requests", label: "My Requests", icon: ClipboardList, exact: false },
  { to: "/profile", label: "Profile", icon: User, exact: false },
] as const;

export function StaffAppShell({ children }: { children: ReactNode }) {
  const router = useRouter();
  const pathname = useRouterState({ select: (s) => s.location.pathname });

  return (
    <div className="min-h-screen bg-background text-foreground pb-20" data-shell="staff">
      <main className="max-w-2xl mx-auto px-4 py-6">{children}</main>
      <nav className="fixed bottom-0 inset-x-0 border-t bg-card">
        <div className="max-w-2xl mx-auto grid grid-cols-4">
          {tabs.map(({ to, label, icon: Icon, exact }) => {
            const active = exact ? pathname === to : pathname === to || pathname.startsWith(to + "/");
            return (
              <Link
                key={to}
                to={to}
                className={
                  "flex flex-col items-center gap-1 py-3 text-[11px] font-medium " +
                  (active ? "text-primary" : "text-muted-foreground")
                }
              >
                <Icon className="h-5 w-5" />
                {label}
              </Link>
            );
          })}
        </div>
      </nav>
      <button
        onClick={async () => {
          await supabase.auth.signOut();
          router.navigate({ to: "/auth", replace: true });
        }}
        className="fixed top-3 right-3 text-xs text-muted-foreground hover:text-foreground"
      >
        Sign out
      </button>
    </div>
  );
}
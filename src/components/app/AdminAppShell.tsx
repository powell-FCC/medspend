import { Link, useRouter, useRouterState } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { LayoutDashboard, Upload, ShoppingCart, Package, Building2, FileText, Users, Settings, LogOut, Building } from "lucide-react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { supabase } from "@/integrations/supabase/client";

const nav = [
  { to: "/dashboard", label: "Dashboard", icon: LayoutDashboard },
  { to: "/inventory", label: "Inventory", icon: Package, ownerOnly: true },
  { to: "/purchases", label: "Orders", icon: ShoppingCart },
  { to: "/vendors", label: "Vendors", icon: Building2 },
  { to: "/upload", label: "Upload Invoice", icon: Upload, ownerOnly: true },
  { to: "/invoices", label: "Invoices", icon: FileText, ownerOnly: true },
  { to: "/supply-requests", label: "Staff", icon: Users },
  { to: "/settings", label: "Settings", icon: Settings },
] as const;

export function AdminAppShell({ children }: { children: ReactNode }) {
  const { active, memberships, setActiveOrgId } = useActiveOrg();
  const router = useRouter();
  const pathname = useRouterState({ select: (s) => s.location.pathname });

  async function signOut() {
    await supabase.auth.signOut();
    router.navigate({ to: "/auth", replace: true });
  }

  return (
    <div className="flex min-h-screen bg-background text-foreground" data-shell="admin">
      <aside className="hidden md:flex w-60 flex-col border-r bg-card">
        <div className="px-5 py-5 border-b">
          <div className="text-sm font-semibold tracking-tight">MedSpend</div>
          <div className="mt-2 flex items-center gap-2 text-xs text-muted-foreground">
            <Building className="h-3.5 w-3.5" />
            <span className="truncate">{active?.organizationName ?? "—"}</span>
          </div>
          <div className="mt-0.5 text-[10px] uppercase tracking-wider text-primary">{active?.role}</div>
          {memberships.length > 1 && (
            <select
              className="mt-2 w-full text-xs rounded border bg-background px-2 py-1"
              value={active?.organizationId ?? ""}
              onChange={(e) => setActiveOrgId(e.target.value)}
            >
              {memberships.map((m) => (
                <option key={m.organizationId} value={m.organizationId}>
                  {m.organizationName} · {m.role}
                </option>
              ))}
            </select>
          )}
        </div>
        <nav className="flex-1 py-3">
          {nav.filter((item) => !("ownerOnly" in item) || active?.role === "owner").map(({ to, label, icon: Icon }) => {
            const activeLink = pathname === to || pathname.startsWith(to + "/");
            return (
              <Link
                key={to}
                to={to}
                className={
                  "flex items-center gap-2 px-5 py-2 text-sm transition-colors " +
                  (activeLink
                    ? "bg-accent text-accent-foreground font-medium"
                    : "text-muted-foreground hover:bg-muted")
                }
              >
                <Icon className="h-4 w-4" />
                {label}
              </Link>
            );
          })}
        </nav>
        <button
          onClick={signOut}
          className="flex items-center gap-2 px-5 py-3 text-sm border-t text-muted-foreground hover:bg-muted"
        >
          <LogOut className="h-4 w-4" /> Sign out
        </button>
      </aside>
      <main className="flex-1 min-w-0">{children}</main>
    </div>
  );
}

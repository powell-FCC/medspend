import { createFileRoute, Outlet, redirect, useRouterState, useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { supabase } from "@/integrations/supabase/client";
import { ActiveOrgProvider, useActiveOrg } from "@/hooks/use-active-org";
import { AdminAppShell } from "@/components/app/AdminAppShell";
import { StaffAppShell } from "@/components/app/StaffAppShell";

export const Route = createFileRoute("/_authenticated")({
  ssr: false,
  beforeLoad: async ({ location }) => {
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user) {
      throw redirect({ to: "/auth", search: { redirect: location.href } });
    }
  },
  component: () => (
    <ActiveOrgProvider>
      <ShellSwitcher />
    </ActiveOrgProvider>
  ),
});

const ADMIN_ROUTES = ["/dashboard", "/upload", "/purchases", "/invoices", "/products", "/vendors", "/supply-requests", "/settings"];
const STAFF_ROUTES = ["/staff", "/profile"];

function isAdminPath(p: string) {
  return ADMIN_ROUTES.some((r) => p === r || p.startsWith(r + "/"));
}
function isStaffPath(p: string) {
  return STAFF_ROUTES.some((r) => p === r || p.startsWith(r + "/"));
}

function ShellSwitcher() {
  const { memberships, active, loading, setActiveOrgId } = useActiveOrg();
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const navigate = useNavigate();

  // No memberships -> onboarding
  useEffect(() => {
    if (loading) return;
    if (memberships.length === 0) {
      if (pathname !== "/onboarding") navigate({ to: "/onboarding", replace: true });
      return;
    }
    if (memberships.length > 1 && !active) {
      if (pathname !== "/select-organization") navigate({ to: "/select-organization", replace: true });
      return;
    }
  }, [loading, memberships, active, pathname, navigate]);

  // Role-based redirect BEFORE render (no shell flash)
  useEffect(() => {
    if (!active) return;
    const isAdmin = active.role === "owner" || active.role === "admin";
    if (isAdmin && pathname.startsWith("/staff")) {
      navigate({ to: "/dashboard", replace: true });
    } else if (!isAdmin && isAdminPath(pathname)) {
      navigate({ to: "/staff", replace: true });
    } else if (pathname === "/onboarding" && memberships.length > 0) {
      navigate({ to: isAdmin ? "/dashboard" : "/staff", replace: true });
    }
  }, [active, pathname, navigate, memberships.length]);

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center text-sm text-muted-foreground">Loading…</div>
    );
  }

  // Bare routes for onboarding / selection
  if (pathname === "/onboarding" || pathname === "/select-organization") {
    return <Outlet />;
  }

  if (memberships.length === 0) {
    return <div className="min-h-screen flex items-center justify-center text-sm text-muted-foreground">Redirecting…</div>;
  }
  if (!active) {
    return <div className="min-h-screen flex items-center justify-center text-sm text-muted-foreground">Select an organization…</div>;
  }

  const isAdmin = active.role === "owner" || active.role === "admin";

  // If role and path mismatch, don't render either shell (avoid flash) — redirect effect will run
  if (isAdmin && !isAdminPath(pathname) && pathname !== "/") return null;
  if (!isAdmin && !isStaffPath(pathname)) return null;

  // Silence unused
  void setActiveOrgId;

  return isAdmin ? (
    <AdminAppShell>
      <Outlet />
    </AdminAppShell>
  ) : (
    <StaffAppShell>
      <Outlet />
    </StaffAppShell>
  );
}
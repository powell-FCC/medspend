import { Link, useRouterState } from "@tanstack/react-router";
import { ClipboardList, Home, PackagePlus, User } from "lucide-react";

const tabs = [
  { to: "/staff", label: "Home", icon: Home, exact: true },
  { to: "/staff/request", label: "Request", icon: PackagePlus, exact: false },
  { to: "/staff/requests", label: "My Requests", icon: ClipboardList, exact: false },
  { to: "/profile", label: "Profile", icon: User, exact: false },
] as const;

export function StaffBottomNav() {
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  return (
    <nav className="fixed inset-x-0 bottom-0 z-40 border-t border-[#dfe4ea] bg-white/95 pb-[env(safe-area-inset-bottom)] backdrop-blur-xl" aria-label="Staff navigation">
      <div className="mx-auto grid max-w-2xl grid-cols-4 px-2">
        {tabs.map(({ to, label, icon: Icon, exact }) => {
          const active = exact ? pathname === to : pathname === to || pathname.startsWith(`${to}/`);
          return (
            <Link key={to} to={to} className={`flex min-h-16 flex-col items-center justify-center gap-1 rounded-xl text-[0.68rem] font-semibold transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#f56600] ${active ? "text-[#f56600]" : "text-[#6c7785] hover:text-[#071d38]"}`} aria-current={active ? "page" : undefined}>
              <Icon className="size-5" strokeWidth={active ? 2.5 : 2} aria-hidden="true" />
              {label}
            </Link>
          );
        })}
      </div>
    </nav>
  );
}

import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { PackagePlus, AlertTriangle, XCircle } from "lucide-react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { useAuth } from "@/hooks/use-auth";
import { listMyRequestsFn } from "@/lib/supply-requests.functions";

export const Route = createFileRoute("/_authenticated/staff/")({
  head: () => ({ meta: [{ title: "Staff — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: StaffHome,
});

function StaffHome() {
  const { active } = useActiveOrg();
  const { user } = useAuth();
  const fetcher = useServerFn(listMyRequestsFn);
  const q = useQuery({
    queryKey: ["me", active?.organizationId, "requests"],
    queryFn: () => fetcher({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });

  return (
    <div>
      <div className="text-xs uppercase tracking-wider text-muted-foreground">{active?.organizationName}</div>
      <h1 className="mt-1 text-2xl font-semibold">Hi{user?.user_metadata?.full_name ? `, ${user.user_metadata.full_name}` : ""}</h1>
      <div className="mt-1 text-sm text-muted-foreground">Staff portal</div>

      <div className="mt-6 grid grid-cols-1 gap-3">
        <ActionCard
          to="/staff/request"
          search={{ type: "reorder" }}
          icon={PackagePlus}
          title="Request supplies"
          subtitle="Reorder items your team needs"
        />
        <ActionCard
          to="/staff/request"
          search={{ type: "low_stock" }}
          icon={AlertTriangle}
          title="Report low stock"
          subtitle="Flag an item that's running low"
        />
        <ActionCard
          to="/staff/request"
          search={{ type: "out_of_stock" }}
          icon={XCircle}
          title="Report out of stock"
          subtitle="Something is completely out"
        />
      </div>

      <div className="mt-8">
        <div className="flex items-center justify-between">
          <h2 className="font-medium">Recent requests</h2>
          <Link to="/staff/requests" className="text-xs text-primary">
            View all
          </Link>
        </div>
        <ul className="mt-2 divide-y rounded-xl border bg-card">
          {(q.data ?? []).slice(0, 5).map((r) => (
            <li key={r.id} className="p-3 text-sm flex items-center justify-between">
              <div>
                <div>{r.itemName}</div>
                <div className="text-xs text-muted-foreground">
                  {r.requestType} · qty {r.quantity ?? "—"}
                </div>
              </div>
              <span className="text-xs uppercase tracking-wider text-primary">{r.status}</span>
            </li>
          ))}
          {(q.data ?? []).length === 0 && (
            <li className="p-4 text-sm text-muted-foreground">No requests yet.</li>
          )}
        </ul>
      </div>
    </div>
  );
}

type IconType = React.ComponentType<{ className?: string }>;
function ActionCard({
  to,
  search,
  icon: Icon,
  title,
  subtitle,
}: {
  to: string;
  search: Record<string, string>;
  icon: IconType;
  title: string;
  subtitle: string;
}) {
  return (
    <Link
      to={to}
      search={search}
      className="flex items-center gap-4 rounded-xl border bg-card p-4 hover:bg-muted"
    >
      <div className="rounded-lg bg-accent p-3 text-accent-foreground">
        <Icon className="h-6 w-6" />
      </div>
      <div>
        <div className="font-medium">{title}</div>
        <div className="text-xs text-muted-foreground">{subtitle}</div>
      </div>
    </Link>
  );
}
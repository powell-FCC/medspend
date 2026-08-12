import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { useActiveOrg } from "@/hooks/use-active-org";
import { listMyRequestsFn } from "@/lib/supply-requests.functions";

export const Route = createFileRoute("/_authenticated/staff/requests")({
  head: () => ({ meta: [{ title: "My requests — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: MyRequests,
});

function MyRequests() {
  const { active } = useActiveOrg();
  const fetcher = useServerFn(listMyRequestsFn);
  const q = useQuery({
    queryKey: ["me", active?.organizationId, "requests"],
    queryFn: () => fetcher({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });

  return (
    <div>
      <h1 className="text-2xl font-semibold">My requests</h1>
      <ul className="mt-4 divide-y rounded-xl border bg-card">
        {(q.data ?? []).map((r) => (
          <li key={r.id} className="p-4 text-sm">
            <div className="flex items-center justify-between">
              <div className="font-medium">{r.itemName}</div>
              <span className="text-xs uppercase tracking-wider text-primary">{r.status}</span>
            </div>
            <div className="mt-1 text-xs text-muted-foreground">
              {r.requestType} · qty {r.quantity ?? "—"} · submitted {new Date(r.createdAt).toLocaleDateString()}
            </div>
            {r.notes && <div className="mt-2 text-sm">{r.notes}</div>}
            {r.latestStaffVisibleNote && <div className="mt-2 rounded-md bg-muted px-3 py-2 text-sm">{r.latestStaffVisibleNote}</div>}
            {r.orderedAt && <div className="mt-1 text-xs text-muted-foreground">Ordered {new Date(r.orderedAt).toLocaleDateString()}</div>}
            {r.receivedAt && <div className="mt-1 text-xs text-muted-foreground">Received {new Date(r.receivedAt).toLocaleDateString()}</div>}
          </li>
        ))}
        {(q.data ?? []).length === 0 && <li className="p-6 text-sm text-muted-foreground text-center">No requests yet.</li>}
      </ul>
    </div>
  );
}

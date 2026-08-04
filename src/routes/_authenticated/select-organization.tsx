import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useActiveOrg } from "@/hooks/use-active-org";

export const Route = createFileRoute("/_authenticated/select-organization")({
  head: () => ({ meta: [{ title: "Select organization — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: Selector,
});

function Selector() {
  const { memberships, setActiveOrgId } = useActiveOrg();
  const navigate = useNavigate();

  function pick(orgId: string, role: string) {
    setActiveOrgId(orgId);
    navigate({ to: role === "staff" ? "/staff" : "/dashboard", replace: true });
  }

  return (
    <div className="min-h-screen flex items-center justify-center px-4">
      <div className="w-full max-w-md rounded-xl border bg-card p-6">
        <h1 className="text-lg font-semibold">Select an organization</h1>
        <p className="mt-1 text-sm text-muted-foreground">You belong to more than one organization.</p>
        <ul className="mt-4 space-y-2">
          {memberships.map((m) => (
            <li key={m.organizationId}>
              <button
                onClick={() => pick(m.organizationId, m.role)}
                className="w-full text-left rounded-md border px-3 py-3 hover:bg-muted"
              >
                <div className="font-medium text-sm">{m.organizationName}</div>
                <div className="text-xs uppercase tracking-wider text-primary mt-0.5">{m.role}</div>
              </button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
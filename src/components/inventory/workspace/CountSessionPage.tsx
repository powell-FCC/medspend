import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useServerFn } from "@tanstack/react-start";
import { AlertCircle, ArrowLeft } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { useActiveOrg } from "@/hooks/use-active-org";
import { getCountSessionFn } from "@/lib/inventory-workspace.functions";
import { inventoryWorkspaceAccess, workspaceQueryKey } from "@/inventory/workspace";
import { CountSessionView } from "./CountSessionView";

// Phase 7B.2 count detail. Owners and admins see the same read-only page.
export function CountSessionPage({ sessionId }: { sessionId: string }) {
  const { active, loading } = useActiveOrg();
  const access = inventoryWorkspaceAccess(active?.role);
  const organizationId = active?.organizationId ?? "";
  const get = useServerFn(getCountSessionFn);
  const session = useQuery({
    queryKey: [...workspaceQueryKey(organizationId), "count-session", sessionId],
    queryFn: () => get({ data: { organizationId, sessionId } }),
    enabled: Boolean(organizationId && access.canRead),
  });
  if (loading) return <Centered>Loading…</Centered>;
  if (!active || !access.canRead)
    return (
      <div className="mx-auto max-w-3xl px-6 py-16">
        <Alert variant="destructive">
          <AlertCircle />
          <AlertTitle>Owner or admin access required</AlertTitle>
          <AlertDescription>
            Only organization owners and admins can view inventory.
          </AlertDescription>
        </Alert>
      </div>
    );
  return (
    <div className="mx-auto max-w-7xl px-5 py-8 sm:px-8" data-page="inventory-count">
      <nav className="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
        <Link
          to="/inventory"
          search={{ tab: "counts" }}
          className="inline-flex items-center gap-1 text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft className="h-4 w-4" />
          Counts
        </Link>
        {session.data && (
          <Link
            to="/inventory/locations/$locationId"
            params={{ locationId: session.data.locationId }}
            search={{ tab: "counts" }}
            className="text-muted-foreground hover:text-foreground"
          >
            {session.data.locationName}
          </Link>
        )}
      </nav>
      {session.isLoading && <Centered>Loading count…</Centered>}
      {session.isError && (
        <Alert variant="destructive" className="mt-6">
          <AlertCircle />
          <AlertTitle>Could not load this count</AlertTitle>
          <AlertDescription>
            {session.error instanceof Error ? session.error.message : "Try again."}
          </AlertDescription>
        </Alert>
      )}
      {session.data && (
        <div className="mt-4">
          <CountSessionView session={session.data} />
        </div>
      )}
    </div>
  );
}

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="py-12 text-center text-sm text-muted-foreground">{children}</div>;
}

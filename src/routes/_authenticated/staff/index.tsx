import { createFileRoute, Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { ClipboardList, PackageCheck } from "lucide-react";
import { useState } from "react";
import { useActiveOrg } from "@/hooks/use-active-org";
import { useAuth } from "@/hooks/use-auth";
import { getStaffDashboardFn } from "@/lib/supply-requests.functions";
import { RequestSummaryCard } from "@/components/staff/RequestSummaryCard";
import { StaffEmptyState } from "@/components/staff/StaffEmptyState";
import { StaffProductPicker, StaffQuickPicks } from "@/components/staff/StaffProductPicker";
import {
  StaffErrorState,
  StaffListSkeleton,
  StaffSectionHeader,
} from "@/components/staff/StaffStates";
import { useStaffCart } from "@/components/staff/StaffCartProvider";
import {
  useStaffProductSearch,
  useStaffQuickPicks,
} from "@/components/staff/useStaffProductSearch";
import { STAFF_CART_MAX_LINES } from "@/supply-requests/staff-request-cart";

export const Route = createFileRoute("/_authenticated/staff/")({
  head: () => ({ meta: [{ title: "Staff — MedSpend" }, { name: "robots", content: "noindex" }] }),
  component: StaffHome,
});

const WORKSPACE_OPEN_REQUESTS = 3;

// Staff Workspace: an action workspace, not a dashboard. Top to bottom it answers
// "anything ready for me?", "what do I need?", "what have I requested?" and "what do I
// usually ask for?". A future primary action (e.g. Scan Inventory QR) slots in beside
// Request Supplies without reshaping the page.
function StaffHome() {
  const { active } = useActiveOrg();
  const { user } = useAuth();
  const cart = useStaffCart();
  const [query, setQuery] = useState("");
  const search = useStaffProductSearch(active?.organizationId, query);
  const quickPicks = useStaffQuickPicks(active?.organizationId);
  const fetcher = useServerFn(getStaffDashboardFn);
  const q = useQuery({
    queryKey: ["me", active?.organizationId, "requests"],
    queryFn: () => fetcher({ data: { organizationId: active!.organizationId } }),
    enabled: !!active,
  });
  const firstName = user?.user_metadata?.full_name?.split(" ")[0];
  const hour = new Date().getHours();
  const greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";

  const readyRequests =
    q.data?.openRequests.filter((request) => request.statusGroup === "READY") ?? [];
  const inProgress =
    q.data?.openRequests.filter((request) => request.statusGroup === "ACTIVE") ?? [];
  const latestPast = q.data?.pastRequests.slice(0, 2) ?? [];
  const cartControls = {
    cartItems: cart.items,
    cartFull: cart.items.length >= STAFF_CART_MAX_LINES,
    onAddProduct: cart.addProduct,
    onChangeQuantity: cart.changeQuantity,
    onRemove: cart.remove,
  };

  return (
    <div className="space-y-8">
      <header className="pr-16">
        <p className="text-[0.7rem] font-semibold uppercase tracking-[0.18em] text-[#5c6878]">
          {active?.organizationName ?? "Medical Team"}
        </p>
        <h1 className="mt-1 text-[1.7rem] font-semibold tracking-[-0.035em] text-[#071d38]">
          {greeting}
          {firstName ? `, ${firstName}` : ""}
        </h1>
      </header>

      {readyRequests.length > 0 && (
        <section aria-labelledby="ready-title" className="space-y-2.5">
          <h2
            id="ready-title"
            className="flex items-center gap-2 text-[0.95rem] font-semibold tracking-tight text-[#a84300]"
          >
            <PackageCheck className="size-4" aria-hidden="true" />
            Ready for you
          </h2>
          {readyRequests.map((request) => (
            <RequestSummaryCard key={request.id} request={request} />
          ))}
        </section>
      )}

      <section
        aria-labelledby="request-supplies-title"
        className="rounded-3xl border border-[#e1e6ec] bg-white p-4 shadow-[0_8px_28px_rgba(7,29,56,0.06)] sm:p-5"
      >
        <h2
          id="request-supplies-title"
          className="text-lg font-semibold tracking-tight text-[#071d38]"
        >
          Request Supplies
        </h2>
        <p className="mb-3 mt-0.5 text-sm text-[#697687]">
          Need something? Find it and add it in one tap.
        </p>
        <StaffProductPicker
          inputId="workspace-search"
          label="Search supplies"
          query={query}
          onQueryChange={setQuery}
          search={search}
          onAddCustom={cart.addCustom}
          {...cartControls}
        />
      </section>

      <section aria-labelledby="my-requests-title">
        <StaffSectionHeader
          id="my-requests-title"
          title="My Requests"
          action={
            <Link
              to="/staff/requests"
              className="flex min-h-11 items-center px-1 text-sm font-semibold text-[#d95700]"
            >
              View all
            </Link>
          }
        />
        <div className="mt-2 space-y-2.5">
          {q.isLoading && <StaffListSkeleton label="Loading your requests" rows={2} />}
          {q.isError && (
            <StaffErrorState
              message="We couldn't load your requests."
              onRetry={() => void q.refetch()}
            />
          )}
          {q.data &&
            inProgress
              .slice(0, WORKSPACE_OPEN_REQUESTS)
              .map((request) => <RequestSummaryCard key={request.id} request={request} />)}
          {q.data && inProgress.length > WORKSPACE_OPEN_REQUESTS && (
            <Link
              to="/staff/requests"
              className="flex min-h-11 items-center justify-center rounded-xl text-sm font-semibold text-[#526174] active:bg-[#eef1f4]"
            >
              {inProgress.length - WORKSPACE_OPEN_REQUESTS} more in progress
            </Link>
          )}
          {q.data && inProgress.length === 0 && latestPast.length > 0 && (
            <>
              <p className="px-1 text-sm text-[#697687]">Nothing in progress right now.</p>
              {latestPast.map((request) => (
                <RequestSummaryCard key={request.id} request={request} />
              ))}
            </>
          )}
          {q.data && q.data.openRequests.length === 0 && q.data.pastRequests.length === 0 && (
            <StaffEmptyState
              icon={<ClipboardList className="size-5" />}
              title="No requests yet"
              description="When you submit a request, you can follow it here."
            />
          )}
        </div>
      </section>

      <section aria-labelledby="usual-items-title">
        <StaffSectionHeader id="usual-items-title" title="Frequent & Recent Items" />
        <div className="mt-2">
          <StaffQuickPicks state={quickPicks} controls={cartControls} />
        </div>
      </section>
    </div>
  );
}

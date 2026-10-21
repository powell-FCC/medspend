import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { ArrowLeft, MessageCircle, Pencil, RotateCcw } from "lucide-react";
import { useState } from "react";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { useActiveOrg } from "@/hooks/use-active-org";
import { getStaffRequestDetailFn } from "@/lib/supply-requests.functions";
import { CancelRequestAction } from "@/components/staff/CancelRequestAction";
import { RequestDetailHeader } from "@/components/staff/RequestDetailHeader";
import { RequestDetailTimeline } from "@/components/staff/RequestDetailTimeline";
import { useStaffCart } from "@/components/staff/StaffCartProvider";
import { StaffErrorState, StaffListSkeleton } from "@/components/staff/StaffStates";
import { requestItemIsCustom } from "@/supply-requests/admin-request-inbox";
import { describeCartCount } from "@/supply-requests/staff-request-cart";

export const Route = createFileRoute("/_authenticated/staff/requests/$id")({
  head: () => ({
    meta: [{ title: "Request details — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: StaffRequestDetail,
});

const card =
  "rounded-2xl border border-[#e1e6ec] bg-white p-5 shadow-[0_4px_18px_rgba(7,29,56,0.04)]";

function StaffRequestDetail() {
  const { id } = Route.useParams();
  const { active } = useActiveOrg();
  const navigate = useNavigate();
  const cart = useStaffCart();
  const [confirmingReplace, setConfirmingReplace] = useState(false);
  const fetchDetail = useServerFn(getStaffRequestDetailFn);
  const request = useQuery({
    queryKey: ["me", active?.organizationId, "requests", id],
    queryFn: () => fetchDetail({ data: { organizationId: active!.organizationId, requestId: id } }),
    enabled: !!active,
  });

  // Request again only opens a new, editable cart. It never reopens or changes this
  // request, and nothing is submitted until the requester submits the new one.
  const requestAgain = () => void navigate({ to: "/staff/request", search: { again: id } });

  return (
    <div className="space-y-4">
      <Link
        to="/staff/requests"
        className="inline-flex min-h-11 items-center gap-2 py-2 text-sm font-semibold text-[#526174]"
      >
        <ArrowLeft className="size-4" /> My Requests
      </Link>
      {request.isLoading && <StaffListSkeleton label="Loading request" rows={2} />}
      {request.isError && (
        <StaffErrorState
          message="This request isn't available."
          onRetry={() => void request.refetch()}
        />
      )}
      {request.data && (
        <>
          <RequestDetailHeader request={request.data} />
          {request.data.staffMessage && (
            <section className={card} aria-labelledby="latest-update-title">
              <h2
                id="latest-update-title"
                className="flex items-center gap-2 text-sm font-semibold"
              >
                <MessageCircle className="size-4 text-[#f56600]" aria-hidden="true" /> Latest update
              </h2>
              <p className="mt-2 text-sm leading-6 text-[#526174] [overflow-wrap:anywhere]">
                {request.data.staffMessage}
              </p>
            </section>
          )}
          <section className={card} aria-labelledby="items-title">
            <h2 id="items-title" className="text-sm font-semibold text-[#34445a]">
              {request.data.itemCount} {request.data.itemCount === 1 ? "item" : "items"} requested
            </h2>
            <ul className="mt-2 divide-y divide-[#edf0f3]">
              {request.data.items.map((item) => (
                <li key={item.id} className="flex items-start justify-between gap-4 py-3">
                  <span className="min-w-0">
                    <span className="block font-medium text-[#071d38] [overflow-wrap:anywhere]">
                      {item.name}
                    </span>
                    {requestItemIsCustom(item) ? (
                      <span className="block text-xs text-[#7b8693]">Custom item</span>
                    ) : (
                      item.packageDisplay && (
                        <span className="block text-xs text-[#697687] [overflow-wrap:anywhere]">
                          {item.packageDisplay}
                        </span>
                      )
                    )}
                  </span>
                  <span className="shrink-0 text-sm font-semibold tabular-nums text-[#344256]">
                    × {item.quantity}
                    {item.unit ? (
                      <span className="font-normal text-[#697687]"> {item.unit}</span>
                    ) : null}
                  </span>
                </li>
              ))}
            </ul>
          </section>
          {request.data.notes && (
            <section className={card} aria-labelledby="note-title">
              <h2 id="note-title" className="text-sm font-semibold text-[#34445a]">
                Your note
              </h2>
              <p className="mt-2 whitespace-pre-wrap text-sm leading-6 text-[#526174] [overflow-wrap:anywhere]">
                {request.data.notes}
              </p>
            </section>
          )}
          <section className={card} aria-labelledby="timeline-title">
            <h2 id="timeline-title" className="mb-4 text-sm font-semibold text-[#34445a]">
              History
            </h2>
            <RequestDetailTimeline items={request.data.timeline} />
          </section>

          <section aria-label="Request actions" className="space-y-3 pt-2">
            {request.data.canEdit ? (
              <div className="rounded-2xl border border-[#f3d3bd] bg-[#fff8f3] p-4">
                <p className="text-sm leading-6 text-[#624b3b]">{request.data.editGuidance}</p>
                <Link
                  to="/staff/request"
                  search={{ edit: request.data.id }}
                  className="mt-3 flex min-h-12 w-full items-center justify-center gap-2 rounded-xl bg-[#071d38] px-5 font-semibold text-white active:bg-[#0d2a4d]"
                >
                  <Pencil className="size-4" aria-hidden="true" /> Edit request
                </Link>
                {request.data.canCancel && active && (
                  <CancelRequestAction
                    organizationId={active.organizationId}
                    requestId={request.data.id}
                    onCancelled={() => window.scrollTo({ top: 0 })}
                    className="mt-2"
                  />
                )}
              </div>
            ) : (
              request.data.editGuidance && (
                <p
                  role="status"
                  className="rounded-2xl border border-[#e1e6ec] bg-white p-4 text-sm leading-6 text-[#526174]"
                >
                  {request.data.editGuidance}
                </p>
              )
            )}
            <button
              type="button"
              onClick={() => (cart.items.length > 0 ? setConfirmingReplace(true) : requestAgain())}
              className="flex min-h-12 w-full items-center justify-center gap-2 rounded-xl border border-[#f56600] bg-white px-5 font-semibold text-[#d95700] active:bg-[#fff3ea]"
            >
              <RotateCcw className="size-4" aria-hidden="true" /> Request again
            </button>
            <p className="text-center text-xs text-[#7a8491]">
              Copies these items into a new request you can change before submitting.
            </p>
          </section>
        </>
      )}
      <AlertDialog open={confirmingReplace} onOpenChange={setConfirmingReplace}>
        <AlertDialogContent className="w-[calc(100%-2rem)] rounded-2xl">
          <AlertDialogHeader>
            <AlertDialogTitle>Replace your current request?</AlertDialogTitle>
            <AlertDialogDescription>
              Your unsent request has {describeCartCount(cart.items)}. Requesting again replaces
              them with the items from this request.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter className="gap-2">
            <AlertDialogCancel className="min-h-12 rounded-xl">
              Keep current request
            </AlertDialogCancel>
            <AlertDialogAction
              onClick={requestAgain}
              className="min-h-12 rounded-xl bg-[#f56600] font-semibold text-white hover:bg-[#d95700]"
            >
              Replace items
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

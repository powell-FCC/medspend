import { useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { Loader2, XCircle } from "lucide-react";
import { useRef, useState } from "react";
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
import { cancelSubmittedSupplyRequestFn } from "@/lib/supply-requests.functions";
import { cn } from "@/lib/utils";
import { CANCEL_REQUEST_CONFIRMATION } from "@/supply-requests/staff-request-cart";

// Phase 6C.2: the requester's only cancellation path. Nothing changes until the
// requester confirms; the database RPC decides whether cancellation is still allowed.
// Radix focuses "Keep request" when the dialog opens, so Enter never cancels by accident.
export function CancelRequestAction({
  organizationId,
  requestId,
  onCancelled,
  className,
}: {
  organizationId: string;
  requestId: string;
  onCancelled: () => void;
  className?: string;
}) {
  const cancelFn = useServerFn(cancelSubmittedSupplyRequestFn);
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const cancelling = useRef(false);
  const [error, setError] = useState<string | null>(null);

  async function confirmCancel(event: React.MouseEvent) {
    // Keep the dialog open until the outcome is known.
    event.preventDefault();
    if (cancelling.current) return;
    cancelling.current = true;
    setBusy(true);
    setError(null);
    let cancelled = false;
    try {
      await cancelFn({ data: { organizationId, requestId } });
      cancelled = true;
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "We couldn't cancel this request.");
    } finally {
      // Refresh either way: a failed cancel may mean review has started.
      await queryClient.invalidateQueries({ queryKey: ["me", organizationId] });
      cancelling.current = false;
      setBusy(false);
    }
    if (cancelled) {
      setOpen(false);
      onCancelled();
    }
  }

  return (
    <>
      <button
        type="button"
        onClick={() => {
          setError(null);
          setOpen(true);
        }}
        className={cn(
          "flex min-h-12 w-full items-center justify-center gap-2 rounded-xl border border-[#f1cbd0] bg-white px-5 font-semibold text-[#a83340] active:bg-[#fff0f1]",
          className,
        )}
      >
        <XCircle className="size-4" aria-hidden="true" /> Cancel request
      </button>
      <AlertDialog open={open} onOpenChange={(next) => !busy && setOpen(next)}>
        <AlertDialogContent className="w-[calc(100%-2rem)] rounded-2xl">
          <AlertDialogHeader>
            <AlertDialogTitle>{CANCEL_REQUEST_CONFIRMATION.title}</AlertDialogTitle>
            <AlertDialogDescription>{CANCEL_REQUEST_CONFIRMATION.body}</AlertDialogDescription>
          </AlertDialogHeader>
          {error && (
            <p role="alert" className="rounded-xl bg-[#fff0f1] p-3 text-sm text-[#a83340]">
              {error}
            </p>
          )}
          <AlertDialogFooter className="gap-2">
            <AlertDialogCancel disabled={busy} className="min-h-12 rounded-xl">
              {CANCEL_REQUEST_CONFIRMATION.keep}
            </AlertDialogCancel>
            <AlertDialogAction
              onClick={(event) => void confirmCancel(event)}
              disabled={busy}
              aria-busy={busy}
              className="min-h-12 gap-2 rounded-xl bg-[#b42318] font-semibold text-white hover:bg-[#912018]"
            >
              {busy && <Loader2 className="size-4 animate-spin" aria-hidden="true" />}
              {busy ? "Cancelling…" : CANCEL_REQUEST_CONFIRMATION.confirm}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}

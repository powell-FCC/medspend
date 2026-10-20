import { createFileRoute, Link, useNavigate, useSearch } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { ArrowLeft, Check, Copy, Loader2, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { z } from "zod";
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
import { listOrgStructureFn } from "@/lib/org-structure.functions";
import {
  getStaffRequestDetailFn,
  submitSupplyRequestFn,
  updateSubmittedSupplyRequestFn,
} from "@/lib/supply-requests.functions";
import { getStaffRequestAgainFn } from "@/lib/staff-workspace.functions";
import {
  STAFF_CART_MAX_LINES,
  addCustomItemToCart,
  addProductToCart,
  cartItemFromRequestItem,
  changeCartItemQuantity,
  createCustomCartItem,
  createStructuredCartItem,
  describeCartCount,
  describeItemCount,
  describeSubmission,
  editRequestTypeIntent,
  removeCartItem,
  resolveEditRequestContextId,
  resolveRequestContextId,
  resolveStaffRequestType,
  toSubmissionItem,
  type StaffProductSelection,
  type StaffRequestCartItem,
} from "@/supply-requests/staff-request-cart";
import { StaffCartList } from "@/components/staff/StaffCartList";
import { useStaffCart } from "@/components/staff/StaffCartProvider";
import { StaffProductPicker } from "@/components/staff/StaffProductPicker";
import { StaffErrorState, StaffListSkeleton } from "@/components/staff/StaffStates";
import {
  useStaffProductSearch,
  useStaffQuickPicks,
} from "@/components/staff/useStaffProductSearch";

const search = z.object({
  type: z.enum(["reorder", "low_stock", "out_of_stock", "new_item"]).optional(),
  // Phase 6C edit mode: the same composer, addressed to one of the requester's own
  // submitted requests. The server decides whether the edit is still allowed.
  edit: z.string().uuid().optional(),
  // Request again: copy a prior request's available lines into a NEW cart. The prior
  // request is only read, and nothing is submitted until the requester submits.
  again: z.string().uuid().optional(),
});

export const Route = createFileRoute("/_authenticated/staff/request")({
  validateSearch: (value) => search.parse(value),
  head: () => ({
    meta: [{ title: "Request supplies — MedSpend" }, { name: "robots", content: "noindex" }],
  }),
  component: RequestRoute,
});

// Remount when switching between creating and editing (or between edited requests) so
// one mode's cart can never be submitted by the other.
function RequestRoute() {
  const { edit } = useSearch({ from: "/_authenticated/staff/request" });
  return <RequestPage key={edit ?? "new"} />;
}

const shortDate = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });

function RequestPage() {
  const { active } = useActiveOrg();
  const routeSearch = useSearch({ from: "/_authenticated/staff/request" });
  const navigate = useNavigate();
  const cart = useStaffCart();
  const [query, setQuery] = useState("");
  // Edit mode works on its own copy, never on the shared new-request cart.
  const [editItems, setEditItems] = useState<StaffRequestCartItem[]>([]);
  const [editNotes, setEditNotes] = useState("");
  const [teamId, setTeamId] = useState("");
  const [locationId, setLocationId] = useState("");
  const [busy, setBusy] = useState(false);
  const submitting = useRef(false);
  const [error, setError] = useState<string | null>(null);
  const [submittedRequestId, setSubmittedRequestId] = useState<string | null>(null);
  const [submittedItemCount, setSubmittedItemCount] = useState(0);
  const [confirmingSubmit, setConfirmingSubmit] = useState(false);
  const [preloadedRequestId, setPreloadedRequestId] = useState<string | null>(null);
  const editRequestId = routeSearch.edit ?? null;
  const isEditMode = !!editRequestId;
  const againRequestId = !isEditMode ? (routeSearch.again ?? null) : null;
  const items = isEditMode ? editItems : cart.items;
  const setItems = isEditMode ? setEditItems : cart.setItems;
  const notes = isEditMode ? editNotes : cart.notes;
  const setNotes = isEditMode ? setEditNotes : cart.setNotes;
  const searchState = useStaffProductSearch(active?.organizationId, query);
  const quickPicks = useStaffQuickPicks(active?.organizationId);
  const submitFn = useServerFn(submitSupplyRequestFn);
  const updateFn = useServerFn(updateSubmittedSupplyRequestFn);
  const fetchDetail = useServerFn(getStaffRequestDetailFn);
  const fetchAgain = useServerFn(getStaffRequestAgainFn);
  const listStructure = useServerFn(listOrgStructureFn);
  const queryClient = useQueryClient();
  const editing = useQuery({
    queryKey: ["me", active?.organizationId, "requests", editRequestId],
    queryFn: () =>
      fetchDetail({ data: { organizationId: active!.organizationId, requestId: editRequestId! } }),
    enabled: !!active && isEditMode,
  });
  const editingRequest = editing.data ?? null;
  const again = useQuery({
    queryKey: ["me", active?.organizationId, "request-again", againRequestId],
    queryFn: () =>
      fetchAgain({ data: { organizationId: active!.organizationId, requestId: againRequestId! } }),
    enabled: !!active && !!againRequestId,
    staleTime: 0,
    gcTime: 0,
  });

  // Preload once per request so background refetches never discard in-progress edits.
  useEffect(() => {
    if (!editingRequest || preloadedRequestId === editingRequest.id) return;
    setItems(editingRequest.items.map(cartItemFromRequestItem));
    setNotes(editingRequest.notes ?? "");
    setTeamId(editingRequest.teamId ?? "");
    setLocationId(editingRequest.locationId ?? "");
    setPreloadedRequestId(editingRequest.id);
  }, [editingRequest, preloadedRequestId, setItems, setNotes]);

  // Request again: fill a fresh cart once, then drop the parameter so a refresh or back
  // navigation never re-copies over the requester's changes. Unavailable lines are
  // listed, never substituted.
  const { replace: replaceCart } = cart;
  useEffect(() => {
    if (!again.data || again.data.requestId !== againRequestId) return;
    const copied = again.data.lines.flatMap((line): StaffRequestCartItem[] => {
      if (line.selection)
        return [createStructuredCartItem(crypto.randomUUID(), line.selection, line.quantity)];
      if (line.freeTextItem)
        return [createCustomCartItem(crypto.randomUUID(), line.freeTextItem, line.quantity)];
      return [];
    });
    replaceCart(copied, {
      requestId: again.data.requestId,
      submittedAt: again.data.submittedAt,
      unavailable: again.data.lines
        .filter((line) => line.availability.status === "unavailable")
        .map((line) => ({ lineId: line.lineId, name: line.name, quantity: line.quantity })),
    });
    void navigate({ to: "/staff/request", search: {}, replace: true });
  }, [again.data, againRequestId, replaceCart, navigate]);

  const structure = useQuery({
    queryKey: ["org", active?.organizationId, "request-context"],
    queryFn: () =>
      listStructure({ data: { organizationId: active!.organizationId, includeArchived: false } }),
    enabled: !!active,
  });
  const teams = structure.data?.teams ?? [];
  const locations = structure.data?.locations ?? [];
  const hasActiveDefaultTeam =
    !!active?.defaultTeamId && teams.some((team) => team.id === active.defaultTeamId);
  const hasActiveDefaultLocation =
    !!active?.defaultLocationId &&
    locations.some((location) => location.id === active.defaultLocationId);
  // Edit mode keeps the request's own team/location unless the requester changes them.
  const resolvedTeamId = isEditMode
    ? resolveEditRequestContextId(editingRequest?.teamId, teamId, active?.defaultTeamId, teams)
    : resolveRequestContextId(active?.defaultTeamId, teamId, teams);
  const resolvedLocationId = isEditMode
    ? resolveEditRequestContextId(
        editingRequest?.locationId,
        locationId,
        active?.defaultLocationId,
        locations,
      )
    : resolveRequestContextId(active?.defaultLocationId, locationId, locations);
  const showTeamSelector = !hasActiveDefaultTeam && teams.length > 1;
  const showLocationSelector = !hasActiveDefaultLocation && locations.length > 1;

  const cartControls = {
    cartItems: items,
    cartFull: items.length >= STAFF_CART_MAX_LINES,
    onAddProduct: (selection: StaffProductSelection) =>
      setItems((current) => addProductToCart(current, crypto.randomUUID(), selection)),
    onChangeQuantity: (key: string, delta: number) =>
      setItems((current) => changeCartItemQuantity(current, key, delta)),
    onRemove: (key: string) => setItems((current) => removeCartItem(current, key)),
  };
  const addCustom = (name: string) =>
    setItems((current) => addCustomItemToCart(current, crypto.randomUUID(), name));

  // The form's submit (button or implicit Enter) never mutates directly. Create mode
  // asks for confirmation first; edit mode saves the existing request in place.
  function submit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    if (items.length === 0 || busy) return;
    if (!resolvedTeamId || !resolvedLocationId) {
      setError("A valid team and location are required. Ask an administrator to configure them.");
      return;
    }
    if (isEditMode) void saveChanges();
    else setConfirmingSubmit(true);
  }

  async function confirmSubmit() {
    setConfirmingSubmit(false);
    // One submission per tap: the ref closes the gap before React re-renders as busy.
    if (submitting.current || items.length === 0) return;
    submitting.current = true;
    setBusy(true);
    try {
      const created = await submitFn({
        data: {
          organizationId: active!.organizationId,
          requestType: resolveStaffRequestType(routeSearch.type, items),
          items: items.map(toSubmissionItem),
          teamId: resolvedTeamId,
          locationId: resolvedLocationId,
          notes: notes.trim() || null,
        },
      });
      setSubmittedItemCount(items.length);
      setSubmittedRequestId(created.id);
      cart.clear();
      await queryClient.invalidateQueries({ queryKey: ["me", active?.organizationId] });
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "We couldn't submit your request.");
    } finally {
      submitting.current = false;
      setBusy(false);
    }
  }

  async function saveChanges() {
    if (!editingRequest || submitting.current) return;
    submitting.current = true;
    setBusy(true);
    try {
      const saved = await updateFn({
        data: {
          organizationId: active!.organizationId,
          requestId: editingRequest.id,
          requestType: resolveStaffRequestType(
            editRequestTypeIntent(editingRequest.requestType),
            items,
          ),
          items: items.map(toSubmissionItem),
          teamId: resolvedTeamId,
          locationId: resolvedLocationId,
          notes: notes.trim() || null,
        },
      });
      setSubmittedItemCount(items.length);
      setSubmittedRequestId(saved.id);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "We couldn't save your changes.");
    } finally {
      // Refresh either way: a failed save may mean review has started.
      await queryClient.invalidateQueries({ queryKey: ["me", active?.organizationId] });
      submitting.current = false;
      setBusy(false);
    }
  }

  if (submittedRequestId)
    return (
      <div
        role="status"
        className="flex min-h-[65dvh] flex-col items-center justify-center text-center"
      >
        <span className="flex size-16 items-center justify-center rounded-full bg-[#edf7f1] text-[#286443]">
          <Check className="size-8" aria-hidden="true" />
        </span>
        <h1 className="mt-6 text-2xl font-semibold tracking-tight">
          {isEditMode ? "Changes saved" : "Request submitted"}
        </h1>
        <p className="mt-2 max-w-xs text-sm leading-6 text-[#667384]">
          {isEditMode
            ? "You can keep making changes until review begins."
            : `${describeItemCount(submittedItemCount)} sent for review. You can still edit this request until review begins.`}
        </p>
        <div className="mt-8 w-full max-w-sm space-y-3">
          <Link
            to="/staff/requests/$id"
            params={{ id: submittedRequestId }}
            className="flex min-h-12 w-full items-center justify-center rounded-xl bg-[#071d38] px-5 font-semibold text-white active:bg-[#0d2a4d]"
          >
            View request
          </Link>
          {!isEditMode && (
            <button
              type="button"
              onClick={() => {
                setSubmittedRequestId(null);
                setQuery("");
                setError(null);
              }}
              className="flex min-h-12 w-full items-center justify-center rounded-xl border border-[#f56600] font-semibold text-[#d95700] active:bg-[#fff3ea]"
            >
              Request something else
            </button>
          )}
          <Link
            to="/staff"
            className="flex min-h-12 w-full items-center justify-center text-sm font-semibold text-[#526174]"
          >
            Back to Staff Workspace
          </Link>
        </div>
      </div>
    );

  if (isEditMode && !editingRequest)
    return (
      <div className="space-y-6">
        <Link
          to="/staff/requests"
          className="inline-flex min-h-11 items-center gap-2 py-2 text-sm font-semibold text-[#526174]"
        >
          <ArrowLeft className="size-4" /> My Requests
        </Link>
        {editing.isError ? (
          <div role="alert" className="rounded-2xl bg-[#fff0f1] p-5 text-sm text-[#a83340]">
            This request isn't available.
          </div>
        ) : (
          <StaffListSkeleton label="Loading request" rows={2} />
        )}
      </div>
    );

  if (editingRequest && !editingRequest.canEdit)
    return (
      <div className="space-y-6">
        <Link
          to="/staff/requests/$id"
          params={{ id: editingRequest.id }}
          className="inline-flex min-h-11 items-center gap-2 py-2 text-sm font-semibold text-[#526174]"
        >
          <ArrowLeft className="size-4" /> Back to request
        </Link>
        <div
          role="status"
          className="rounded-2xl border border-[#e1e6ec] bg-white p-5 text-sm leading-6 text-[#526174]"
        >
          {editingRequest.editGuidance ?? "This request can no longer be edited."}
        </div>
      </div>
    );

  if (againRequestId)
    return (
      <div className="space-y-4">
        {again.isError ? (
          <>
            <StaffErrorState
              message="We couldn't copy that request."
              onRetry={() => void again.refetch()}
            />
            <Link
              to="/staff/requests"
              className="inline-flex min-h-11 items-center gap-2 py-2 text-sm font-semibold text-[#526174]"
            >
              <ArrowLeft className="size-4" /> My Requests
            </Link>
          </>
        ) : (
          <div role="status" className="flex items-center gap-2 py-6 text-sm text-[#526174]">
            <Loader2 className="size-4 animate-spin" aria-hidden="true" />
            Copying your items into a new request…
          </div>
        )}
      </div>
    );

  const confirmation = describeSubmission(items, {
    teamName: teams.find((team) => team.id === resolvedTeamId)?.name ?? null,
    locationName: locations.find((location) => location.id === resolvedLocationId)?.name ?? null,
  });
  const hasItems = items.length > 0;
  const againSource = !isEditMode ? cart.againSource : null;

  return (
    <div>
      {editingRequest && (
        <Link
          to="/staff/requests/$id"
          params={{ id: editingRequest.id }}
          className="mb-3 inline-flex min-h-11 items-center gap-2 py-2 text-sm font-semibold text-[#526174]"
        >
          <ArrowLeft className="size-4" /> Back to request
        </Link>
      )}
      <header>
        <p className="text-xs font-semibold uppercase tracking-[0.16em] text-[#697687]">
          {isEditMode ? "Edit Request" : "New Request"}
        </p>
        <h1 className="mt-1 text-[1.7rem] font-semibold tracking-tight">
          {isEditMode
            ? "Update your request"
            : hasItems
              ? "Review your request"
              : "What do you need?"}
        </h1>
        {isEditMode && (
          <p className="mt-2 text-sm leading-6 text-[#667384]">
            You can make changes until this request enters review.
          </p>
        )}
      </header>
      <form onSubmit={submit} className="mt-6 space-y-7">
        {againSource && (
          <section
            aria-label="Copied from an earlier request"
            className="rounded-2xl border border-[#dce3eb] bg-[#f3f6f9] p-4 text-sm leading-6 text-[#344256]"
          >
            <div className="flex items-start gap-3">
              <Copy className="mt-1 size-4 shrink-0 text-[#526174]" aria-hidden="true" />
              <div className="min-w-0 flex-1">
                <p>
                  Copied from your request on {shortDate.format(new Date(againSource.submittedAt))}.
                  This is a new request — nothing is sent until you submit it.
                </p>
                {againSource.unavailable.length > 0 && (
                  <div role="alert" className="mt-2 text-[#8d2d39]">
                    <p className="font-semibold">
                      {againSource.unavailable.length === 1
                        ? "1 item is no longer available and was not added:"
                        : `${againSource.unavailable.length} items are no longer available and were not added:`}
                    </p>
                    <ul className="mt-1 list-disc pl-5">
                      {againSource.unavailable.map((line) => (
                        <li key={line.lineId} className="[overflow-wrap:anywhere]">
                          {line.name} × {line.quantity}
                        </li>
                      ))}
                    </ul>
                    <p className="mt-1 text-[#526174]">
                      Search for a replacement if you still need it.
                    </p>
                  </div>
                )}
              </div>
              <button
                type="button"
                onClick={cart.dismissAgainSource}
                aria-label="Dismiss"
                className="-mr-2 -mt-2 flex size-11 shrink-0 items-center justify-center rounded-full text-[#637080] active:bg-[#e6ebf0]"
              >
                <X className="size-4" aria-hidden="true" />
              </button>
            </div>
          </section>
        )}

        {hasItems && (
          <section aria-labelledby="cart-title">
            <h2 id="cart-title" className="mb-2 text-[0.95rem] font-semibold text-[#071d38]">
              Your request · {describeCartCount(items)}
            </h2>
            <StaffCartList
              items={items}
              onChangeQuantity={cartControls.onChangeQuantity}
              onRemove={cartControls.onRemove}
            />
          </section>
        )}

        <section aria-labelledby="add-items-title">
          <h2
            id="add-items-title"
            className={hasItems ? "mb-2 text-[0.95rem] font-semibold text-[#071d38]" : "sr-only"}
          >
            {hasItems ? "Add more items" : "Search supplies"}
          </h2>
          <StaffProductPicker
            inputId="supply-search"
            label="Search supplies"
            query={query}
            onQueryChange={setQuery}
            search={searchState}
            quickPicks={quickPicks}
            onAddCustom={addCustom}
            {...cartControls}
          />
        </section>

        {hasItems && (
          <>
            {(showTeamSelector || showLocationSelector) && (
              <section className="grid gap-4">
                {showTeamSelector && (
                  <label className="text-sm font-semibold">
                    Team
                    <select
                      aria-label="Team"
                      required
                      value={teamId}
                      onChange={(event) => setTeamId(event.target.value)}
                      className="mt-2 min-h-12 w-full rounded-xl border border-[#dce2e8] bg-white px-3 font-normal"
                    >
                      <option value="">Select team</option>
                      {teams.map((team) => (
                        <option key={team.id} value={team.id}>
                          {team.name}
                        </option>
                      ))}
                    </select>
                  </label>
                )}
                {showLocationSelector && (
                  <label className="text-sm font-semibold">
                    Location
                    <select
                      aria-label="Location"
                      required
                      value={locationId}
                      onChange={(event) => setLocationId(event.target.value)}
                      className="mt-2 min-h-12 w-full rounded-xl border border-[#dce2e8] bg-white px-3 font-normal"
                    >
                      <option value="">Select location</option>
                      {locations.map((location) => (
                        <option key={location.id} value={location.id}>
                          {location.name}
                        </option>
                      ))}
                    </select>
                  </label>
                )}
              </section>
            )}
            <section>
              <label htmlFor="request-note" className="text-sm font-semibold">
                Add a note <span className="font-normal text-[#7b8693]">(optional)</span>
              </label>
              <textarea
                id="request-note"
                rows={3}
                maxLength={5000}
                value={notes}
                onChange={(event) => setNotes(event.target.value)}
                placeholder="Size, location, or anything helpful"
                className="mt-2 w-full resize-none rounded-2xl border border-[#dce2e8] bg-white p-4 text-base outline-none placeholder:text-[#9aa3ad] focus:border-[#f56600] focus:ring-4 focus:ring-[#f56600]/10"
              />
            </section>
          </>
        )}
        {isEditMode && items.length === 0 && (
          <p className="rounded-xl bg-[#f4f6f8] p-3 text-sm text-[#526174]">
            A request needs at least one item. Add an item to save your changes.
          </p>
        )}

        {hasItems && (
          <div className="sticky bottom-[calc(4.75rem+env(safe-area-inset-bottom))] z-20 -mx-1 space-y-2 rounded-2xl bg-[#f5f7f9]/95 px-1 pb-1 pt-2 backdrop-blur">
            {error && (
              <p role="alert" className="rounded-xl bg-[#fff0f1] p-3 text-sm text-[#a83340]">
                {error}
              </p>
            )}
            <button
              type="submit"
              disabled={busy || !hasItems}
              aria-busy={busy}
              className="flex min-h-14 w-full items-center justify-center gap-2 rounded-2xl bg-[#f56600] px-5 text-base font-semibold text-white shadow-[0_10px_25px_rgba(245,102,0,0.22)] transition active:scale-[0.99] active:bg-[#dc5c00] disabled:opacity-60"
            >
              {busy && <Loader2 className="size-5 animate-spin" aria-hidden="true" />}
              {isEditMode
                ? busy
                  ? "Saving…"
                  : "Save changes"
                : busy
                  ? "Submitting…"
                  : `Submit request · ${describeCartCount(items)}`}
            </button>
          </div>
        )}
      </form>
      <AlertDialog open={confirmingSubmit} onOpenChange={setConfirmingSubmit}>
        <AlertDialogContent className="w-[calc(100%-2rem)] rounded-2xl">
          <AlertDialogHeader>
            <AlertDialogTitle>{confirmation.title}</AlertDialogTitle>
            <AlertDialogDescription>{confirmation.body}</AlertDialogDescription>
            {confirmation.context && (
              <p className="text-sm text-[#697687]">{confirmation.context}</p>
            )}
          </AlertDialogHeader>
          <AlertDialogFooter className="gap-2">
            <AlertDialogCancel className="min-h-12 rounded-xl">Keep editing</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => void confirmSubmit()}
              disabled={busy}
              className="min-h-12 rounded-xl bg-[#f56600] font-semibold text-white hover:bg-[#d95700]"
            >
              Submit request
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

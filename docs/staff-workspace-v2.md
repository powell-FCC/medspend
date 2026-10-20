# Staff Workspace v2

Staff get simplicity; admins keep information density. The staff side is a mobile-first action workspace for three jobs: request supplies, see what happened to my requests, and quickly repeat common requests.

No migration. Everything here uses the production schema, the existing RLS policies and the existing request RPCs.

## Structure

```
Staff Workspace (/staff)
  Ready for you          only when a request is 'received' (admin "Ready for Staff")
  Request Supplies       search + one-tap add, custom-item fallback
  My Requests            up to 3 in progress, "View all"
  Frequent & Recent      requester's usual items, one-tap add

Request (/staff/request) empty cart: discovery (search, frequent, recent)
                         with items: review cart, add more, note, submit
My Requests (/staff/requests)       in progress (ready first), past requests paged
Request detail (/staff/requests/:id) status, items, note, latest update, history,
                                     Edit (Phase 6C, submitted only), Request again
```

A future primary action (Scan Inventory QR) goes beside Request Supplies on the workspace and as a bottom-nav tab. Nothing in this branch reserves or stubs it.

## Cart

- The cart lives in `StaffCartProvider` inside `StaffAppShell`, so items added on the workspace survive moving to review and back. It is in memory only. A reload, sign-out or organization switch starts a fresh cart.
- Adding a product already in the cart increases its quantity. Lines merge only when every identity field matches (product, inventory item, vendor product, catalog vendor product), so one source is never silently swapped for another.
- The cart stops at 50 lines, the submission RPC's limit.
- "N items · Review request" is docked above the bottom navigation whenever the cart has items, except on the request page. The request page has its own sticky "Submit request · N items" action.
- Phase 6C edit mode keeps its own copy of the lines and never touches the shared cart.

## Submission

Unchanged canonical path: `submitSupplyRequestFn` → `submit_supply_request`, with the Phase 6C confirmation dialog. A ref guard and the busy state prevent a double submit. After submitting, the success screen says "Request submitted" (not approved, not ordered) and offers View request, Request something else, and Back to Staff Workspace.

## Frequent and Recent

`getStaffQuickPicksFn` (read-only):

- Reads the caller's own 40 most recent non-declined requests in the active organization (`requested_by = auth.uid()`), then their structured lines in one query. Custom lines are skipped.
- Groups lines by the same identity key `search_supply_request_products` deduplicates on: organization product, else catalog vendor product, else inventory item.
- **Frequent**: products in at least 2 of those requests, ranked by number of requests (not quantity), then recency. At most 6.
- **Recent**: most recently requested products, each once, excluding anything shown under Frequent. At most 6.
- Only products that are still requestable are offered (see availability below).

## Request again

`getStaffRequestAgainFn` (read-only, owner-only) returns the prior request's lines with availability. The composer copies the available lines, with their stored identity tuples, into a new editable cart and lists the lines it left out. Nothing is submitted, and the historical request is never reopened or changed. If the cart already had items, the detail page asks before replacing them. The note is not copied.

## Availability (quick picks and request again)

These are the per-line rules from `replace_supply_request_items`, as far as a staff member can see them under RLS:

| Identity               | Offered when                                                    |
| ---------------------- | --------------------------------------------------------------- |
| product                | org product is `active` and `staff_requestable`                 |
| inventory item         | org inventory row is visible (RLS returns active rows only)     |
| catalog vendor product | active, not discontinued, its catalog product and vendor active |
| vendor product         | its product passes (vendor products are admin-only under RLS)   |

The submission RPC re-validates every line and stays the authority.

## Statuses

Presentation only; the database statuses are unchanged.

| Status       | Label        | Description                   | Group       |
| ------------ | ------------ | ----------------------------- | ----------- |
| submitted    | Submitted    | Waiting for review            | in progress |
| under_review | Under review | Being reviewed                | in progress |
| approved     | Approved     | Approved, not yet ordered     | in progress |
| ordered      | Ordered      | Ordered, waiting for delivery | in progress |
| received     | Ready        | Received and ready for you    | ready       |
| completed    | Completed    | Request completed             | past        |
| denied       | Declined     | This request was declined     | past        |

`received` keeps the existing staff label "Ready", matching the admin "Ready for Staff" queue.

## Needs attention

No status asks the requester to act. Declined is terminal, so it is no longer grouped as "action required", and the workspace has no "Needs attention" section. The workspace surfaces "Ready for you" for `received` requests, which the admin workflow already defines as ready for staff.

## Timeline

Only stored events: the request's `created_at` ("Submitted") and the staff-safe projection `list_staff_supply_request_updates` (status changes, staff-visible notes, requester edits). Nothing is inferred from the current status. Requests whose transitions predate audited updates show only "Submitted" plus their current status in the header.

## Bounds

- Workspace and My Requests: up to 100 open requests plus 20 past requests per page (max 200). Items and staff-safe updates load in one query each for the page.
- Quick picks: 40 requests, then one query per identity table plus one specification RPC.
- Search: unchanged (debounced, 2+ characters, 20 results, canonical RPC).

## Not built here

QR inventory, inventory adjustments or locations, purchasing, new statuses, cancellation, analytics events (no internal event system exists), recommendations.

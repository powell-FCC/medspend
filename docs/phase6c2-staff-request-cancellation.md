# Phase 6C.2: staff request cancellation

## Problem

Phase 6C let a requester edit a submitted request, but a request cannot be saved with zero items. A requester who removed every line had no valid action left, and a requester who no longer needed anything had to ask an admin to decline it.

Phase 6C.2 adds an explicit **Cancel request** action. Cancellation is a lifecycle event, not a deletion, and a request is never saved empty.

## Lifecycle

```
submitted ──(requester: cancel_submitted_supply_request)──> cancelled   (terminal)
    │
    └──> under_review ──> approved ──> ordered ──> received ──> completed
    └──> denied
```

- **Cancellable state:** exactly the Phase 6C edit window. That is `status = 'submitted'` and no commitment exists, which is always true for `submitted` and checked defensively. `canRequesterCancelSupplyRequest` is defined as `canRequesterEditSupplyRequest`, so the two rules cannot drift.
- `under_review` and every later status cannot be cancelled. A `denied` request gets its own message.
- `cancelled` is terminal. It cannot be edited, cancelled again, or "uncancelled". The admin transition matrix has no entry for it, so `transition_supply_request` raises `Invalid supply request transition: cancelled to X`, and no admin path leads into it either: `approved to cancelled` is rejected.
- `denied` is not overloaded. A cancelled request is never relabelled as declined.

## Historical data

Cancelling changes only `supply_requests.status`. The request row, its lines, request-wide note, team, location and request type are untouched. Earlier audit rows, including Phase 6C `requester_edited` events, are kept. The request stays viewable by the requester and the admin.

## Schema and migrations (local only; not applied)

`supply_request_status` is a Postgres enum. Two migrations, because a new enum value cannot be used in the transaction that adds it:

| File                                                     | Change                                                                                                                                                                                                                                                                                                              |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `20261020120000_phase6c2_cancelled_request_status.sql`   | `ALTER TYPE public.supply_request_status ADD VALUE IF NOT EXISTS 'cancelled'`. Appended; no existing value, row or comparison changes.                                                                                                                                                                              |
| `20261020120100_phase6c2_staff_request_cancellation.sql` | Single transaction with a preflight guard. It adds the `cancel_submitted_supply_request` RPC and replaces the `supply_request_updates_event_kind_check` constraint to allow the cancellation event. `update_submitted_supply_request` is `CREATE OR REPLACE`d, identical except for a specific "cancelled" message. |

The migrations rewrite no data: no status remapping, no deletes, and no policy, grant or unrelated function is dropped or recreated. The preflight refuses to run if the enum value is missing, if the RPC already exists, or if any `cancelled` request or update row already exists.

Release checks live in `supabase/release/phase6c2/`. `precheck.sql` and `postcheck.sql` are read-only, assertion-backed fingerprints, and the README lists the exact pre/post diff to expect. Both were validated end to end on a disposable database migrated from `main`.

Ship order: apply the two migrations in order, then deploy the application. An older UI never offers cancellation, and the new UI's only new call is `cancel_submitted_supply_request`. `src/integrations/supabase/types.ts` was hand-edited (enum value and RPC). Before release, `supabase gen types` was run against disposable databases before and after the migrations, and its delta matched the hand edits exactly. Regenerate from production after applying, as a final check.

## Canonical mutation: `cancel_submitted_supply_request(_organization_id, _request_id)`

`SECURITY DEFINER`, executable by `authenticated` only (`PUBLIC` and `anon` revoked). It runs in one transaction:

1. require `auth.uid()` (`Not authenticated`, `42501`) and active organization membership (`Not a member of this organization`, `42501`);
2. `SELECT … FOR UPDATE` the organization-scoped request. This is the same row lock as `update_submitted_supply_request`, `decide_supply_request`, `transition_supply_request` and commitment creation;
3. reject another member's request as `Supply request not found` (`P0002`), indistinguishable from a missing one. Admins get no cancel action: the RPC is requester-only even for an admin of the organization;
4. if already `cancelled`, return `{ alreadyCancelled: true, cancelledAt }` with the original time. No row write and no new event;
5. reject `denied` with `This request has been declined and can no longer be cancelled.` (`55000`);
6. reject any other non-`submitted` status, or any commitment, with `This request has already entered review and can no longer be cancelled.` (`55000`);
7. set `status = 'cancelled'` and insert one audit row;
8. return `{ id, status, alreadyCancelled: false, cancelledAt, updatedAt }`.

The client sends only `organizationId` and `requestId`. The requester is always `auth.uid()`. The server function `cancelSubmittedSupplyRequestFn` checks membership and delegates; it performs no table writes.

### Concurrency

Verified with two concurrent sessions against a disposable database:

- **Admin approves first:** the requester's cancel waits on the row lock. It then fails with "already entered review"; the request stays `approved` with its single commitment and no cancellation event.
- **Requester cancels first:** an admin approve from a stale screen waits. It then fails with `This request has already been decided. Refresh the inbox.`, with no commitment and no decision audit row.

Because `updated_at` advances on cancellation, any decision prepared before it is also stale under the Phase 6C version check.

## Event and audit

One `supply_request_updates` row per cancellation:

- `event_kind = 'requester_cancelled'`, `author_id` = the requester, `status_from = 'submitted'`, `status_to = 'cancelled'`, no notes; `created_at` is the cancellation time;
- the check constraint allows that shape only, and requires any row with `status_to = 'cancelled'` to be a requester cancellation. An admin's direct write (`sru_write_admin`) therefore cannot forge an ordinary "cancelled" status row or attach a note;
- staff read it through the unchanged `list_staff_supply_request_updates` (it already returns rows with a `status_to`, never `internal_note`). The staff timeline shows **Request cancelled** with the stored timestamp. `buildStaffRequestTimeline` maps only stored events and infers nothing from the current status;
- admins see **Cancelled by requester** in the request's activity log.

## Staff UI

- Status label **Cancelled** ("You cancelled this request"), in its own neutral `CANCELLED` badge group.
- **Request detail, submitted:** **Cancel request** (red outline) below **Edit request**.
- **Edit composer with items:** a separate "No longer need this request?" section below the form, away from the sticky **Save changes** bar.
- **Edit composer after removing the final line:** "No items left in this request." The supporting copy says a request can't be saved without items: add one to keep it, or cancel it. **Cancel request** is shown in the same card. No save action is rendered, and the save path still refuses an empty cart.
- **Confirmation:** the existing `AlertDialog`, not `window.confirm`. It reads "Cancel this request?" / "This request will no longer be reviewed or fulfilled. It will remain in your request history." with **Keep request** and a red **Cancel request**. Radix focuses **Keep request**, so Enter or Escape never cancels by accident. The confirm button shows "Cancelling…" and both buttons are disabled while the call runs. A failed cancel keeps the dialog open with the server message and refreshes the request.
- **After cancelling:** the detail refreshes in place. From edit mode, the requester lands on the cancelled request's detail page.
- **Cancelled detail:** items, note and history stay visible, along with "You cancelled this request. It will not be reviewed or fulfilled." There is no edit or cancel action. Opening the edit URL shows the same read-only guidance.
- **Request again** is unchanged and available. It copies still-requestable lines into a new cart and never reopens the cancelled request.

## Filtering

| Surface                                         | Behavior                                                                                                                                                                                                                                         |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Staff Workspace "in progress" / "Ready for you" | `STAFF_OPEN_STATUSES` is unchanged, so `cancelled` is never loaded as open. `isStaffOpenRequest` excludes the `CANCELLED` group.                                                                                                                 |
| My Requests history                             | `STAFF_PAST_STATUSES` gains `cancelled`. `isStaffPastRequest` includes it.                                                                                                                                                                       |
| Frequent & Recent                               | `QUICK_PICK_EXCLUDED_STATUSES = ['denied', 'cancelled']`, applied at the request query, so no cancelled line is ever loaded.                                                                                                                     |
| Admin Request Inbox                             | `cancelled` maps to the existing history group (`COMPLETED`, like `denied`): "Cancelled by requester", no next action. It never appears in Needs Review, Awaiting Order, Awaiting Delivery or Ready for Staff. The inbox is otherwise unchanged. |
| Command Center                                  | "Awaiting approval" counts `status IN ('submitted', 'under_review')` only.                                                                                                                                                                       |
| Inventory intelligence                          | `OPEN_REQUEST_STATUSES` is an explicit list without `cancelled`.                                                                                                                                                                                 |

## Budget and commitment behavior

Phase 6A.2 creates a commitment only on approval (`create_supply_request_commitment` requires `approved`/`ordered`/`received`/`completed`). Cancellation is only possible from `submitted`, before approval, so a cancellable request never has a commitment. Cancellation has **no commitment, budget, settlement-candidate or Command Center effect**:

- it creates and releases nothing (the existing `release_kind = 'cancelled'` is an unrelated commitment-release reason and is not used);
- settlement candidates are `received`/`completed` only;
- budget summary math reads commitments and invoices, not request statuses.

The narrow boundary is preserved: cancelling after approval is not possible. Admins still end approved or ordered work by declining it, which keeps releasing the commitment as before.

## Authorization boundary

Authorization lives in the database RPC. Staff gain no table privileges:

- direct `UPDATE … SET status = 'cancelled'` by staff matches no row (there is no staff update policy). By an admin, it is rejected by the Phase 6C lifecycle guard trigger;
- staff cannot insert audit rows. The new constraint stops an admin from forging a non-requester "cancelled" row;
- a deactivated member, another member, another organization and an unauthenticated caller are all rejected (SQL behavior test).

## Tests

- `tests/phase6c2-staff-request-cancellation.test.ts`: lifecycle and window, status mapping, open/past grouping, timeline mapping, Frequent/Recent exclusion, Request again from a cancelled request, admin queues, empty-edit behavior and copy, confirmation wiring, structural checks of both migrations, the RPC, the edit-RPC diff, the server function and budget queries, plus rendered states (submitted and cancelled detail, emptied edit, cancelled edit URL, My Requests history).
- `supabase/tests/phase6c2_staff_request_cancellation_behavior.sql`: rollback-only coverage. It checks own cancel; rejection of other members, other organizations, admins, deactivated and unauthenticated callers; every ineligible status; that rejected attempts write nothing; no direct cancel or forged events; preserved lines, note and fields; one authoritative event; idempotent repeat; no edit after cancel; the staff projection; the admin awaiting-approval count; no admin decide or transition from or into `cancelled`; no commitment; grants; and unchanged denied/completed edit messages.
- Existing assertions updated for the new status: 6C "no new statuses", Workspace v2 status table and quick-pick query, and the catalog vendor test that required its migration to be the newest file.

## Non-goals

No admin cancel action, no uncancel, no cancellation after review begins, no Admin Request Inbox redesign, no Staff Workspace redesign, and no change to approval, commitment, budget, purchasing, inventory or invoice behavior.

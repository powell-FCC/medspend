# Phase 6C: staff request forgiveness

## Problem

Beta staff feedback: a staff member submitted a supply request before they had finished it and had no way to get it back.

Two things made this likely:

1. **Submission was easy to trigger by accident.** The request composer is a single `<form>`. Once the cart had one item, the submit button was rendered, so pressing Enter in the search box or the "Can't find the item?" field submitted the whole request immediately (implicit form submission), with no confirmation.
2. **There was no recovery path.** After submission the request was read-only to its requester.

Phase 6C fixes both: accidental submission is harder, and a requester can correct their own request until admin review begins.

## Eligibility rule

A requester may edit a request only when all of these hold:

- the caller is authenticated;
- the caller is an **active** member of the request's organization;
- the request belongs to that organization;
- the request was created by the caller (`requested_by = auth.uid()`);
- `status = 'submitted'`;
- no commitment exists for the request (always true for `submitted`; checked defensively).

## Lifecycle boundary

```
submitted  ──(requester may edit, any number of times)──┐
    │                                                    │
    └──> under_review ──> approved ──> ordered ──> received ──> completed
    └──> denied
```

- Editing keeps the **same request ID** and leaves `status = 'submitted'`. There is no `submitted → draft` regression and no new status.
- The moment an admin moves the request to `under_review` (directly, or implicitly when approving from `submitted` through `decide_supply_request`), the request is read-only to staff.
- `under_review`, `approved`, `ordered`, `received`, `completed`, and `denied` are all locked.

The UI uses `canRequesterEditSupplyRequest(status)` only to avoid offering a doomed action. **The database RPC is the enforcement boundary.**

## Editable fields

The same staff-controlled fields as creation, through the same composer:

- line items (add, remove), using the same inventory / organization product / vendor product / global catalog / custom identities;
- quantities;
- request-wide note;
- team and location (when the composer shows selectors);
- `request_type` is re-derived from the edited cart exactly as at creation (`reorder` ↔ `new_item`). An explicit `low_stock` / `out_of_stock` report is preserved.

When team/location are omitted, an edit keeps the request's **current** team/location (falling back to membership defaults only if those are no longer active). Edit mode in the UI likewise preloads the request's own team/location rather than silently switching to the requester's current default.

## Database implementation

Migration: `supabase/migrations/20261009120000_phase6c_staff_request_forgiveness.sql` (local only; not applied).

| Object | Kind | Access |
| --- | --- | --- |
| `resolve_supply_request_context(org, requester, team, location)` | new private helper | revoked from `PUBLIC`, `anon`, `authenticated` |
| `replace_supply_request_items(org, request, items)` | new private helper | revoked from `PUBLIC`, `anon`, `authenticated` |
| `submit_supply_request(...)` | **same signature**, now delegates to the two helpers | unchanged (`authenticated`) |
| `update_submitted_supply_request(org, request, type, team, location, notes, items)` | new RPC, returns `jsonb` | `authenticated` only |
| `supply_request_updates.event_kind` | new nullable column + check constraint | existing RLS |
| `list_staff_supply_request_updates(org, ids)` | recreated with an `event_kind` result column | unchanged (`authenticated`) |

### Shared validation (no parallel request system)

The Phase 5A.7 context and line rules were moved, verbatim, out of `submit_supply_request` into the two private helpers. Submission and editing call the same code, so identity, quantity, package, team, location, membership-default, and organization-ownership rules cannot drift. The rollback-only 5A.7, 5A.8, 5A.9, 6A.2, and 6B behavior suites pass unchanged against the refactored submission.

### `update_submitted_supply_request`

In one transaction:

1. require `auth.uid()` and active organization membership;
2. `SELECT … FOR UPDATE` the request row scoped to the organization — the same row lock taken by `transition_supply_request`, `decide_supply_request`, and commitment creation;
3. reject another member's request as `Supply request not found` (`P0002`, indistinguishable from a missing request);
4. reject any status other than `submitted` (`55000`);
5. resolve and validate team/location with the shared context helper;
6. update `request_type`, `team_id`, `location_id`, `notes` on the **same row**;
7. replace the line set with the shared line helper (delete + validated insert of the complete set, then refresh the legacy first-line mirror columns);
8. insert a `requester_edited` audit row;
9. return `{ id, status, itemCount, updatedAt }`.

Any validation error aborts the whole statement; nothing is partially written. There is no client-side delete/recreate choreography and no new request row.

Line IDs are not preserved across an edit (the request ID is). This is safe because no other table can reference a `submitted` request's lines: commitment snapshots are only created at approval and use `ON DELETE RESTRICT`.

## Authorization

Staff may edit only their own request, in an organization where they are an active member, while it is `submitted`. Specifically denied (and covered by the SQL behavior test):

- another member's request in the same organization → `Supply request not found`;
- a caller from another organization → `Not a member of this organization` (or not found when scoped to their own organization);
- a deactivated requester → `Not a member of this organization`;
- `under_review`, `approved`, `ordered`, `received`, `completed` → `This request has already entered review and can no longer be edited.`;
- `denied` → `This request has been declined and can no longer be edited.`

Staff gain no new table privileges. The helpers are not executable by `authenticated`. Direct staff `UPDATE` on `supply_requests`, direct line deletion, and forged `requester_edited` audit inserts are all still blocked by existing RLS (verified in the behavior test). Owner/admin workflows and RPCs are unchanged.

## Race-condition behavior

Scenario: the requester opens a submitted request; an admin moves it to `under_review`; the requester then clicks **Save changes**.

- The edit RPC and every admin lifecycle RPC lock the same request row. Whichever transaction arrives second waits for the first to commit, then re-reads the row.
- If review started first, the save fails atomically with `This request has already entered review and can no longer be edited.` and the reviewed request is not modified.
- The staff UI shows that message and refreshes the request, which then shows the read-only guidance.

This was verified with two concurrent database sessions against a disposable database: the requester's save blocked on the admin's open transaction, then failed with the message above once the admin committed; the line set and audit history were unchanged.

**Known limitation (unchanged approval semantics):** if a requester's edit commits *before* an admin acts, an admin who loaded the request earlier and then approves from a stale screen approves — and commits — the current (edited) contents. The edit is visible in the admin activity log as "Requester edited request". Closing this fully requires an optimistic version check on the approval RPC, which this phase deliberately does not change. See follow-ups.

## Audit behavior

Requester edits reuse `supply_request_updates`:

- one row per successful edit: `event_kind = 'requester_edited'`, `author_id = requester`, `status_from/status_to/internal_note/staff_visible_note` all `NULL`;
- a check constraint makes a `requester_edited` row unable to carry a lifecycle status or any note, so an edit event can never smuggle an admin note to staff;
- admins see "Requester edited request" in the request's Activity log;
- the requester sees "You edited this request" in their timeline via the staff-safe `list_staff_supply_request_updates` projection, which still never returns `internal_note`.

No field-level diff is fabricated; the current architecture has no clean diff model.

## Confirmation UX

- Pressing Enter in the search box no longer submits the form; pressing Enter in the custom-item field adds that item.
- The final **Submit Request** button (and any remaining implicit submission) opens a confirmation dialog built on the existing `AlertDialog` component:
  - **Submit this request?**
  - "4 items will be sent for review." (singular for one item), plus team · location when known;
  - **Keep editing** / **Submit request**.
- The mutation runs only from **Submit request**. No wizard or extra step is added beyond this one confirmation.
- **Save changes** in edit mode does not ask for confirmation: it is reversible until review begins.

## Post-submission recovery messaging

After a successful submission the existing success screen now says:

> **Request Submitted** — You can still edit this request until review begins.

with a primary **View request** action linking to the new request's detail page, and the existing **Request another item** action.

On the staff request detail page:

- `submitted`: "You can make changes until this request enters review." with an **Edit request** button.
- `under_review`: "This request is being reviewed and can no longer be edited." No edit action.
- later statuses: no edit action.
- the requester's own request-wide note is now shown, since it is editable.

Edit mode is the existing composer at `/staff/request?edit=<request id>`. It preloads lines, quantities, note, and team/location, shows **Save changes**, and updates the existing request. The composer remounts when switching between creating and editing so one mode's cart can never be submitted by the other.

## Why drafts are not included

Beta feedback showed a need to recover from one accidental submission, not a need to park unfinished work. Drafts would add a status (or a parallel table), autosave, abandoned-draft cleanup, resume flows, and draft lists, and would complicate every admin queue and budget query. Editing until review covers the reported problem with no new lifecycle state.

## Why withdrawal is deferred

Withdrawal/cancellation needs its own status and terminal semantics, admin queue treatment, staff messaging, and a decision about interaction with 6A.2 commitments if allowed after approval. None of that is needed to fix the reported problem. Phase 6C adds no `withdrawn`/`cancelled` status, no requester cancellation, and no request deletion. A requester who no longer needs a submitted request should contact an administrator, who can decline it through the existing workflow.

## Financial and commitment non-effects

Editing a `submitted` request is pre-review and pre-financial-commitment. Phase 6C does not change:

- approval behavior or the `decide_supply_request` / `transition_supply_request` RPCs;
- 6A budget math or `get_budget_summary`;
- 6A.2 commitment creation, immutability, or manual release (an edit never creates a commitment; approval still snapshots the request's lines at approval time, exactly once);
- purchasing/ordering, receiving, or invoice handling;
- Phase 6B price intelligence;
- request-to-invoice relationships (no heuristic is introduced).

The admin budget-impact preview for a `submitted` request already reads live lines, so it reflects edits automatically.

## Explicit non-goals

- drafts of any kind (status, server-side saved drafts, autosave, resume, lists, cleanup);
- withdrawal, cancellation, or deletion of requests;
- editing after review begins, or by anyone other than the requester;
- admin editing of staff requests;
- field-level change diffs;
- notifications to admins about edits;
- changes to approval, commitment, budget, purchasing, receiving, invoice, or price-intelligence behavior.

## Tests

- `tests/phase6c-staff-request-forgiveness.test.ts` — helpers (eligibility, preload/round-trip of identities, request-type derivation, context resolution, confirmation copy), payload validation, and structural checks of the migration, server functions, composer, staff detail, and admin activity log.
- `supabase/tests/phase6c_staff_request_forgiveness_behavior.sql` — rollback-only behavioral coverage (35 checks): refactored submission; same ID/status/no duplicate; quantity change, line removal, mixed structured + custom additions; note/team/location edits and context preservation; stored-identity round trip; invalid quantities, identities, teams, and locations with exact messages; atomic failure; every locked status; ownership, cross-organization, and deactivated-member denials; no bypass via private helpers or direct table writes; audit events for admin and staff; no internal notes for staff; stale save after review; no commitment before approval and an unchanged 6A.2 approval snapshot of the edited lines afterward; audit constraint.

## Deployment (not performed)

1. Review and apply `20261009120000_phase6c_staff_request_forgiveness.sql` (single transaction with a preflight guard).
2. Regenerate Supabase types and compare with the hand-edited `src/integrations/supabase/types.ts` changes (`event_kind`, `update_submitted_supply_request`, `list_staff_supply_request_updates.event_kind`).
3. Run `supabase/tests/phase6c_staff_request_forgiveness_behavior.sql` and the existing request behavior suites against a disposable migrated database.
4. Deploy the application only after the migration is live: the new staff UI calls `update_submitted_supply_request` and reads `event_kind`.

## Follow-ups

- Optional optimistic concurrency for admin decisions (e.g. pass the `updated_at` the admin reviewed) so an approval made from a stale screen is rejected after a requester edit.
- Requester withdrawal as its own phase.

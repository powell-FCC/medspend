# Phase 7B.1: Inventory admin workspace

Phase 7B.1 turns `/inventory` into a workspace for owners and admins: Items, Locations, a page per location with its Stock and Labels, and the full QR label lifecycle including revoke-only. Owners manage inventory. Admins see the same information read-only. Staff keep the Staff Workspace, Request Supplies, My Requests and `/count`, and gain nothing.

Migration: `supabase/migrations/20261028120000_phase7b1_inventory_admin_workspace.sql`. Release: `supabase/release/phase7b1/README.md`.

## Roles

|                                             | Owner | Admin                 | Staff                 |
| ------------------------------------------- | ----- | --------------------- | --------------------- |
| Inventory in the admin navigation           | yes   | yes (Read-only badge) | no (admin shell only) |
| Items, Locations, location Stock and Labels | read  | read                  | no                    |
| Add, edit, archive items; categories        | yes   | no                    | no                    |
| Add, rename, archive, restore locations     | yes   | no                    | no                    |
| Move and adjust stock                       | yes   | no                    | no                    |
| Issue, Replace, Revoke QR labels            | yes   | no                    | no                    |
| `/count`                                    | yes   | yes                   | yes (unchanged)       |

Admin controls are hidden, not disabled. Hiding is never the protection: every mutation server function checks the owner role (`src/inventory/owner-access.ts`), and every database function checks it again. Upload Invoice and Invoices stay owner-only.

## Reads: owner+admin functions, never raw tables

Raw-table RLS stays owner-only for locations, balances, transfers, adjustments and count history, and labels stay unreadable. No policy or table grant changed. Admins read through five SECURITY DEFINER functions. Each refuses an anonymous caller, a non-member, a member of another organization and staff with `Forbidden: owner or admin access required` (`is_org_admin`: an active membership with role owner or admin), and filters every query by the requested organization:

| Function                                                                                     | Returns                                                                                                                                                                                                                                                       |
| -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `list_inventory_workspace_locations(org, status, limit, after…)`                             | Each location: kind, active, items stocked (quantity > 0), countable items (the locked 7A.2 rule, through `inventory_countable_balances`), last counted and by whom, active labels, last label issued. Unassigned first; its count and label fields are NULL. |
| `get_inventory_workspace_location(org, location)`                                            | The same for one location, plus archived items still stocked there.                                                                                                                                                                                           |
| `list_inventory_workspace_location_stock(org, location, limit, after…)`                      | A storage location's countable items, or what Unassigned holds (quantity > 0): quantity here, archived flag, the item's organization quantity, par and status, and when it was last counted here.                                                             |
| `list_inventory_workspace_items(org, search, category, status, stock_status, limit, after…)` | Items with search, category, status and organization-level low-stock filters applied in the database; Unassigned and physical quantities, how many physical locations hold it, and the location name when it is exactly one.                                  |
| `list_inventory_workspace_item_balances(org, item)`                                          | One item's balance at every location, for the owner's Move and Adjust dialogs.                                                                                                                                                                                |

None returns `last_purchase_price`, `last_purchase_date` or any vendor cost. Owners and admins receive the same contract. The item list includes description, vendor name and manufacturer because the owner's edit form rewrites every field it shows.

Par and status are organization-wide: the item's total against its organization par, with the same rule as `getInventoryStatus` (`inventory_workspace_stock_status`). The Stock tab says so and never calls a location low on stock; SportSpend has no par per location (7D).

## No silent truncation

Before 7B.1 the page loaded every item and every balance in one request each. A hosted project's API returns at most its row cap (1000 by default), so a large organization would have seen wrong placements without an error. Now:

- every list function is keyset paged (`(sort key, id) > cursor`, page size 1 to 500), and the Items and Stock tabs load more on request;
- counts (items stocked, countable items, labels) are computed in the database, never from rows loaded into the browser;
- the server loops through location pages, so the location list is complete however many there are;
- one-object answers (a location's header, one item's balances) are a single JSON value, which the row cap does not apply to.

`run_phase7b1_workspace_integration.sh` runs PostgREST with `PGRST_DB_MAX_ROWS=1000` against 1100 items, 2234 balance rows, 1100 rows at one location and 210 locations, shows a raw read really stops at 1000, and proves every workspace read is complete. `listInventoryFn` and `listLocationCountStatusFn` stay for the currently deployed application but the workspace no longer calls them.

## QR labels

The raw token is returned once, when a label is issued; only its SHA-256 hash is stored. A printed copy can never be regenerated, so "another copy" is always another, newly issued label.

- **Issue label / Issue another label**: one more active label; earlier ones keep working.
- **Replace labels**: `replace_inventory_location_labels` locks the location row, revokes every active label, and issues exactly one replacement through `issue_inventory_location_label` (same owner check, eligibility rules, token generation and hashing), all in one transaction. If issuing fails, the revocation rolls back: the earlier labels keep working and nothing new exists. The location lock serializes concurrent replacements. The old client-side revoke-then-issue sequence is gone.
- **Revoke labels**: `revoke_inventory_location_labels` (unchanged since 7A.2) revokes every active label and issues nothing. Confirmation: "N active labels for [Location] will stop working immediately. No new label will be issued." An active location can still be counted from the `/count` location list.

Archived locations: their unrevoked labels are suspended (they resolve as `location_unavailable`). The owner may revoke them; issuing and replacing are refused until the location is restored. Restoring brings back unrevoked labels and never revives revoked ones ("Restoring this location will not reactivate revoked labels."). The archive dialog offers "Also revoke N active labels", unchecked by default; when checked it archives first, then revokes, and if the revoke fails it reports that the location was archived and its labels were not revoked.

## Screens

- `/inventory?tab=items|locations`. Later packages add Overview and Activity tabs.
- `/inventory/locations/$locationId?tab=stock|labels`. Unassigned uses the same route with a system layout: stock only, no labels, counts, rename or archive.
- Locations show factual count state only: "Not counted yet", "Nothing to count" (no countable items), or "Counted N days ago" with the date and who counted. There is no fresh, due or overdue until a count cadence is approved (7B.5).

## Unchanged

QR scan semantics, physical counts, stale-count protection, balance versioning, the countable-item rule, Unassigned protection, staff `/count`, request identity hardening, and every 7A.1 and 7A.2 function body and grant (the release fingerprint proves it). The Phase 7A.2 production acceptance records are untouched.

## Deferred

Count history (7B.2), transfer and adjustment history (7B.3), overview KPIs and the dedicated Unassigned view (7B.4), count cadence (7B.5), location-level par and replenishment (7D), receiving destinations (7C), purchasing (8), dollar valuation (10), location-scoped admins.

## Tests

- `supabase/tests/phase7b1_inventory_admin_workspace_behavior.sql`: rollback-only. Exact contracts, the authorization matrix for every read, organization scoping, admin raw-table reads still empty, summaries and the countable rule against the 7A.2 count page, keyset paging, filters, Replace (refusals, a forced failure after revocation, success), revoke-only on an archived location, and every admin mutation path refused with inventory unchanged.
- `supabase/tests/phase7b1_mutation_check.sh <db>`: 19 mutants, all killed.
- `supabase/tests/run_phase7b1_workspace_integration.sh` with `tests/phase7b1-workspace-integration.test.ts`: real JWTs for owner, admin, staff, another organization's owner and admin, a non-member and anon through PostgREST with a 1000-row cap; the server-function read helpers and owner check; Replace rollback through the API.
- `supabase/tests/phase7b1_release_check.sh`: the release scripts as the SQL Editor sends them, an induced failure, refused reapplication, and a pre/post diff limited to the seven new functions.
- `tests/phase7b1-inventory-admin-workspace.test.ts`: workspace rules, migration and release structure, routes, navigation, server-function owner checks, and rendered owner and admin UI.

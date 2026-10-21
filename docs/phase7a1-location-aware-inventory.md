# Phase 7A.1: location-aware inventory foundation

Phase 7A.1 lets the same product sit in several physical places (a training room cabinet, an away medical cart, an academy supply room) with a quantity at each. It is the foundation for Phase 7A.2 (QR physical counts) and adds no QR, scanning or counting.

Migration: `supabase/migrations/20261021120000_phase7a1_location_aware_inventory.sql`.

## Why an organization-wide quantity was not enough

Before 7A.1, `inventory_items` held one row per organization product (`inventory_items_org_product_uq`) with one `quantity`. A physical count is a statement about one place. Counting a cabinet against an organization-wide number would silently erase stock held anywhere else. Giving each item a single location was rejected for the same reason: tape lives in more than one place.

## Why `public.locations` was not reused

`public.locations` are organization sites. Supply requests use them as destinations, and members use them as their default location. Putting cabinets and carts there would add them to the staff request location picker and to member defaults. Physical storage locations are a separate concept: `public.inventory_locations`. Settings > Locations is unchanged.

## Model

| Table                         | Role                                                                                                                                                                            |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `inventory_locations`         | Physical storage locations per organization. `kind` is `unassigned` (exactly one per organization) or `storage`. Names are unique per organization, ignoring case.              |
| `inventory_location_balances` | **Canonical** quantity per `(inventory_item_id, inventory_location_id)`. `numeric`, `>= 0`. `version` and `updated_at` change on every write, so 7A.2 can detect a stale count. |
| `inventory_transfers`         | Stock moves: item, from, to, quantity (> 0), actor, time, idempotency key (unique per organization).                                                                            |
| `inventory_adjustments`       | Gains `inventory_location_id`. `NULL` only on rows written before 7A.1, which were organization-level history. `source_type` also accepts `physical_count`, reserved for 7A.2.  |

Composite foreign keys (`(id, organization_id)`) tie every balance, transfer and located adjustment to an item and a location of the **same** organization. A cross-tenant row cannot be created, even by the database owner.

### Organization total invariant

`inventory_items.quantity` stays, because every existing read path uses it: inventory UI, low stock, inventory intelligence, staff search and price tools. It is a summary, never a second source of truth:

- **Single writer.** `inventory_apply_balance_delta(org, item, location, delta)` is the only code that changes a balance or the summary. It changes both by the same amount, in one function.
- **Guard triggers.** `inventory_items_guard_quantity` and `inventory_location_balances_guard` reject any quantity change made outside that function. The function sets a transaction-local flag. Clients cannot set it, because PostgREST exposes only public-schema functions. An insert of a non-zero quantity by `anon`, `authenticated` or `service_role` is also rejected.
- **Commit-time proof.** The deferred constraint triggers `inventory_items_balance_invariant` and `inventory_location_balances_invariant` re-check `quantity = SUM(balances)` for every touched item at commit. A mismatch aborts the whole transaction.
- **Seeding.** Every new item gets an Unassigned balance carrying its inserted quantity, through `inventory_items_seed_balance`. Every application path inserts at 0.

### Unassigned

Unassigned is stock the organization holds that has not been placed in a physical location yet. It is not a site, not a request destination and never a QR location. It is created per organization: by the migration for existing organizations, and by `organizations_seed_inventory_unassigned` for new ones. Triggers and the RPCs refuse to rename, describe, archive, delete or re-kind it, or to make any other location `unassigned`.

A storage location can be archived only when it holds no stock. Archived locations cannot receive stock, so stock can never be stranded.

### Fractional quantities

Quantities remain `numeric`; nothing is rounded or converted to integers. The UI shows up to six decimal places without float noise (`formatQuantity`). 7A.2 count controls should follow the same rule.

## Mutation paths

The audit inventoried every quantity-changing path. All of them now go through the primitive.

| Path                                                                                 | Destination             | Change                                                                                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------ | ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `post_reviewed_invoice` (exact-match and manual-match receiving)                     | Unassigned              | Only the quantity write and the receipt row were replaced by `apply_inventory_location_delta`. The reason, provenance, idempotency key, price history and all other statements are byte-for-byte main's; a unit test holds the body to the beta-hardening text. |
| `receive_invoice_inventory_item` (legacy, unused by the app)                         | Unassigned              | Routed through the primitive; see the security hardening below.                                                                                                                                                                                                 |
| `stock_catalog_vendor_product`                                                       | Unassigned (zero)       | Unchanged. Its zero-quantity insert gets a zero Unassigned balance from the seeding trigger.                                                                                                                                                                    |
| `adjust_inventory_quantity(org, item, amount, reason)` (deployed app)                | Unassigned              | Same signature, owner check, reasons and return value (the new organization total). It never borrows from a shelf: if Unassigned is short it fails, even when the total would allow the change.                                                                 |
| `adjust_inventory_location_quantity(org, item, location, amount, reason)` (7A.1 app) | Chosen location         | Owner only; non-zero; no "Invoice received" reason. Changes only that location and the total.                                                                                                                                                                   |
| `move_inventory_stock`                                                               | From → to               | Owner only; total unchanged; see below.                                                                                                                                                                                                                         |
| `delete_invoice_permanently`                                                         | Removes from Unassigned | See below.                                                                                                                                                                                                                                                      |
| Item create in the UI                                                                | Unassigned              | Inserts at 0, then a location adjustment for the starting quantity.                                                                                                                                                                                             |
| Item edit in the UI                                                                  | none                    | The quantity field is read-only; stock changes only through Adjust or Move. This also removes main's read-then-write race.                                                                                                                                      |

Request submission, approval and fulfillment never touch inventory, before or after 7A.1. Budgets, price history, catalog pricing and invoice totals are not modified.

### Receiving rule

All receipts land in Unassigned. Receiving never guesses a cabinet from the organization site, the request location, the staff member's default location, the vendor or any earlier count. Choosing a receiving destination is a later purchasing/receiving UX decision.

### Moves

`move_inventory_stock(org, item, from, to, quantity, idempotency_key)`:

- Requires the owner role, a quantity greater than 0, two different locations in the item's organization, and an active destination.
- Locks the item row, then both locations (`FOR SHARE`, in id order), then both balances in location-id order.
- Rejects the move if the source would go below zero.
- Writes one `inventory_transfers` row and leaves the organization total unchanged.
- **Retries:** the same key with the same payload returns `replayed: true` and changes nothing. The same key with a different payload is rejected. Concurrent retries serialize on the item lock, so exactly one applies.

Moves never write `inventory_adjustments`. Those rows change totals, and invoice deletion sums them.

## Invoice deletion

`delete_invoice_permanently` keeps main's behavior, including its organization-total snapshot rebuild of surviving history, plus two guards:

1. **Reversal from Unassigned only.** Receipts land in Unassigned, so their reversal is taken from Unassigned through the primitive. If stock has since been moved to shelves and Unassigned is short, deletion is refused with "Move N <unit> of <item> back to Unassigned before deleting this invoice." Stock is never pulled from a physical location silently.
2. **Physical-count checkpoint.** A count is an absolute checkpoint. Replaying relative history across one corrupts stock: 10 actual, +5 mistaken receipt = 15, count to 10, delete the receipt, and a naive replay leaves 5. Deletion is refused when any `physical_count` adjustment for an affected item, at any location, was created at or after the invoice's receipt. 7A.1 writes no counts; the guard is exercised with synthetic `physical_count` rows.

Before any move or count exists, deletion results are identical to main: `phase7a1_backfill_check.sh` runs the same deletions on a main-schema copy and a migrated copy and diffs the results.

## Concurrency

- **Lock order:** item row first, then locations (share), then balances in location-id order. Every quantity change to one item therefore queues on its item row.
- **Invoice deletion:** keeps its upload, invoice, items-by-id lock order.
- **Archive:** takes the location row `FOR UPDATE`, so it waits for any in-flight move into that location and then sees its stock.

`supabase/tests/phase7a1_race_check.sh` runs these two-session scenarios:

1. Receiving during a move.
2. Two moves draining one source (the second is refused).
3. An adjustment racing a move.
4. Deletion against a move, and deletion with a queued adjustment.
5. Archive against an incoming move.
6. 100 opposite-direction moves across two items in parallel (no deadlock, exact totals).
7. A concurrent retry of one move request.
8. A committed drift that aborts at commit.

## Authorization

- **Owner:** reads locations, balances and transfers (RLS), and manages locations, moves and adjustments through the RPCs. Inventory was owner-only before and stays so.
- **Admin and staff:** read no location data and have no new mutation path. Admin catalog stocking still creates zero-quantity items, as before.
- **Direct table writes:** application roles (`anon`, `authenticated`, `service_role`) have **no** insert, update or delete grants on the three new tables. Supabase's default all-privileges grants are revoked.
- **Internal primitives:** `inventory_apply_balance_delta`, `apply_inventory_location_delta` and `ensure_inventory_unassigned_location` are not executable by clients.
- **Ledger:** the direct owner insert path into `inventory_adjustments` (policy, and the `authenticated`/`anon` insert grants) is closed. A hand-written ledger row changes no balance and would corrupt deletion replay. The deployed app never used it.

### Security hardening found during 7A.1

`receive_invoice_inventory_item` (Phase 2C) is unused by the app. Its `EXECUTE` privilege was held by `PUBLIC`, and so by `anon`. It already required the owner role internally, so neither staff nor anon could change inventory through it. It now refuses `PUBLIC`/`anon` at the grant level too, and also requires a signed-in caller explicitly. It stays owner-only, matching owner-only invoice posting, and was not broadened to admins.

The four-argument `adjust_inventory_quantity` was likewise executable by `anon`, behind the same internal owner check. It is now `authenticated`-only.

## Migration and release

The migration is additive and safe before the app deploys:

- It runs in one transaction and briefly locks `inventory_items` and `inventory_adjustments` (`SHARE ROW EXCLUSIVE`) while it snapshots and backfills.
- It writes no history and fabricates no locations: each organization gets Unassigned, and each item's current quantity becomes its Unassigned balance.
- It ends with an in-migration postcheck: identical item and adjustment counts, every quantity unchanged, `quantity = SUM(balances)` for every item, all stock in Unassigned, and one Unassigned per organization.

Release order:

1. `supabase/release/phase7a1/precheck.sql`
2. Apply the migration.
3. `supabase/release/phase7a1/postcheck.sql`, then diff the two outputs (see that folder's README).
4. Merge and deploy the app.

The deployed app keeps working at every step: it calls only signatures that still exist with the same behavior.

## Boundary with 7A.2

7A.1 provides:

- per-location balances with `version` and `updated_at` for stale-count detection
- protected Unassigned
- location context on every new adjustment
- the reserved `physical_count` source type
- the deletion checkpoint guard
- owner-only reads that 7A.2 will widen with a narrow staff counting boundary

**Deferred to 7A.2:**

- QR identity and tokens for `storage` locations, never Unassigned
- the staff scan and count UI
- the count session table and `count_session_id`
- zero-delta count rows
- the staff-safe read and count RPCs

**Deferred to the Inventory Admin Workspace:**

- location dashboards, low-stock and par rules per location
- bulk or approved transfers, count schedules and overdue counts
- choosing a receiving destination at receipt time
- adjustment and transfer history views

The count-freshness and overdue capability will come from `physical_count` adjustments, which carry location, item and time, together with balance `version`/`updated_at`.

## Tests

- `tests/phase7a1-location-aware-inventory.test.ts`: helpers, migration structure, the `post_reviewed_invoice` body-equality check, server functions, and rendered owner UI.
- `supabase/tests/phase7a1_location_aware_inventory_behavior.sql`: rollback-only, with deferred checks forced before rollback. Covers balances, receiving, moves, compatibility and location adjustments, legacy receive authorization, direct-write rejection, invariant rollback, archive rules, deletion guards, RLS and tenant isolation.
- `supabase/tests/phase7a1_mutation_check.sh`: 15 mutants, all killed.
- `supabase/tests/phase7a1_backfill_check.sh`: seeded pre-7A.1 history, precheck/postcheck diff, and deletion parity with main.
- `supabase/tests/phase7a1_race_check.sh`: the two-session scenarios above.

# Phase 6A.2 request commitments

Phase 6A.2 adds organization-level request commitment accounting without creating a request-to-invoice relationship.

## Architecture decision

- `supply_request_commitments` is the one-per-request financial record. It stores the immutable known amount, pricing completeness, commitment actor/time, active/released state, and release audit.
- `supply_request_commitment_items` stores every request line's quantity and resolved unit/extended cost at commitment time. Unpriced lines are stored explicitly with null cost fields.
- Approval creates both records inside `transition_supply_request`, using the same organization-scoped request row lock and transaction as the lifecycle audit. The unique request key plus conflict-safe insertion makes retries idempotent.
- Active means the request reached `approved` and has not been denied or explicitly released. `ordered`, `received`, and `completed` preserve active status.
- Denial releases an existing active commitment with a lifecycle reason. An admin can otherwise release through `release_supply_request_commitment`, which requires a reason type and explanation and only allows the one-way `active -> released` transition.
- No invoice, vendor, SKU, name, date, or price matching clears a commitment. Admins release it after confirming that posted actual spend replaces it, or that the obligation no longer exists. This explicit handoff prevents silent double-counting without inventing fulfillment data.

## Price snapshot rules

The resolver uses the first available nonnegative USD-equivalent value in this order:

1. latest immutable purchase-price history for the request's exact organization vendor product;
2. the selected inventory item's last purchase price;
3. latest immutable purchase-price history for the request's organization product;
4. the selected global catalog vendor product's source price, only when its currency is explicitly USD.

Catalog source price is an estimate, not purchase history. It is used only as the last available source for approval planning and becomes immutable only when copied into the commitment snapshot.

`fully_priced` means every line has a cost. `partially_priced` sums only priced lines and retains null snapshots for the others. `unpriced` has a zero known amount and never presents that zero as an estimated cost. Budget and approval UI disclose incomplete pricing.

Historical requests that had already reached approval before the migration are backfilled as unpriced commitments. Their approval timestamp/actor is recovered from request audit rows when available. Repricing them from current mutable data would falsely present a current estimate as historical truth. Previously denied requests that demonstrably reached approval are backfilled as released.

## Budget behavior

`get_budget_summary` preserves the Phase 6A.1 actual-spend query and legacy actual-only `remaining_amount`. It adds `committed_spend` and `available_amount`, where:

`available_amount = budget_amount - actual_spend - active known commitment amounts`

Commitments are included when their commitment date is inside the selected budget period. Incomplete commitment counts make the known-cost limitation visible. There is still no team attribution.

The admin request detail calls `get_supply_request_budget_impact`. For a pending request it returns the current budget, actual spend, active committed spend, available budget, the live request estimate, and projected availability after approval. Once committed, it uses the immutable snapshot rather than live price data.

## Deployment and verification

The local implementation does not apply or deploy anything. Deployment eventually requires reviewing and applying `20260914120000_phase6a2_request_commitments.sql`, regenerating Supabase types from that database if the standard generated output differs, and running `supabase/tests/phase6a2_request_commitments_behavior.sql` against a disposable migrated database. The behavior script is rollback-only.

# Budget & Purchasing command center

## Purpose

`/budget-purchasing` is the admin financial and purchasing dashboard. It answers: what is the budget, what has been spent, what is committed, what is truly available, what needs attention, and whether the organization is paying more than before or more than another vendor it already buys the same item from.

It replaces the Phase 6A.1 Budget page. Creating and editing budget periods moved onto this page (the same `BudgetEditor` dialog and `saveBudgetFn`), and `/budget` redirects here.

## Sources and architecture

No new tables. Migration `20261015120000_budget_purchasing_command_center.sql` adds three read-only `STABLE SECURITY DEFINER` functions. Each requires owner/admin membership of the requested organization (`is_org_admin`), is revoked from `PUBLIC`/`anon`, and is granted to `authenticated`.

| Function                               | Returns                                                                                                                        |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `get_budget_purchasing_overview(org)`  | Every active budget's row from `get_budget_summary`, attention counts, and (owners only) the eight latest posted invoices      |
| `get_budget_lineage(org, budget)`      | Active commitments and (owners only) posted invoices inside one budget period, with full-period totals and lists bounded to 50 |
| `get_price_intelligence_overview(org)` | One comparison row per product for the 500 most recently purchased products                                                    |

Invoice-level detail (invoice numbers, vendors, totals, the invoice review queue) is returned to owners only, matching the existing owner-only invoice and purchase screens. Admins see the same budget totals and price intelligence they already had through Phase 6A/6B.

The browser makes two requests for the page (overview and prices), plus one per opened detail drawer. The price drawer reuses Phase 6B `get_product_price_intelligence` for the observation history list.

## Financial definitions

All figures come from `get_budget_summary` unchanged, called once per active budget inside the overview function:

- **Budget**: `organization_budgets.amount` for the period.
- **Spent**: posted invoices (`posted_at IS NOT NULL`) whose `COALESCE(invoice_date, posted_at::date)` falls in the period, totalled as `COALESCE(invoice_total, total_amount, total, SUM(invoice_items.total_price), 0)`.
- **Committed**: `supply_request_commitments` with `status = 'active'` whose `committed_at::date` falls in the period. Amounts are the immutable snapshots captured at approval; unpriced items count as $0 and are disclosed.
- **Available**: Budget − Spent − Committed.

A commitment leaves Committed only when an admin releases it (denied, settled, cancelled, …). Requests are not matched to invoices automatically, so a received or completed request whose purchase has since been invoiced is counted in both Spent and Committed until its commitment is released. Whether that has happened is not knowable from the data, so the page never nets, adjusts, or auto-releases anything. Instead it makes the condition explicit:

- **Settlement candidate**: an active commitment whose request status is `received` or `completed`. Per budget, candidates use the same `committed_at::date` period rule as Committed, so they are always a subset of it.
- **Summary**: the Committed figure is labelled "Active / unreleased". When the scope holds candidates, an amber notice states "$X of commitments may need settlement", says that Available includes them and may be conservative until each is reviewed, and says this is not confirmed duplicate spend. Budget, Spent, Committed and Available are the canonical values either way.
- **Needs Attention → Commitments to settle** leads the list while non-zero (count, amount, explanation) and opens a drawer listing the candidates, oldest first (25 shown, totals over all).
- **Action**: each candidate links to `/supply-requests?request=<id>`, which opens that request's existing detail in its own queue tab. Release happens there, through the existing audited **Release Commitment** action (reason type and explanation required). The dashboard performs no mutation.
- **Budget drawer**: every commitment is tagged **Active commitment** or **Potential settlement candidate**, with the candidate count and total for the period.

Budgets are organization-wide periods; there are no categories or departments. When several active budgets exist the page shows one period at a time (default: the period containing today, latest start first). "All active budgets" combines them by summing only when no two periods overlap. Overlapping periods would attribute the same invoice to both budgets, so a combined view is not offered for them.

No projection or forecast is shown.

## Needs Attention

Only existing workflows, with counts from the database:

- **Awaiting approval**: requests in `submitted` or `under_review` (count only; pending requests have no committed amount). Opens the Request Inbox on Needs Review.
- **Invoice review** (owners): `invoice_processing_jobs.status = 'review_required'` (count only). Opens Invoices.
- **Budget warning**: active budgets covering today with spent + committed ≥ 90% of the budget, or over budget.
- **Commitments to settle**: active commitments on `received`/`completed` requests, with their exact snapshot total. Listed first while non-zero; opens the candidate list described above.
- **Unpriced commitments**: active commitments that are not fully priced.

## Price intelligence rules

Observations are exactly the Phase 6B valid set: this organization's `inventory_price_history` rows on posted invoices with `currency_code = 'USD'` and a price of `unit_price`, or `extended_price / quantity` when the unit price is absent. Catalog/list prices are never read.

- **Current**: the product's most recent observation, ordered by `purchase_date`, `created_at`, `id`.
- **Comparable unit**: the observation's unit of measure (trimmed, case- and whitespace-insensitive) plus its package size text compared the same way. A current observation without a unit of measure is not compared with anything.
- **Previous**: the immediately earlier observation from the same vendor with the same comparable unit (a missing package matches a missing package for the same vendor only). **Change** and **Change %** are computed only against that row; the percentage needs a previous price above zero.
- **90-day average**: the average of the same vendor's same-unit observations dated within the 90 days ending on the current purchase date (inclusive).
- **Best known option**: among other vendors, each vendor's latest observation of the same product with the same unit of measure and the same recorded package size (both must be present); the lowest price wins. Product identity is the organization's matched `products.id`; nothing is inferred from descriptions.
- **Unit savings**: current price − best option price, only when the option is lower. It is per unit of measure and never annualized.
- **Filters**: Price increases = change > 0; Savings opportunities = unit savings > 0. Vendor filter uses the current vendor.

Package text comes from invoice lines and is not independently verified (see Phase 6B); the evidence drawer says so.

## Verification

- `supabase/tests/budget_purchasing_command_center_behavior.sql` (rollback-only): budget math and agreement with `get_budget_summary`, settled commitments excluded, attention counts, lineage reconciliation, owner/admin visibility, every price rule, refusal for staff/non-members/other organizations, cross-organization isolation, empty organizations, and function volatility/grants.
- `supabase/tests/budget_purchasing_command_center_mutation_check.sh <database>`: removes each critical rule in turn and expects the suite to fail.
- `tests/budget-purchasing-command-center.test.ts`: scope combination, utilization, attention items, filters and sorts, server data functions, and server-rendered UI states.
